package Router::Blast;
# ABSTRACT: FIX ME

use strict;
use warnings;
use overload '""' => 'as_string';
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


sub add {
  my $self  = shift;
  my $name  = shift;
  my $route = shift // croak 'no route supplied';
  my %args  = $self->_args(@_);

  $args{payload} or croak 'no payload defined';

  croak "route '$name' already defined" if $self->{index}{ $name };
  (my $methods, $route) = $self->_split_route($route);

  my @methods =
    sort
    uniq 
    map  { s/^\s+|\s+$//g; uc $_ }
    map  { split '\|' }
    grep { defined }
    $self->_list($args{methods}, $methods)
  ;

  delete $self->{regex}; # force recompile

  my @route = split /{([^}]+)}/, $route;
  my $is_placeholder = 0;
  my @regex;
  foreach (@route) {
    if ($is_placeholder) {
      /^([^:]+):?(.*)$/ or croak "invalid placeholder '$_'";
      my ($pname, $regex) = ($1, $2);

      my $optional = 0;
      my $pre = ''; # match before placeholder content
      if ($pname eq '.format') {
        $optional = 1;
        $pname = 'format';
        $regex = '[^.\s/]+?' unless length $regex;
        $pre = '\\.';
      } else {
        $optional = exists $args{ $pname } ? 1 : 0;
        $regex = '[^/]+?' unless length $regex;
      }

      $_ = {
        pname    => $pname,
        regex    => $regex,
        optional => $optional,
      };

      my $opt = $optional ? '?' : '';
      push @regex, "(?:$pre(?<$pname>$regex))$opt";
    } else {
      push @regex, quotemeta($_); # literal
    }
  } continue {
    $is_placeholder = !$is_placeholder;
  }

  local $_ = {
    name    => $name,
    route   => \@route,
    regex   => (join '', @regex),
    methods => \@methods,
    payload => $args{payload},
    source  => $route,
  };

  use Data::Dumper;
  warn "Added route: ", Dumper($_), "\n";

  push @{ $self->{routes} }, $_;
  $self->{index}{ $name } = $_;

  return $self;
}


sub _compile {
  my $self = shift;

  my $routes = $self->{routes};

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
    @route = ($name); # url, not name
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

  return Router::Blast::Submapper->new(
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


package Router::Blast::Submapper;

use strict;
use warnings;
use Carp;

sub new {
  my $class  = shift;
  my $parent = shift or croak 'no parent supplied';
  my $name   = shift;
  my $route  = shift;
  my %args   = Router::Blast->_args(@_);

  (my $methods, $route) = Router::Blast->_split_route($route);

  $args{methods} = [
    grep { defined } Router::Blast->_list($args{methods}, $methods)
  ];

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

  (my $methods, $route) = Router::Blast->_split_route($route);

  $name  = join '_', grep { defined } $self->{name}, $name;
  $route = join '', grep { defined } $self->{route}, $route;

  $parent->add(
    $name,
    $route,
    %{ $self->{args} },
    Router::Blast->_args(@_, methods => $methods),
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
