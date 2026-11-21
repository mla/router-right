#!/usr/bin/env perl

# Two kinds of test, both about behaviour that is expected to change.
#
# "defects" assert the behaviour wanted and are marked TODO: they fail
# today, and each one passing unexpectedly is the signal to move it into
# the file for its subject.
#
# "undecided" pin what the code does today where the right behaviour is a
# design decision. Changing one of these should be deliberate.

use strict;
use warnings;
use Test::Spec;

my $CLASS = 'Router::Right';

use_ok $CLASS;

{
  package Router::Right::Test::Scoped;
  use parent -norequire, 'Router::Right';
  sub _submapper_class { 'Router::Right::Test::Scoped::Submapper' }

  package Router::Right::Test::Scoped::Submapper;
  use parent -norequire, 'Router::Right::Submapper';
}

describe 'defects' => sub {
  my $r;

  before each => sub {
    $r = $CLASS->new;
  };

  it 'url checks the whole placeholder value against its pattern' => sub {
    local $TODO = 'pattern is applied unanchored';
    $r->add(num => '/n/{id:\d+}', 'Num');

    eval { $r->url('num', id => 'abc1') };
    like $@, qr/invalid value for param 'id'/;
  };

  it 'url builds a path that matches back to the same value' => sub {
    local $TODO = 'placeholder values are not escaped';
    $r->add(user => '/users/{id}', 'User');

    foreach my $id ('a?b', 'a#b') {
      my $url   = eval { $r->url('user', id => $id) };
      my $match = $url && $r->match($url->path);
      (my $got = $match ? $match->{id} : '') =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;

      is $got, $id, "id '$id'";
    }
  };

  it 'url refuses a slash in a placeholder that cannot hold one' => sub {
    local $TODO = 'pattern is applied unanchored';
    $r->add(user => '/users/{id}', 'User');

    eval { $r->url('user', id => 'a/b') };
    like $@, qr/invalid value for param 'id'/;
  };

  it 'url drops an optional format passed undefined or empty' => sub {
    local $TODO = 'an empty value is checked against the pattern';
    $r->add(dl => '/dl/{file}{.format}', 'Download');

    is eval { $r->url('dl', file => 'foo', format => undef) }, '/dl/foo';
    is eval { $r->url('dl', file => 'foo', format => '') }, '/dl/foo';
  };

  it 'url refuses a format the route could not match back' => sub {
    local $TODO = 'pattern is applied unanchored';
    $r->add(dl => '/dl/{file}{.format}', 'Download');

    eval { $r->url('dl', file => 'foo', format => 'tar.gz') };
    like $@, qr/invalid value for param 'format'/;
  };

  it 'accepts a quantifier in a placeholder pattern' => sub {
    local $TODO = 'placeholder ends at the first closing brace';
    my $ok = eval {
      $r->add(code => '/c/{code:\d{3}}', 'Code');
      $r->match('/c/123') && !$r->match('/c/12');
    };

    ok $ok, 'matches three digits only';
  };

  it 'reports a bad placeholder pattern when the route is added' => sub {
    local $TODO = 'pattern is first compiled by match()';
    eval { $r->add(bad => '/b/{id:(}', 'Bad') };

    like $@, qr/placeholder|pattern/;
  };

  it 'uses the submapper class the router names' => sub {
    local $TODO = 'Submapper::new blesses into its own package';
    my $scoped = Router::Right::Test::Scoped->new;

    isa_ok $scoped->with(a => '/a', 'A'),
      'Router::Right::Test::Scoped::Submapper';
  };

  it 'answers can() for a router method called on a scope' => sub {
    local $TODO = 'forwarded through AUTOLOAD';

    ok $r->with(a => '/a', 'A')->can('url');
  };

  it 'refuses an unknown method on a match' => sub {
    local $TODO = 'AUTOLOAD returns undef for any name';
    $r->add(foo => '/foo', 'Foo');

    eval { $r->match('/foo')->no_such_field };
    like $@, qr/no_such_field/;
  };

  it 'answers can() for a route field on a match' => sub {
    local $TODO = 'fields are served through AUTOLOAD';
    $r->add(foo => '/foo', 'Foo');

    ok $r->match('/foo')->can('name');
  };

  it 'accepts a route named 0' => sub {
    local $TODO = 'name is tested for truth';
    $r->add(0 => '/zero', 'Zero');

    is eval { $r->url(0) }, '/zero';
  };
};

describe 'undecided' => sub {
  my $r;

  before each => sub {
    $r = $CLASS->new;
  };

  it 'a resource id containing a dot is split into id and format' => sub {
    $r->resource('user', 'User');

    my $match = $r->match('/users/john.smith', 'GET');
    is $match->{id}, 'john';
    is $match->{format}, 'smith';
  };

  it 'a formatted_ resource route is never the one matched' => sub {
    $r->resource('user', 'User');

    is $r->match('/users/7.json', 'GET')->name, 'user';
    is $r->match('/users.json', 'GET')->name, 'users';
  };

  it 'a resource puts the format before /edit' => sub {
    $r->resource('user', 'User');

    is $r->url('edit_user', id => 7, format => 'json'), '/users/7.json/edit';
    ok !$r->match('/users/7/edit.json', 'GET');
  };

  it 'a resource update takes PUT but not PATCH' => sub {
    $r->resource('user', 'User');

    ok $r->match('/users/7', 'PUT');
    ok !$r->match('/users/7', 'PATCH');
  };

  it 'a method refused by the first matching path is a 405, even ' .
     'when a later path takes it' => sub {
    $r->add(show    => 'GET /x/{id}', 'X#show');
    $r->add(special => 'POST /x/special', 'X#special');

    ok !$r->match('/x/special', 'POST');
    is $r->error, 405;
  };

  it 'a scope and its route combine their methods' => sub {
    $r->with(a => 'POST /a', 'A')->add(b => 'GET /b');

    is_deeply [ $r->allowed_methods('a_b') ], [qw/ GET POST /];
  };

  it 'two routes on one path and method are both kept' => sub {
    $r->add(first  => 'GET /foo', 'First');
    $r->add(second => 'GET /foo', 'Second');

    is scalar(() = $r->routes), 2;
    is $r->match('/foo', 'GET')->{controller}, 'First';
  };

  it 'a placeholder named controller is filled from the path' => sub {
    $r->add(any => '/c/{controller}', { action => 'index' });

    is $r->match('/c/Anything')->{controller}, 'Anything';
  };

  it 'a path spelled two ways is two groups for allowed_methods' => sub {
    $r->add(show   => 'GET /x/{id}', 'X#show');
    $r->add(update => 'PUT /x/{id:\d+}', 'X#update');

    ok !$r->match('/x/7', 'PUT');
    is_deeply [ $r->allowed_methods ], ['GET'];
  };
};

runtests unless caller;
