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

    it 'refuses a placeholder name that is not an identifier' => sub {
      foreach my $name ('a-b', '1st', 'a b') {
        eval { $r->add(foo => "/foo/{$name}", 'Foo') };
        like $@, qr/invalid placeholder name '\Q$name\E'/, "'$name'";
      }
    };

    it 'refuses an unbalanced brace' => sub {
      eval { $r->add(foo => '/foo/{id', 'Foo') };
      like $@, qr/unbalanced brace in route path '\/foo\/\{id'/;

      eval { $r->add(bar => '/bar/{id:\d{3}', 'Bar') };
      like $@, qr/unbalanced brace/;
    };

    it 'refuses a placeholder pattern that does not compile' => sub {
      eval { $r->add(foo => '/foo/{id:(}', 'Foo') };
      like $@, qr/invalid pattern for placeholder 'id'/;
    };

    it 'refuses a bad pattern before the route is stored' => sub {
      eval { $r->add(foo => '/foo/{id:(}', 'Foo') };

      is scalar(() = $r->routes), 0;
      ok !$r->match('/foo/1');
    };

    it 'refuses an empty path outside a scope' => sub {
      eval { $r->add(foo => '', 'Foo') };
      like $@, qr/no route path supplied/;
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

    it 'refuses a value its pattern matches only in part' => sub {
      $r->add(num => '/n/{id:\d+}', 'Num');

      eval { $r->url('num', id => 'abc1') };
      like $@, qr/invalid value for param 'id'/;
    };

    it 'refuses a slash in a placeholder that cannot hold one' => sub {
      $r->add(user => '/users/{id}', 'User');

      eval { $r->url('user', id => 'a/b') };
      like $@, qr/invalid value for param 'id'/;
    };

    it 'refuses a format the route could not match back' => sub {
      $r->add(dl => '/dl/{file}{.format}', 'Download');

      eval { $r->url('dl', file => 'foo', format => 'tar.gz') };
      like $@, qr/invalid value for param 'format'/;
    };

    it 'refuses an empty placeholder value' => sub {
      $r->add(entry => '/entries/{year}', 'Entry');

      eval { $r->url('entry', year => '') };
      like $@, qr/invalid value for param 'year'/;
    };
  };

  describe 'a placeholder pattern that refers to a group' => sub {
    foreach my $pattern (
      '([a-c])\1', '([a-c])\g1', '([a-c])\g{-1}', '(?<q>a)\k<q>',
      "(?<q>a)\\k'q'", '(?<q>a)\g{q}', '(?P<q>a)(?P=q)', '(a)(?1)',
      '(a)(?-1)', '(?+1)(a)', '\((?:[^()]|(?R))*\)', '(?<q>a)(?&q)',
      '(?<q>a)(?P>q)', '(a)?(?(1)b|c)', '(?<q>a)?(?(<q>)b|c)',
      '(?(DEFINE)(?<d>a))(?&d)', '(a)(?(R1)b|c)', '(a)(?0)',
    ) {
      it "is refused: $pattern" => sub {
        eval { $r->add(x => "/x/{p:$pattern}", 'X') };
        like $@, qr/pattern for placeholder 'p' refers to a group/;
      };
    }

    foreach my $pattern ('a\\\\1', '[\1a]', '(?(?=a)ab|c)', '(?<q>a)b', '(?:a)(b)') {
      it "is not refused for what only looks like one: $pattern" => sub {
        ok eval { $r->add(x => "/x/{p:$pattern}", 'X'); 1 }, $@;
      };
    }
  };

  describe 'two default placeholders in one segment' => sub {
    foreach my $path ('/a/{x}{y}', '/a/{x}-{y}', '/a/{x}.{y}{.format}',
                      '/a/{w}/b{x}c{y}d/e') {
      it "are refused: $path" => sub {
        eval { $r->add(x => $path, 'X') };
        like $@, qr/placeholders '\w' and '\w' in route '\Q$path\E' share a segment/;
      };
    }

    foreach my $path ('/a/{x}/{y}', '/a/{id}{.format}', '/a/{x}-{y:\d+}',
                      '/a/{c}{rest:/.*}', '/a/{x:[^/-]+}-{y:[^/-]+}') {
      it "are not what this refuses: $path" => sub {
        ok eval { $r->add(x => $path, 'X'); 1 }, $@;
      };
    }

    it 'are added with a warning under legacy' => sub {
      my $legacy = $CLASS->new(legacy => 1);
      my @warnings;
      local $SIG{__WARN__} = sub { push @warnings, @_ };

      $legacy->add(x => '/a/{x}-{y}', 'X');

      like $warnings[0], qr/share a segment/;
      is $legacy->match('/a/b-c')->{y}, 'c';
    };
  };

  describe 'a placeholder pattern with a backtracking verb' => sub {
    foreach my $pattern (
      '[a-z]+(*ACCEPT)', 'a(*COMMIT)b', 'a(*PRUNE)b', 'a(*SKIP)b',
      'a(*FAIL)|b', 'a(*F)|b', 'a(*MARK:x)b', 'a(*:x)b', 'a(*THEN)b|c',
      'a(*PRUNE:x)b',
    ) {
      it "is refused: $pattern" => sub {
        eval { $r->add(x => "/x/{p:$pattern}", 'X') };
        like $@, qr/pattern for placeholder 'p' uses a backtracking verb/;
      };
    }

    foreach my $pattern ('\\(*ACCEPT\\)', '[(*]ACCEPT', 'a\\(\\*COMMIT') {
      it "is not refused for what only looks like one: $pattern" => sub {
        ok eval { $r->add(x => "/x/{p:$pattern}", 'X'); 1 }, $@;
      };
    }

    it 'is not refused for a lower-case assertion' => sub {
      plan skip_all => 'needs Perl 5.28' if $] < 5.028;
      ok eval { $r->add(x => '/x/{p:(*pla:a)[a-z]+}', 'X'); 1 }, $@;
      ok $r->match('/x/ab');
      ok !$r->match('/x/ba');
    };

    it 'cannot send a request to another route' => sub {
      $r->add(home  => '/', 'Home');
      $r->add(purge => 'POST /admin/{id}/purge', 'Admin#purge');
      eval { $r->add(s => '/s/{x:[a-z]+(*ACCEPT)}', 'S') };

      ok !$r->match('/s/abc', 'POST');
    };
  };

  describe 'a route that can never match' => sub {
    it 'is refused when an earlier one takes its path and methods' => sub {
      $r->add(first => 'GET /foo', 'First');

      eval { $r->add(second => 'GET /foo', 'Second') };
      like $@, qr/route 'second' can never match: 'first' already takes GET \/foo/;
    };

    it 'is refused behind a route that takes every method' => sub {
      $r->add(undef, '/foo', 'First');

      eval { $r->add(second => 'POST /foo', 'Second') };
      like $@, qr/'second' can never match: with no name already takes POST/;

      eval { $r->add(third => '/foo', 'Third') };
      like $@, qr/'third' can never match: .* takes every method on \/foo/;
    };

    it 'is accepted as a second name for the same payload' => sub {
      $r->add(undef, 'GET /foo', 'First#show');
      $r->add(foo => 'GET /foo', { controller => 'First', action => 'show' });

      is $r->url('foo'), '/foo';
      is scalar(() = $r->routes), 2;
    };

    it 'is accepted when it takes a method the earlier one does not' => sub {
      $r->add(first => 'GET /foo', 'First');
      $r->add(second => '/foo', 'Second');

      is $r->match('/foo', 'GET')->{controller}, 'First';
      is $r->match('/foo', 'POST')->{controller}, 'Second';
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
      like $@, qr/no route path supplied/;
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
