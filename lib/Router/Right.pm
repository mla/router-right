package Router::Right;
# ABSTRACT: FIX ME

use strict;
use warnings;
use Carp;
use List::Util qw/ max /;
use List::MoreUtils qw/ any uniq /;
use URI;
use URI::QueryParam;

our $VERSION = 0.01;

require 5.10.0; # for named captures

sub new {
  my $class = shift;

  $class = ref($class) || $class;

  my $match;

  my $self = bless {
    routes => [],      # routes in insertion order
    index  => {},      # same routes, but indexed by name
    match  => \$match, # route index of last match
    error  => undef,   # status code of last match
  }, $class;

  return $self;
}


sub _list {
  my $class = shift;

  return map { ref $_ eq 'ARRAY' ? @$_ : $_ } @_;
}


# mainly for testing right now
sub _route {
  my $self = shift;
  my $name = shift or croak 'no name supplied';

  return $self->{index}{ $name };
}


sub error {
  my $self = shift;

  if (@_) {
    $self->{error} = shift;
    return;
  }

  return $self->{error};
}


sub _args {
  my $self = shift;
  my @args = (@_ % 2 ? (payload => @_) : @_);

  my %merged;
  while (@args) {
    my $key = shift @args;
    if ($key eq 'payload') {
      my $payload = shift @args;
      $merged{ $key } ||= {};
      @{ $merged{ $key } }{ keys %$payload } = values %$payload;
    } elsif ($key eq 'methods') {
      $merged{ $key } = [
        grep { defined }
        $self->_list($merged{ $key }, shift @args)
      ];
    } else {
      $merged{ $key } = shift @args;
    }
  }

  return wantarray ? %merged : \%merged;
}

sub _split_route {
  my $self = shift;
  my $route = shift or croak 'no route supplied';

  $route =~ m{^\s* (?:([^/]+)\s+)? (/.*)}x
    or croak "invalid route specification '$route'";
  (my $methods, $route) = ($1, $2);

  return ($methods, $route);
}


sub _methods {
  my $self = shift;

  my @methods = 
    sort { $a cmp $b }
    uniq 
    map  { s/^\s+|\s+$//g; uc $_ }
    map  { split '[|,]' }
    grep { defined }
    $self->_list(@_)
  ;
  @methods = () if any { $_ eq '*' } @methods;

  return wantarray ? @methods : \@methods;
}


sub _build_route {
  my $class = shift;
  my $route = shift or croak 'no route supplied';
  my $args  = shift or croak 'no args supplied';

  my @route = split /{([^}]+)}/, $route;
  my @regex;
  my $is_placeholder = 0;
  my %placeholders;
  foreach (@route) {
    if ($is_placeholder) {
      /^([^:]+):?(.*)$/ or croak "invalid placeholder '$_'";
      my ($pname, $regex) = ($1, $2);

      my $optional = 0;
      my $pre = '';  # match before placeholder content
      # placeholder type; used to identify special ones like .format
      my $type = ''; 
      if ($pname eq '.format') {
        $optional = 1;
        $pname = 'format';
        $regex = '[^.\s/]+?' unless length $regex;
        $pre = '\\.';
        $type = '.';
      } else {
        $optional = exists $args->{ $pname } ? 1 : 0;
        $regex = '[^/]+?' unless length $regex;
      }

      croak "placeholder '$pname' redefined" if $placeholders{ $pname }++;

      $_ = {
        pname    => $pname,
        regex    => $regex,
        optional => $optional,
        type     => $type,
      };

      my $opt = $optional ? '?' : '';
      push @regex, "(?:$pre(?<$pname>$regex))$opt";
    } else {
      push @regex, quotemeta($_); # literal
    }
  } continue {
    $is_placeholder = !$is_placeholder;
  }

  return \@route, join('', @regex);
}


sub add {
  my $self  = shift;
  my $name  = shift;
  my $route = shift // croak 'no route supplied';
  my %args  = $self->_args(@_);

  $args{payload} or croak 'no payload defined';

  croak "route '$name' already defined" if $self->{index}{ $name };
  (my $methods, $route) = $self->_split_route($route);
  my @methods = $self->_methods($args{methods}, $methods);

  delete $self->{regex}; # force recompile

  my ($route_arrayref, $regex) = $self->_build_route($route, \%args);

  local $_ = {
    name    => $name,
    route   => $route_arrayref,
    regex   => $regex,
    methods => \@methods,
    payload => $args{payload},
    source  => $route,
  };

  #use Data::Dumper;
  #warn "Added route: ", Dumper($_), "\n";

  push @{ $self->{routes} }, $_;
  $self->{index}{ $name } = $_;

  return $self;
}


sub _compile {
  my $self = shift;

  my $routes = $self->{routes};
  @$routes or return qr/(?!)/; # pattern can never match

  my $match = $self->{match};

  # Tested faster to terminate each route with \z rather than placing
  # at end of combined regex.
  my $regex = join '|',
    map { "(?: $_->[1]{regex} \\z (?{ \$\$match = $_->[0] }))" }
    map { [$_, $routes->[$_]] }
    (0..$#{ $routes })
  ;

  # warn "Regex: $regex\n";
  use re 'eval';
  return qr/\A (?: $regex )/xu;
}


sub match {
  my $self   = shift;
  my $path   = shift;
  my $method = shift;

  my $regex = $self->{regex} ||= $self->_compile;

  my $match = $self->{match};
  $$match = undef;
  $self->{error} = undef;

  $path =~ /$regex/ or return $self->error(404);

  # The regex above set the index of the matching route on success
  my $route = $self->{routes}[ $$match ]
    or croak "no route defined for match index '$$match'?!";

  if ($method) {
    my $allow = $route->{methods};
    if (@$allow) {
      any { uc $method eq $_ } @$allow or return $self->error(405);
    }
  }

  # XXX Most of the time is related to copying the %+ hash; faster way?
  return { %{ $route->{payload} }, %+ };
}


sub url {
  my $self = shift;
  my $name = shift or croak 'no url name supplied';
  my %args = @_;

  my @route;
  if (my $route = $self->{index}{ $name }) {
    @route = @{ $route->{route} };    
  } elsif ($name =~ m{^/}) {
    if ($name =~ /{/) {
      my ($route, $regex) = $self->_build_route($name, {});
      @route = @$route;
    } else {
      @route = ($name); # url, not really a name
    }
  } else {
    croak "url name '$name' not found";
  }

  my $is_placeholder = 0;
  my @path;
  foreach (@route) {
    if (!$is_placeholder) {
      push @path, $_;
      next;
    }

    my $pname = $_->{pname};

    unless (exists $args{ $pname }) {
      $_->{optional}
        or croak "required param '$pname' missing from url '$name'";
      next;
    }

    my $val = delete $args{ $pname } // '';
    $val =~ /$_->{regex}/
      or croak "invalid value for param '$pname' in url '$name'";

    if ($pname eq 'format' && $_->{type} eq '.') {
      $val = ".$val";
    }

    push @path, $val;
  } continue {
    $is_placeholder = !$is_placeholder;
  }

  my $uri = URI->new(join '', @path);
  $uri->query_param($_ => $args{$_}) foreach keys %args;

  return $uri;
}


sub with {
  my $self = shift;

  return Router::Right::Submapper->new(
    $self,
    @_,
  );
}


sub allowed_methods {
  my $self = shift;

  my $idx = ${ $self->{match} };
  defined $idx or return;

  my $route = $self->{routes}[ $idx ]
    or croak "no route found for idx '$idx'?!";

  my $allow = $route->{methods};
  return wantarray ? @$allow : [ @$allow ];
}


sub as_string {
  my $self = shift;

  my @routes;
  my $max_name_len   = 0;
  my $max_method_len = 0;
  foreach (@{ $self->{routes} }) {
    my $methods = join ',', @{ $_->{methods} };

    $max_name_len   = max($max_name_len, length $_->{name});
    $max_method_len = max($max_method_len, length $methods);

    push @routes, [ $_->{name}, $methods || '*', $_->{source} ];
  }

  my $str = '';
  foreach (@routes) {
    $str .= sprintf "%${max_name_len}s %-${max_method_len}s %s\n", @$_;
  }
  return $str;
}


package Router::Right::Submapper;

use strict;
use warnings;
use Carp;

sub new {
  my $class  = shift;
  my $parent = shift or croak 'no parent supplied';
  my $name   = shift;
  my $route  = shift;
  my %args   = Router::Right->_args(@_);

  (my $methods, $route) = Router::Right->_split_route($route);
  $args{methods} = [ Router::Right->_methods($args{methods}, $methods) ];

  $class = ref($class) || $class;
  my $self = bless {
    parent => $parent,
    name   => $name,
    route  => $route,
    args   => \%args,
  };

  if (my $func = $args{call}) {
    local $_ = $self;
    $func->($self);
  }

  return $self;
}


sub add {
  my $self  = shift;
  my $name  = shift;
  my $route = shift // croak 'no route supplied';

  my $parent = $self->{parent} or croak 'no parent?!';

  (my $methods, $route) = Router::Right->_split_route($route);

  $name  = join '_', grep { defined } $self->{name}, $name;
  $route = join '', grep { defined } $self->{route}, $route;

  $parent->add(
    $name,
    $route,
    %{ $self->{args} },
    Router::Right->_args(@_, methods => $methods),
  );

  return $self;
}


# nested submapper
sub with {
  my $self = shift;

  $self->new($self, @_);
}


1;

__END__

# vim: set foldmethod=marker:
