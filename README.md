# NAME

Router::Right - Fast, framework-agnostic URL routing engine for web applications

# VERSION

version 0.01

# SYNOPSIS

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

# DESCRIPTION

Router::Right is a Perl-based, framework-agnostic routing engine used to
map web application request URLs to application handlers.

# METHODS

- new()

    Returns a new Router::Right instance

- add($name => $route\_path, payload => \\%payload \[, %options\])

    Define a route. $name is used to reference the route elsewhere.
    On a successful match, the payload hash reference is returned; its contents are
    completely user-defined and may contain anything.

    See the ROUTE DEFINITION section for details on how $route\_path values are
    specified.

    As a convenience, the payload field name may be omitted. i.e., 
    add($name => $route\_path, \\%payload)

- match($url \[, $method\])

    Attempts to find a route that matches the supplied $url. Routes are
    matched in the order defined.

    If a match is found, its associated payload is returned. If not, undef
    is returned and the error() method can be checked to see why the match
    failed.

    $method, if supplied, is the HTTP method of the request
    (e.g., GET, POST, etc.). Specifying $method may prevent a route
    from otherwise matching if the route was defined with a restricted set of allowed
    methods (see ROUTE DEFINITION). By default, all request methods are allowed.

- error()

    Returns the error code of the last failed match.

        404 = no match found
        405 = method not allowed

    A 405 result indicates a match was found, but the request method was
    not allowed. allowed\_methods() can be called to obtain a list of the methods
    that are allowed by the route.

- allowed\_methods()

    Returns the methods allowed by the last matched route.
    Returns a list in array context and an array reference in scalar context.

    An empty list indicates that all methods are accepted.

- url($name \[, %params\])

    Constructs a URL from the $name route. Placeholder values are supplied as
    %params. Unknown placeholder values are appended as query string parameters.

    Example:

        $r->add(entry => '/entries/{year}', { controller => 'Entry' });
        $r->url('entry', year => '1916', q => 'abc'); # produces /entries/1916?q=abc 

    The return value is a [URI](https://metacpan.org/pod/URI) instance.

- as\_string()

    Returns a report of the defined routes, in order of definition.

- with($name => $route\_path \[, %options\])

    Helper method to prevent code duplication. Allows route information to be
    shared across multiple routes. For example:

        $r->with(admin => '/admin',        { controller => 'Admin' })
          ->add(users  => '/users',        { action => 'users' })
          ->add(trx    => '/transactions', { action => 'transactions' })
        ;

        print $r->as_string;

        # prints:
        #
        #   admin_users * /admin/users
        #   admin_trx   * /admin/transactions

    The payload contents are merged. The route names are joined by an underscore.
    The paths are simply concatenated.

    Either or both of $name and $route\_path may be undefined.

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

    Within the callback function, $\_ is set to the router instance.
    It is also supplied as a parameter.

# ROUTE DEFINITION

A route path is a normal URL path with the addition of placeholder variables.
For example:

    $r->add(entries => '/entries/{year}/{month}');

defines a route path containing two placeholders, "year" and "month'.
By default, a placeholder matches any string up to the next forward slash.

Placeholder names must not begin with a number, nor contain hyphens.

The default match rule may be overridden. For example:

    $r->add(entries => '/entries/{year:\d+}/{month:\d+}');

is the same as above, except it will only match if both the year and month
contain only digits.

The special {.format} placeholder can be used to allow an optional file
extension to be added. For example:

    $r->add(download => '/dl/{file}{.format}', { controller => 'Download' });
    $r->match('/dl/foo.gz'); # returns { controller => 'Download', file => 'foo', format => 'gz' }
    $r->match('/dl/foo');    # returns { controller => 'Download', file => 'foo' }

    # And to build a URL from it:
    $r->url('download', file => 'foo', format => 'bz2'); # /dl/foo.bz2

# SEE ALSO

Router::Right is based on Tokuhiro Matsuno's Router::Simple and
Router::Boom modules.

Python's Routes module:
[https://routes.readthedocs.io/en/latest/index.html](https://routes.readthedocs.io/en/latest/index.html)

# AUTHOR

Maurice Aubrey <maurice.aubrey@gmail.com>

# COPYRIGHT AND LICENSE

This software is copyright (c) 2016 by Maurice Aubrey.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

[![Build Status](https://travis-ci.org/mla/router-right.svg?branch=master)](https://travis-ci.org/mla/router-right)
