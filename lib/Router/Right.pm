package Router::Right;
# ABSTRACT: Framework-agnostic URL routing engine for web applications

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
    routes     => [],      # routes in insertion order
    name_index => {},      # route name => route
    path_index => {},      # route path => list of all routes using it
    match      => \$match, # route index of last match
    error      => undef,   # status code of last match
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

  return $self->{name_index}{ $name };
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


sub _split_route_path {
  my $self = shift;
  my $path = shift or croak 'no route path supplied';

  $path =~ m{^\s* (?:([^/]+)\s+)? (/.*)}x
    or croak "invalid route path specification '$path'";
  return ($1, $2); # methods, path
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
  my $self = shift;
  my $name = shift;
  my $path = shift // croak 'no route path supplied';
  my %args = $self->_args(@_);

  $args{payload} or croak 'no payload defined';

  croak "route '$name' already defined" if $self->{name_index}{ $name };
  (my $methods, $path) = $self->_split_route_path($path);
  my @methods = $self->_methods($args{methods}, $methods);

  delete $self->{regex}; # force recompile

  my ($route, $regex) = $self->_build_route($path, \%args);

  local $_ = {
    name    => $name,
    path    => $path,
    route   => $route,
    regex   => $regex,
    methods => \@methods,
    payload => $args{payload},
  };

  #use Data::Dumper;
  #warn "Added route: ", Dumper($_), "\n";

  push @{ $self->{routes} }, $_;
  $self->{name_index}{ $name } = $_;
  push @{ $self->{path_index}{ $path } ||= [] }, $_;

  return $self;
}


sub _compile {
  my $self = shift;

  my @routes = @{ $self->{routes} };
  @routes or return qr/(?!)/; # pattern can never match

  my $match = $self->{match};

  # assign position index, for convience
  for (my $i = 0; $i < @routes; $i++) {
    $routes[$i]{pos} = $i;
  }

  # Tested faster to terminate each route with \z rather than placing
  # at end of combined regex.
  my $regex = join '|',
    map { "(?: $_->{regex} \\z (?{ \$\$match = $_->{pos} }))" }
    @routes
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
  if (my $route = $self->{name_index}{ $name }) {
    @route = @{ $route->{route} };    
  } elsif ($name =~ m{^/}) { # url, not a route name
    if ($name =~ /{/) { # has placeholders? if so, need to parse it
      my ($route, $regex) = $self->_build_route($name, {});
      @route = @$route;
    } else {
      @route = ($name); # otherwise, treat it as string literal
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

    push @routes, [ $_->{name}, $methods || '*', $_->{path} ];
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

  (my $methods, $route) = Router::Right->_split_route_path($route);
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

  (my $methods, $route) = Router::Right->_split_route_path($route);

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

=encoding utf8

=head1 NAME

Router::Right - Framework-agnostic URL routing engine for web applications

=head1 SYNOPSIS

  use Router::Right;

  my $r = Router::Right->new;

  $r->add(
    home => '/',
    { controller => 'Home', action => 'show' },
  );

  $r->add(
    blog => '/blog/{year}/{month}',
    { controller => 'Blog', action => 'monthly' },
  );

  my $match = $r->match('/blog/1916/08'); 
  # Returns {
  #   controller => 'Blog',
  #   action => 'monthly',
  #   year => '1916',
  #   month => '08',
  # }

=head1 DESCRIPTION

Router::Right is a framework-agnostic routing engine used to map web
application request URLs to application handlers.

=METHODS

=over 4

=item new()

Returns a new Router::Right instance

=item add($name => $route, payload => \%payload [, %options])

Define a route. $name is used to reference the route. On a successful match,
the payload is returned as a hash reference; its content can be anything.

See the ROUTE DEFINITION section for details on how $route values are
specified.

As a convience, the payload field name may be omitted. i.e., 
add($name => $route_path, \%payload)

=item match($url [, $method])

Attempts to find a route that matches the supplied $url. Routes are
matched in the order defined.

If a match is found, its associated payload is returned. If not, undef
is returned and the error() method can be checked to see why the match
failed.

$method, if supplied, is the HTTP method of the request
(e.g., GET, POST, PUT, DELETE). Specifying $method may prevent a route
from matching if the route was defined with a restricted set of allowed
methods (see ROUTE DEFINITION). By default, all request methods are allowed.

=item error()

Returns the error code of the last failed match.

  404 = no match found
  405 = method not allowed

A 405 result indicates a match was found, but the request method was
not allowed. allowed_methods() can be called to obtain a list of the methods
that are allowed by the route.

=back

=head1 SEE ALSO

Much of the design of Router::Right comes from Tokuhiro Matsuno's
Router::Simple and Router::Boom modules.

Python's Routes module
L<https://routes.readthedocs.io/en/latest/index.html>

=head1 LICENSE

Copyright (C) Maurice Aubrey

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

# vim: set foldmethod=marker:


