#!/usr/bin/env perl

# Every way a route definition or a lookup is refused.

use strict;
use warnings;
use Test::Spec;

my $CLASS = 'Router::Right';

use_ok $CLASS;

describe 'Router' => sub {
  my $r;

  before each => sub {
    $r = $CLASS->new;
  };

  describe 'add' => sub {
    it 'requires a payload' => sub {
      eval { $r->add(foo => '/foo') };
      like $@, qr/no payload defined/;
    };

    it 'refuses a path that does not start with a slash or placeholder' =>
      sub {
        eval { $r->add(foo => 'foo', 'Foo') };
        like $@, qr/invalid route path specification 'foo'/;
      };

    it 'refuses a placeholder name containing a slash' => sub {
      eval { $r->add(foo => '/foo/{a/b}', 'Foo') };
      like $@, qr{invalid placeholder name 'a/b'};
    };

    it 'refuses a placeholder with no name' => sub {
      eval { $r->add(foo => '/foo/{:\d+}', 'Foo') };
      like $@, qr/invalid placeholder ':\\d\+'/;
    };

    it 'refuses a format placeholder beside a plain one of that name' =>
      sub {
        eval { $r->add(foo => '/foo/{format}{.format}', 'Foo') };
        like $@, qr/placeholder 'format' redefined/;
      };

    it 'keeps working after a refused route' => sub {
      eval { $r->add(bad => '/bad/{a/b}', 'Bad') };
      $r->add(ok => '/ok', 'OK');

      is_deeply $r->match('/ok'), { controller => 'OK' };
      ok !$r->match('/bad/1');
      is scalar(() = $r->routes), 1;
    };

    it 'leaves the first route in place when a name is reused' => sub {
      $r->add(foo => '/first', 'First');
      eval { $r->add(foo => '/second', 'Second') };

      is $r->url('foo'), '/first';
      ok !$r->match('/second');
    };
  };

  describe 'url' => sub {
    it 'requires a name' => sub {
      eval { $r->url };
      like $@, qr/no url name supplied/;
    };

    it 'requires every placeholder' => sub {
      $r->add(entry => '/entries/{year}/{month}', 'Entry');

      eval { $r->url('entry', year => 1916) };
      like $@, qr/required param 'month' missing from url 'entry'/;
    };

    it 'refuses an undefined placeholder value' => sub {
      $r->add(entry => '/entries/{year}', 'Entry');

      eval { $r->url('entry', year => undef) };
      like $@, qr/invalid value for param 'year'/;
    };

    it 'refuses an empty placeholder value' => sub {
      $r->add(entry => '/entries/{year}', 'Entry');

      eval { $r->url('entry', year => '') };
      like $@, qr/invalid value for param 'year'/;
    };
  };

  describe 'resource' => sub {
    it 'requires a member name' => sub {
      eval { $r->resource };
      like $@, qr/no resource member name supplied/;
    };

    it 'accepts no controller, leaving only the action' => sub {
      $r->resource('message');

      is_deeply $r->match('/messages', 'GET'), { action => 'index' };
    };

    it 'requires a member name when nested' => sub {
      eval { $r->with(admin => '/admin', 'Admin')->resource };
      like $@, qr/no resource member name supplied/;
    };
  };

  describe 'with' => sub {
    it 'refuses a nested route with no path' => sub {
      eval { $r->with(admin => '/admin', 'Admin')->add('users') };
      like $@, qr/no route supplied/;
    };

    it 'refuses a nested route that repeats a name' => sub {
      my $admin = $r->with(admin => '/admin', 'Admin');
      $admin->add(users => '/users');

      eval { $admin->add(users => '/people') };
      like $@, qr/route 'admin_users' already defined/;
    };
  };

  describe 'allowed_methods' => sub {
    it 'is empty for an unknown route name' => sub {
      is_deeply [ $r->allowed_methods('nope') ], [];
      is scalar($r->allowed_methods('nope')), undef;
    };

    it 'is empty for an unknown route path' => sub {
      is_deeply [ $r->allowed_methods('/nope') ], [];
    };

    it 'is empty before any match' => sub {
      is_deeply [ $r->allowed_methods ], [];
    };

    it 'is empty after a failed match' => sub {
      $r->add(foo => 'GET /foo', 'Foo');
      $r->match('/foo', 'GET');
      $r->match('/nope', 'GET');

      is_deeply [ $r->allowed_methods ], [];
    };
  };
};

runtests unless caller;
