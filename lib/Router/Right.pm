package Router::Right;
# ABSTRACT: Fast, framework-agnostic URL routing engine for web applications

use strict;
use warnings;
use 5.10.0; # named captures, see perlver
use Carp;
use List::Util qw/ max /;
use List::MoreUtils qw/ any uniq /;
use URI;
use URI::QueryParam;

our $VERSION = 0.02;

sub NOT_FOUND          () { 404 }
sub METHOD_NOT_ALLOWED () { 405 }

sub new {
  my $class = shift;

  $class = ref($class) || $class;

  my $match;

  my $self = bless {
    routes      => [],      # routes in insertion order, grouped by path
    route_index => {},      # path => route index of group in above routes[]
    name_index  => {},      # route name => route
    match       => \$match, # route group index of last match
    error       => undef,   # status code of last match
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


# Given a route path, returns the associated route group index
sub _group_index {
  my $self = shift;
  my $path = shift or croak 'no route path supplied';

  return $self->{route_index}{ $path } //= @{ $self->{routes} };
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
      croak "invalid placeholder name '$pname'" if $pname =~ m{/};

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

  delete $self->{regex}; # force recompile

  my $payload = delete $args{payload} or croak 'no payload defined';
  croak "route '$name' already defined" if $self->{name_index}{ $name };

  (my $methods, $path) = $self->_split_route_path($path);
  my @methods = $self->_methods($args{methods}, $methods);

  my $index = $self->_group_index($path);

  my ($route, $regex) = $self->_build_route($path, \%args);

  local $_ = {
    name    => $name,
    path    => $path,
    route   => $route,
    index   => $index,
    regex   => $regex,
    methods => \@methods,
    payload => $payload,
    args    => \%args,
  };

  #use Data::Dumper;
  #warn "Added route '$name' with index '$index': ", Dumper($_), "\n";

  push @{ $self->{routes}[ $index ] ||= [] }, $_;
  $self->{name_index}{ $name } = $_;

  return $self;
}


sub _compile {
  my $self = shift;

  my @routes = @{ $self->{routes} };
  @routes or return qr/(?!)/; # pattern can never match

  my $match = $self->{match};

  # Tested faster to terminate each route with \z rather than placing
  # at end of combined regex.
  my $regex = join '|',
    map { "(?: $_->{regex} \\z (?{ \$\$match = $_->{index} }))" }
    map { $_->[0] } # unique route paths
    @routes
  ;

  # warn "Regex: $regex\n";
  use re 'eval';
  return qr/\A (?: $regex )/x;
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

  # The regex above set the index of the matching route group on success
  my $routes = $self->{routes}[ $$match ]
    or croak "no route defined for match index '$$match'?!";

  my $matched_route;

  if ($method) {
    foreach (@$routes) {
      my $allowed = $_->{methods};
      if (@$allowed) {
        $matched_route = $_ if any { uc $method eq $_ } @$allowed;
      } else { # no allowed means any method is accepted
        $matched_route = $_;
      }
      last if $matched_route;
    }
  } else {
    $matched_route = $routes->[0];
  }

  $matched_route or return $self->error(405);

  # XXX Most of the time is related to copying the %+ hash; faster way?
  #return { %{ $matched_route->{payload} } };
  return { %{ $matched_route->{payload} }, %+ };
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
    }

    my $pval = delete($args{ $pname }) // '';
    $pval =~ /$_->{regex}/
      or croak "invalid value for param '$pname' in url '$name': '$pval'";

    if ($pname eq 'format' && $_->{type} eq '.') {
      $pval = ".$pval";
    }

    push @path, $pval;
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

  my $index;
  if (@_) {
    my $path;
    if ($_[0] !~ m{/}) { # route name, not path
      my $name = shift;
      my $route = $self->{name_index}{ $name } or return;
      $path = $route->{path};
    } else {
      $path = shift;
    }

    $index = $self->{route_index}{ $path };
  } else {
    $index = ${ $self->{match} };
  }
  defined $index or return;

  my $routes = $self->{routes}[ $index ]
    or croak "no routes found for index '$index'?!";

  my $allowed = $self->_methods(map { $_->{methods} } @$routes);
  return wantarray ? @$allowed : $allowed;
}


sub as_string {
  my $self = shift;

  my @routes;
  my $max_name_len   = 0;
  my $max_method_len = 0;
  foreach (map { @$_ } @{ $self->{routes} }) {
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

Router::Right is a Perl-based, framework-agnostic routing engine used to
map web application request URLs to application handlers.

=head1 METHODS

=over 4

=item new()

Returns a new Router::Right instance

=item add($name => $route_path, payload => \%payload [, %options])

Define a route. $name is used to reference the route elsewhere. On a successful match, the payload hash reference is returned; its contents are completely user-defined and may contain anything. For example:

  $r->add(entries => '/entries', payload => { controller => 'Entries' })

See the ROUTE DEFINITION section for details on how $route_path values are specified.
As a convenience, the payload field name may be omitted. i.e.,

  add($name => $route_path, \%payload)

By default, routes match any HTTP request method (e.g., GET, POST). To restrict them, supply a "methods" option. e.g.,

  $r->add(entries => '/entries', { controller => 'Entries' }, methods => 'GET')

That would only match GET requests. The value may be either a string or an array reference of
strings. e.g.,

  $r->add(entries => '/entries', { controller => 'Entries' }, methods => [qw/ GET POST /])

Method strings are case-insensitive. As a convenience, the allowed methods can also be specified
as part of the route path itself. e.g.,

  $r->add(entries => 'GET|POST /entries', { controller => 'Entries' })

=item match($url [, $method])

Attempts to find a route that matches the supplied $url. Routes are matched in the order defined.

If a match is found, its associated payload is returned. If not, undef is returned and the error() method will indicate why the match failed.

$method, if supplied, is the HTTP method of the request (e.g., GET, POST, etc.). Specifying $method may prevent a route from otherwise matching if the route was defined with a restricted set of allowed methods (see ROUTE DEFINITION). By default, all request methods are allowed.

=item error()

Returns the error code of the last failed match.

  404 = no match found
  405 = method not allowed

A 405 result indicates a match was found, but the request method was not allowed. allowed_methods() can be called to obtain a list of the methods that are permitted for the route.

=item allowed_methods([ $name ])

Returns the list of allowed methods for a given route name or path. In list context, returns a list. In scalar context, returns an array reference. An empty list/array indicates that all methods are
permitted.

If route $name is supplied, returns its permitted methods. Returns undef in scalar context if the route is unknown. If $name contains a forward slash, it's intepreted as a route path, instead.

With no argument, returns the methods permitted by the last match() attempt. Returns undef in scalar context if there was no prior match.

  $r->add(entries => 'PUT|GET /entries', { controller => 'Entries' });
  print join(', ', $r->allowed_methods('entries')), "\n"; # prints GET, PUT

=item url($name [, %params])

Constructs a URL from the $name route. Placeholder values are supplied as %params. Unknown placeholder values are appended as query string parameters.

Example:

  $r->add(entry => '/entries/{year}', { controller => 'Entry' });
  $r->url('entry', year => '1916', q => 'abc'); # produces /entries/1916?q=abc 

The return value is a L<URI> instance.

=item as_string()

Returns a report of the defined routes, in order of definition.

=item with($name => $route_path [, %options])

Helper method to prevent code duplication. Allows route information to be shared across multiple routes. For example:

  $r->with(admin => '/admin',        { controller => 'Admin' })
    ->add(users  => '/users',        { action => 'users' })
    ->add(trx    => '/transactions', { action => 'transactions' })
  ;

  print $r->as_string;

  # prints:
  #
  #   admin_users * /admin/users
  #   admin_trx   * /admin/transactions

The payload contents are merged. The route names are joined by an underscore. The paths are simply concatenated. Either or both of $name and $route_path may be undefined.

A callback is accepted, which allows chaining with() calls:

  $r->with(admin => '/admin',  { controller => 'Admin' }, call => sub {
    $_->add(users => '/users', { action => 'users' });
    $_->add(log   => '/log',   { action => 'log' });
  })->with(dashboard => '/dashboard', { controller => 'Admin::Dashboard' }, call => sub {
    $_->add(view => '/{action}');
  });

  print $r->as_string;

  # prints:
  #   admin_users          * /admin/users
  #   admin_log            * /admin/log
  #   admin_dashboard_view * /admin/dashboard/{action}

Within the callback function, $_ is set to the router instance. It is also supplied as a parameter.

=back

=head1 ROUTE DEFINITION

A route path is a normal URL path with the addition of placeholder variables. For example:

  $r->add(entries => '/entries/{year}/{month}');

defines a route path containing two placeholders, "year" and "month'. By default, a placeholder matches any string up to the next forward slash.

Placeholder names must not begin with a number, nor contain hyphens or forward slashes.

The default match rule may be overridden. For example:

  $r->add(entries => '/entries/{year:\d+}/{month:\d+}');

is the same as above, except it will only match if both the year and month contain only digits.

The special {.format} placeholder can be used to allow an optional file extension to be appended. For example:

  $r->add(download => '/dl/{file}{.format}', { controller => 'Download' });
  $r->match('/dl/foo.gz'); # returns { controller => 'Download', file => 'foo', format => 'gz' }
  $r->match('/dl/foo');    # returns { controller => 'Download', file => 'foo' }

  # And to build a URL from it:
  $r->url('download', file => 'foo', format => 'bz2'); # /dl/foo.bz2

=head1 SEE ALSO

Router::Right is based on Tokuhiro Matsuno's Router::Simple and Router::Boom modules.

This module seeks to implement most features of Python's Routes:
L<https://routes.readthedocs.io/en/latest/index.html>

=cut

# vim: set foldmethod=marker:
