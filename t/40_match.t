#!/usr/bin/env perl

use strict;
use warnings;
use Test::Spec;

my $CLASS = 'Router::Right';

use_ok $CLASS;

{
  package Router::Right::Test::Plain;
  use parent -norequire, 'Router::Right';
  sub _match_class { undef }

  package Router::Right::Test::Coded;
  use parent -norequire, 'Router::Right';
  sub _match_class {
    sub {
      my ($router, $payload, $route) = @_;
      return { payload => $payload, name => $route->{name} };
    };
  }

  package Router::Right::Test::Custom;
  use parent -norequire, 'Router::Right';
  sub _match_class { 'Router::Right::Test::Custom::Match' }

  package Router::Right::Test::Custom::Match;
  use parent -norequire, 'Router::Right::Match';
  sub label { 'custom ' . $_[0]->name }
}

describe 'Router' => sub {
  my $r;

  before each => sub {
    $r = $CLASS->new;
  };

  describe 'match order' => sub {
    it 'gives a path to the route defined first' => sub {
      $r->add(any  => '/x/{id}', 'Any');
      $r->add(lit  => '/x/new', 'Literal');

      is $r->match('/x/new')->{controller}, 'Any';
    };

    it 'gives a literal defined first its own path' => sub {
      $r->add(lit  => '/x/new', 'Literal');
      $r->add(any  => '/x/{id}', 'Any');

      is $r->match('/x/new')->{controller}, 'Literal';
      is $r->match('/x/7')->{controller}, 'Any';
    };

    it 'gives a literal its path when an earlier pattern refuses it' => sub {
      $r->add(num => '/x/{id:\d+}', 'Number');
      $r->add(lit => '/x/new', 'Literal');

      is $r->match('/x/new')->{controller}, 'Literal';
      is $r->match('/x/7')->{controller}, 'Number';
    };

    it 'takes a route added after a match, in the order defined' => sub {
      $r->add(lit => '/x/new', 'Literal');
      is $r->match('/x/new')->{controller}, 'Literal';

      $r->add(any  => '/x/{id}', 'Any');
      $r->add(late => '/x/late', 'Late');

      is $r->match('/x/new')->{controller}, 'Literal';
      is $r->match('/x/late')->{controller}, 'Any';
    };

    it 'matches a literal path exactly' => sub {
      $r->add(lit => '/x/new', 'Literal');

      ok !$r->match($_), "'$_'" foreach '/x/new/', '/x/New', "/x/new\n", '/x';
    };

    it 'matches with literal routes alone, or none' => sub {
      ok !$r->match('/x');

      $r->add(lit => '/x', 'Literal');
      is $r->match('/x')->{controller}, 'Literal';
      ok !$r->match('/y');
      is $r->error, 404;
    };

    it 'falls through a pattern that refuses the value' => sub {
      $r->add(num  => '/x/{id:\d+}', 'Number');
      $r->add(word => '/x/{slug}', 'Word');

      is $r->match('/x/42')->{controller}, 'Number';
      is $r->match('/x/abc')->{controller}, 'Word';
    };

    it 'matches the whole path only' => sub {
      $r->add(foo => '/foo', 'Foo');

      ok !$r->match('/foo/');
      ok !$r->match('/foo/bar');
      ok !$r->match('/fo');
      ok !$r->match('x/foo');
      ok !$r->match('');
    };

    it 'treats regex metacharacters in a path literally' => sub {
      $r->add(dots => '/a.b/c+d/(e)', 'Dots');

      ok $r->match('/a.b/c+d/(e)');
      ok !$r->match('/aXb/c+d/(e)');
      ok !$r->match('/a.b/ccd/(e)');
    };

    it 'sees routes added after the first match' => sub {
      $r->add(foo => '/foo', 'Foo');
      ok !$r->match('/bar');

      $r->add(bar => '/bar', 'Bar');
      is $r->match('/bar')->{controller}, 'Bar';
    };

    it 'never matches with no routes' => sub {
      ok !$r->match('/');
      is $r->error, 404;
    };
  };

  describe 'placeholders' => sub {
    it 'can open the path' => sub {
      $r->add(icon => '{splat:.*}/favicon.ico', 'Icon');
      $r->add(home => '/', 'Home');

      is_deeply $r->match('/favicon.ico'),
        { controller => 'Icon', splat => '' };
      is_deeply $r->match('/a/b/favicon.ico'),
        { controller => 'Icon', splat => '/a/b' };
      is_deeply $r->match('/'), { controller => 'Home' };
    };

    it 'can be the whole path' => sub {
      $r->add(page => '{page:/[a-z]+}', 'Page');

      is_deeply $r->match('/about'),
        { controller => 'Page', page => '/about' };
      ok !$r->match('/about/us');
    };

    it 'can span slashes when the pattern allows' => sub {
      $r->add(blob => '/blob/{path:.+}', 'Blob');

      is $r->match('/blob/a/b/c.txt')->{path}, 'a/b/c.txt';
      ok !$r->match('/blob/');
    };

    it 'can sit inside a segment' => sub {
      $r->add(icon => '/icon{size:(?:-\d+)?}.png', 'Icon');

      is $r->match('/icon.png')->{size}, '';
      is $r->match('/icon-180.png')->{size}, '-180';
      ok !$r->match('/icon-big.png');
    };

    it 'can sit side by side' => sub {
      $r->add(range => '/range/{from:\d+}-{to:\d+}', 'Range');

      is_deeply $r->match('/range/10-20'),
        { controller => 'Range', from => 10, to => 20 };
    };

    it 'accepts braces in a pattern' => sub {
      $r->add(code => '/c/{code:\d{3}}', 'Code');
      $r->add(pair => '/p/{pair:[a-z]{1,2}-\d{2,}}', 'Pair');

      ok $r->match('/c/123');
      ok !$r->match('/c/12');
      ok !$r->match('/c/1234');
      is $r->match('/p/ab-123')->{pair}, 'ab-123';
      is $r->url('code', code => 123), '/c/123';
    };

    it 'accepts alternation in a pattern' => sub {
      $r->add(kind => '/k/{kind:booking|posting}/{id}', 'Kind');

      is $r->match('/k/posting/5')->{kind}, 'posting';
      ok !$r->match('/k/offer/5');
      ok !$r->match('/k/bookingx/5');
    };

    it 'does not percent-decode what it captures' => sub {
      $r->add(entry => '/e/{id}', 'Entry');

      is $r->match('/e/a%20b')->{id}, 'a%20b';
    };

    it 'takes its value over a payload key of the same name' => sub {
      $r->add(act => '/c/{action}', 'Ctl#fixed');

      is $r->match('/c/other')->{action}, 'other';
    };

    it 'leaves the route payload untouched by a match' => sub {
      $r->add(act => '/c/{action}', 'Ctl#fixed');
      $r->match('/c/other');

      is $r->_route('act')->{payload}{action}, 'fixed';
    };
  };

  describe 'a capture named inside a pattern' => sub {
    it 'is returned beside the placeholder' => sub {
      $r->add(day => '/d/{date:(?<year>\d{4})-(?<month>\d\d)}', 'Day');

      is_deeply $r->match('/d/1916-08'), {
        controller => 'Day',
        date       => '1916-08',
        year       => 1916,
        month      => '08',
      };
    };
  };

  describe 'a placeholder' => sub {
    it 'replaces a payload value of the same name' => sub {
      $r->add(any => '/c/{controller}/{action}', 'Default#index');

      is_deeply $r->match('/c/Thing/list'),
        { controller => 'Thing', action => 'list' };
    };
  };

  describe 'format placeholder' => sub {
    before each => sub {
      $r->add(dl => '/dl/{file}{.format}', 'Download');
    };

    it 'is left out of the payload when absent' => sub {
      is_deeply $r->match('/dl/foo'),
        { controller => 'Download', file => 'foo' };
    };

    it 'refuses a trailing dot with no extension' => sub {
      is $r->match('/dl/foo.')->{file}, 'foo.';
    };

    it 'accepts its own pattern' => sub {
      $r->add(cal => '/cal/{id}{.format:ics}', 'Calendar');

      is $r->match('/cal/7.ics')->{format}, 'ics';
      is $r->match('/cal/7.pdf')->{id}, '7.pdf';
    };
  };

  describe 'methods' => sub {
    it 'are matched case-insensitively' => sub {
      $r->add(foo => 'get /foo', 'Foo');

      ok $r->match('/foo', 'GET');
      ok $r->match('/foo', 'get');
      is_deeply [ $r->allowed_methods('foo') ], ['GET'];
    };

    it 'accept a comma as separator' => sub {
      $r->add(foo => 'GET,POST /foo', 'Foo');

      is_deeply [ $r->allowed_methods('foo') ], [qw/ GET POST /];
    };

    it 'combine the path prefix with the methods option' => sub {
      $r->add(foo => 'GET /foo', 'Foo', methods => 'POST');

      is_deeply [ $r->allowed_methods('foo') ], [qw/ GET POST /];
    };

    it 'are listed once and sorted' => sub {
      $r->add(foo => 'PUT|GET|put /foo', 'Foo');

      is_deeply [ $r->allowed_methods('foo') ], [qw/ GET PUT /];
    };

    it 'accept * for any method' => sub {
      $r->add(foo => '* /foo', 'Foo');

      is_deeply [ $r->allowed_methods('foo') ], [];
      ok $r->match('/foo', 'DELETE');
    };

    it 'pick the route for the method when a path is defined twice' =>
      sub {
        $r->add(show   => 'GET /foo', 'Foo#show');
        $r->add(update => 'PUT /foo', 'Foo#update');

        is $r->match('/foo', 'GET')->{action}, 'show';
        is $r->match('/foo', 'PUT')->{action}, 'update';
        is_deeply [ $r->allowed_methods('/foo') ], [qw/ GET PUT /];
      };

    it 'give a path to a later route when the first refuses the method' =>
      sub {
        $r->add(show    => 'GET /x/{id}', 'X#show');
        $r->add(special => 'POST /x/special', 'X#special');
        $r->add(update  => 'PUT /x/{id:\d+}', 'X#update');

        is $r->match('/x/special', 'POST')->{action}, 'special';
        is $r->match('/x/special', 'GET')->{action}, 'show';
        is_deeply $r->match('/x/7', 'PUT'),
          { controller => 'X', action => 'update', id => 7 };
        is $r->match('/x/7', 'PUT')->name, 'update';
        ok !$r->error;
      };

    it 'give a method a restricted route refuses to a wider one after it' =>
      sub {
        $r->add(remove => 'POST /x/{id}/delete', 'X#delete');
        $r->add(any    => '/x/{id}/{action}', 'X');

        is $r->match('/x/7/delete', 'POST')->name, 'remove';
        is $r->match('/x/7/delete', 'GET')->name, 'any';
      };

    it 'report every method the path takes when none of them fits' => sub {
      $r->add(show    => 'GET /x/{id}', 'X#show');
      $r->add(special => 'POST /x/special', 'X#special');
      $r->add(update  => 'PUT /x/{id:\d+}', 'X#update');

      ok !$r->match('/x/special', 'DELETE');
      is $r->error, 405;
      is_deeply [ $r->allowed_methods ], [qw/ GET POST /];

      ok !$r->match('/x/7', 'DELETE');
      is_deeply [ $r->allowed_methods ], [qw/ GET PUT /];

      ok $r->match('/x/7', 'GET');
      is_deeply [ $r->allowed_methods ], ['GET'];
    };

    describe 'with legacy_methods' => sub {
      before each => sub {
        $r = $CLASS->new(legacy_methods => 1);
      };

      it 'refuse a method the first matching path does not take, though ' .
         'a later path takes it' => sub {
        $r->add(remove => 'POST /x/{id}/delete', 'X#delete');
        $r->add(any    => '/x/{id}/{action}', 'X');

        is $r->match('/x/7/delete', 'POST')->name, 'remove';
        ok !$r->match('/x/7/delete', 'GET');
        is $r->error, 405;
        is_deeply [ $r->allowed_methods ], ['POST'];
        is $r->match('/x/7/other', 'GET')->{action}, 'other';
      };

      it 'refuse a method for a literal path a later pattern would take' =>
        sub {
          $r->add(lit => 'POST /x/special', 'X#special');
          $r->add(any => '/x/{id}', 'X#show');

          ok !$r->match('/x/special', 'GET');
          is $r->error, 405;
        };

      it 'treat a path written two ways as two paths' => sub {
        $r->add(show   => 'GET /x/{id}', 'X#show');
        $r->add(update => 'PUT /x/{id:\d+}', 'X#update');

        ok !$r->match('/x/7', 'PUT');
        is $r->error, 405;
        is_deeply [ $r->allowed_methods ], ['GET'];
      };

      it 'share one set of routes with a scope' => sub {
        $r->with(a => '/a', 'A')->add(b => 'POST /{id}', '#b');
        $r->add(any => '/a/{rest}', 'Any');

        ok !$r->match('/a/7', 'GET');
        is $r->match('/a/7', 'post')->{action}, 'b';
        ok !$r->match('/nope', 'GET');
        is $r->error, 404;
        is $r->match('/a/7')->{action}, 'b';
      };
    };

    it 'are matched in any letter case' => sub {
      $r->add(show => 'get /foo', 'Foo#show');

      is $r->match('/foo', 'Get')->{action}, 'show';
    };

    it 'give a method no route names to a route taking every method' => sub {
      $r->add(show => 'GET /foo', 'Foo#show');
      $r->add(any  => '/bar', 'Bar#any');

      is $r->match('/bar', 'PROPFIND')->{action}, 'any';
      ok !$r->match('/foo', 'PROPFIND');
      is $r->error, 405;
      ok !$r->match('/baz', 'PROPFIND');
      is $r->error, 404;
    };

    it 'tell a path no route has from a method its routes refuse' => sub {
      $r->add(lit => 'GET /foo', 'Foo#show');
      $r->add(dyn => 'GET /x/{id}', 'X#show');

      foreach ([ '/foo' => 405 ], [ '/x/7' => 405 ], [ '/nope' => 404 ],
               [ '/x/7/8' => 404 ]) {
        my ($path, $status) = @$_;
        ok !$r->match($path, 'POST');
        is $r->error, $status, "POST $path";
      }
    };

    it 'take a route added after a match for the same method' => sub {
      $r->add(show => 'GET /foo', 'Foo#show');
      ok !$r->match('/foo', 'POST');

      $r->add(create => 'POST /foo', 'Foo#create');
      is $r->match('/foo', 'POST')->{action}, 'create';
    };

    it 'give the first route when no method is supplied' => sub {
      $r->add(show   => 'GET /foo', 'Foo#show');
      $r->add(update => 'PUT /foo', 'Foo#update');

      is $r->match('/foo')->{action}, 'show';
    };

    it 'report 405 and what is allowed when none fits' => sub {
      $r->add(show   => 'GET /foo', 'Foo#show');
      $r->add(update => 'PUT /foo', 'Foo#update');

      ok !$r->match('/foo', 'DELETE');
      is $r->error, Router::Right::METHOD_NOT_ALLOWED();
      is_deeply [ $r->allowed_methods ], [qw/ GET PUT /];
    };

    it 'do not imply HEAD from GET' => sub {
      $r->add(foo => 'GET /foo', 'Foo');

      ok !$r->match('/foo', 'HEAD');
      is $r->error, 405;
    };
  };

  describe 'error' => sub {
    it 'is cleared by the next successful match' => sub {
      $r->add(foo => '/foo', 'Foo');

      $r->match('/nope');
      is $r->error, Router::Right::NOT_FOUND();

      $r->match('/foo');
      is $r->error, undef;
    };

    it 'exports its codes on request' => sub {
      Router::Right->import(qw/ NOT_FOUND METHOD_NOT_ALLOWED /);

      is NOT_FOUND(), 404;
      is METHOD_NOT_ALLOWED(), 405;
    };
  };

  describe 'match result' => sub {
    before each => sub {
      $r->add(entry => 'GET /e/{id}', 'Entry#show');
    };

    it 'is a copy the caller may change' => sub {
      my $match = $r->match('/e/1');
      $match->{controller} = 'Changed';
      $match->{extra} = 1;

      is_deeply $r->match('/e/2'),
        { controller => 'Entry', action => 'show', id => 2 };
    };

    it 'exposes the route it came from' => sub {
      my $match = $r->match('/e/1', 'GET');

      is $match->name, 'entry';
      is $match->path, '/e/{id}';
      is_deeply $match->methods, ['GET'];
      is_deeply $match->payload, { controller => 'Entry', action => 'show' };
    };

    it 'refuses an unknown method' => sub {
      eval { $r->match('/e/1')->no_such_field };
      like $@, qr/no_such_field/;
    };

    it 'answers can() for each route field' => sub {
      my $match = $r->match('/e/1');

      ok $match->can($_), $_
        foreach qw/ name path methods payload route index regex args /;
    };

    it 'keeps each result tied to its own route' => sub {
      $r->add(other => '/o/{id}', 'Other');

      my $first  = $r->match('/e/1');
      my $second = $r->match('/o/1');

      is $first->name, 'entry';
      is $second->name, 'other';
    };

    it 'is a plain hash when the match class is undefined' => sub {
      my $plain = Router::Right::Test::Plain->new;
      $plain->add(entry => '/e/{id}', 'Entry');

      my $match = $plain->match('/e/1');
      is ref $match, 'HASH';
      is_deeply $match, { controller => 'Entry', id => 1 };
    };

    it 'is whatever a code ref match class returns' => sub {
      my $coded = Router::Right::Test::Coded->new;
      $coded->add(entry => '/e/{id}', 'Entry');

      is_deeply $coded->match('/e/1'), {
        payload => { controller => 'Entry', id => 1 },
        name    => 'entry',
      };
    };

    it 'is blessed into a custom match class' => sub {
      my $custom = Router::Right::Test::Custom->new;
      $custom->add(entry => '/e/{id}', 'Entry');

      my $match = $custom->match('/e/1');
      isa_ok $match, 'Router::Right::Test::Custom::Match';
      is $match->label, 'custom entry';
    };
  };

  describe 'routes' => sub {
    it 'lists every route, grouped by path in definition order' => sub {
      $r->add(a_get => 'GET /a', 'A#show');
      $r->add(b     => '/b', 'B');
      $r->add(a_put => 'PUT /a', 'A#update');

      is_deeply [ map { $_->{name} } $r->routes ], [qw/ a_get a_put b /];
    };

    it 'describes each route' => sub {
      $r->add(entry => 'GET /e/{id}', 'Entry#show');

      my ($route) = $r->routes;
      is $route->{name}, 'entry';
      is $route->{path}, '/e/{id}';
      is_deeply $route->{methods}, ['GET'];
      is_deeply $route->{payload}, { controller => 'Entry', action => 'show' };
      is $route->{route}[0], '/e/';
      is $route->{route}[1]{pname}, 'id';
    };
  };

  describe 'as_string' => sub {
    it 'shows * for a route that takes any method' => sub {
      $r->add(foo => '/foo', 'Foo');

      like $r->as_string, qr/^foo \* \/foo \{ controller => "Foo" \}$/m;
    };

    it 'leaves the name blank for an unnamed route' => sub {
      $r->add(undef, 'POST /foo', 'Foo');

      like $r->as_string, qr/^ POST \/foo /m;
    };

    it 'keeps a multi-line payload on one line' => sub {
      $r->add(foo => '/foo', {
        controller => 'A' x 30,
        action     => 'b' x 30,
        other      => 'c' x 30,
      });

      is scalar(() = $r->as_string =~ /\n/g), 1;
    };

    it 'is empty with no routes' => sub {
      is $r->as_string, '';
    };
  };

  describe 'new' => sub {
    it 'called on an instance starts an empty router' => sub {
      $r->add(foo => '/foo', 'Foo');
      my $other = $r->new;

      isa_ok $other, $CLASS;
      ok !$other->match('/foo');
      ok $r->match('/foo');
    };

    it 'keeps two routers apart' => sub {
      my $other = $CLASS->new;
      $r->add(foo => '/foo', 'Foo');
      $other->add(bar => '/bar', 'Bar');

      ok $r->match('/foo');
      ok $other->match('/bar');
      ok !$r->match('/bar');
      ok !$other->match('/foo');
    };

    describe 'with legacy' => sub {
      my $routes = sub {
        my $router = shift;
        $router->add(remove => 'POST /x/{id}/delete', 'X#delete');
        $router->add(any    => '/x/{id}/{action}', 'X');
        $router->resource('message', 'Message');
        return $router;
      };

      it 'keeps the methods rule and the resource routes of 1.05' => sub {
        my $legacy = $routes->($CLASS->new(legacy => 1));

        ok !$legacy->match('/x/7/delete', 'GET');
        is $legacy->error, 405;
        is $legacy->url('edit_message', id => 7), '/messages/7/edit';
        ok $legacy->url('formatted_messages', format => 'json');
      };

      it 'lets one of the two be turned off' => sub {
        my $half = $routes->($CLASS->new(legacy => 1, legacy_resources => 0));

        ok !$half->match('/x/7/delete', 'GET');
        is $half->url('message_edit', id => 7), '/messages/7/edit';

        $half = $routes->($CLASS->new(legacy => 1, legacy_methods => 0));

        is $half->match('/x/7/delete', 'GET')->name, 'any';
        is $half->url('edit_message', id => 7), '/messages/7/edit';
      };

      it 'warns of a route that can never match, and keeps it' => sub {
        my $legacy = $CLASS->new(legacy => 1);
        $legacy->add(first => 'GET /foo', 'First');

        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $legacy->add(second => 'GET /foo', 'Second');

        like $warnings[0], qr/route 'second' can never match/;
        is scalar @warnings, 1;
        is $legacy->url('second'), '/foo';
        is $legacy->match('/foo', 'GET')->{controller}, 'First';
      };

      it 'refuses that route when only the narrower switches are on' => sub {
        my $narrow = $CLASS->new(legacy_methods => 1, legacy_resources => 1);
        $narrow->add(first => 'GET /foo', 'First');

        eval { $narrow->add(second => 'GET /foo', 'Second') };
        like $@, qr/can never match/;
      };
    };
  };
};

runtests unless caller;
