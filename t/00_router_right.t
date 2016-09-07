#!/usr/bin/env perl

use strict;
use warnings;
use Test::Spec;

my $CLASS = 'Router::Right';

use_ok $CLASS;

my $r = $CLASS->new;
isa_ok $r, $CLASS, 'constructor';

isa_ok $r->new, $CLASS, 'constructor from instance';

describe 'Router' => sub {
  my $r;

  before each => sub {
    $r = $CLASS->new;
  };

  it 'can be built' => sub {
    is ref $r, $CLASS;
  };

  describe 'add' => sub {
    my $payload = { controller => 'Foo' };

    it 'can accept route' => sub {
      ok $r->add(home => '/', $payload);
    };

    it 'returns reference for chaining' => sub {
      is ref $r->add(home => '/', $payload), $CLASS;
    };

    it 'does not require a route name' => sub {
      $r->add(undef, '/', $payload);
    };

    it 'raises exception if duplicate route name added' => sub {
      $r->add(home => '/', $payload);
      eval { $r->add(home => '/', $payload) };
      ok $@;
    };

    it 'requires a route path' => sub {
      eval { $r->add('home', undef, $payload) };
      ok $@;
    };

    it 'defaults to accepting all methods' => sub {
      $r->add(home => '/', $payload);
      is_deeply $r->_route('home')->{methods}, [];
    };

    describe 'methods' => sub {
      it 'defaults to accepting all' => sub {
        $r->add(home => '/', $payload);
        is_deeply $r->_route('home')->{methods}, [];
      };

      it 'can be specified by scalar' => sub {
        $r->add(home => '/', $payload, methods => 'post');
        is_deeply $r->_route('home')->{methods}, ['POST'];
      };

      it 'can be specified by scalar with multiple values' => sub {
        $r->add(home => '/', $payload, methods => 'POST, DELETE |GET');
        is_deeply $r->_route('home')->{methods}, ['DELETE', 'GET', 'POST'];
      };

      it 'can be specified by array ref' => sub {
        $r->add(home => '/', $payload, methods => [qw/ PUT POST /]);
        is_deeply $r->_route('home')->{methods}, ['POST', 'PUT'];
      };

      it 'can be specified as part of route' => sub {
        $r->add(home => 'POST /', $payload);
        is_deeply $r->_route('home')->{methods}, ['POST'];
      };
    };
  };

  describe 'matching' => sub {
    my $payload = { controller => 'Foo' };

    it 'a known route returns payload' => sub {
      $r->add(home => '/', $payload);
      is_deeply $r->match('/'), $payload;
      is_deeply $r->match('/'), $payload, 'cached regex';
    };

    it 'an unknown route returns undef' => sub {
      is $r->match('/unknown'), undef, 'when no routes defined';
      $r->add(home => '/', $payload);
      is $r->match('/unknown'), undef, 'when routes defined';
    };

    it 'a route with no method restriction matches with any method' => sub {
      $r->add(home => '/', $payload);
      is_deeply $r->match('/', 'POST'), $payload;
    };

    it 'a route with matching methods returns payload' => sub {
      $r->add(get_home => 'GET /', { method => 'GET' });
      $r->add(put_home => 'PUT /', { method => 'PUT' });
      is_deeply $r->match('/', 'PUT'), { method => 'PUT' };
    };

    it 'a route with differing methods returns undef' => sub {
      $r->add(home => 'GET /', $payload);
      is $r->match('/', 'POST'), undef;
    };

    it 'allows an optional format extension' => sub {
      $r->add(download => '/dl/{file}{.format}', { controller => 'DL' });
      my $rv = $r->match('/dl/foo');
      is_deeply $rv, { controller => 'DL', file => 'foo' },
        'matches without extension';

      $rv = $r->match('/dl/foo.gz');
      is_deeply $rv, { controller => 'DL', file => 'foo', format => 'gz' },
        'matches with extension';
    };
  };

  describe 'placeholder route' => sub {
    my $payload = { controller => 'Foo' };

    it 'defaults to matching [^/]+' => sub {
      $r->add(entry => '/entry/{year}/foo', $payload);
      ok $r->match('/entry/1916/foo');
      ok $r->match('/entry/zort/foo');
    };

    it 'can be restricted by pattern' => sub {
      $r->add(entry => '/entry/{year:\d+}/foo', $payload);
      ok $r->match('/entry/1916/foo');
      ok !$r->match('/entry/zort/foo');
    };

    it 'merges placeholder content into payload' => sub {
      $r->add(entry => '/entry/{year}/{month}/{day}', $payload);
      my $got = $r->match('/entry/1916/08/11');
      is_deeply
        $got,
        {
          controller => 'Foo',
          year       => '1916',
          month      => '08',
          day        => '11',
        },
      ;
    };

    it 'raises exception on duplicate placeholder' => sub {
      eval { $r->add(entry => '/entry/{year}/{month}/{year}') };
      ok $@;
    };
  };

  describe 'payload' => sub {
    my $payload = { controller => 'Foo', action => 'zort' };

    it 'can be specified as a named hash ref' => sub {
      $r->add(home => '/', payload => $payload);
      is_deeply $r->match('/'), $payload;
    };

    it 'can be specified as a positional hash ref' => sub {
      $r->add(home => '/', $payload);
      is_deeply $r->match('/'), $payload;
    };

    it 'can be specified as a named scalar' => sub {
      $r->add(home => '/', payload => 'Foo#zort');
      is_deeply $r->match('/'), $payload;
    };

    it 'can be specified as a positional scalar' => sub {
      $r->add(home => '/', 'Foo#zort');
      is_deeply $r->match('/'), $payload;
    };

    it 'can be specified as a scalar with no action' => sub {
      $r->add(home => '/', 'Foo');
      is_deeply $r->match('/'), { controller => 'Foo' };
    };

    it 'can be specified as a scalar with no controller' => sub {
      $r->add(home => '/', '#zort');
      is_deeply $r->match('/'), { action => 'zort' };
    };
  };

  it 'can produce list of routes' => sub {
    $r->add(home => '/', { controller => 'Home' });
    $r->add(add => 'POST /add', { controller => 'Entries' });
    ok $r->as_string;
  };

  it 'can return list of allowed methods from previous match' => sub {
    $r->add(add => 'POST /add', {});
    $r->match('/add');
    is_deeply scalar $r->allowed_methods, ['POST'];
  };

  it 'can look up allowed methods by route name' => sub {
    $r->add(add => 'POST /add', {});
    is_deeply scalar $r->allowed_methods('add'), ['POST'];
  };

  it 'can look up allowed methods by route path' => sub {
    $r->add(add => 'POST /add', {});
    is_deeply scalar $r->allowed_methods('/add'), ['POST'];
  };

  describe 'can build url' => sub {
    it 'from route' => sub {
      $r->add(entry => '/entries/{year}/{month}/{day}', {});
      my $url = $r->url('entry', year => '1916', month => '08', day => '14');
      is $url, '/entries/1916/08/14';
    };

    it 'raises exception if invalid placeholder value' => sub {
      $r->add(entry => '/entries/{year:\d+}', {});
      eval { $r->url('entry', year => 'foo') };
      ok $@;
    };

    describe 'with special format placeholder' => sub {
      it 'supplied' => sub {
        $r->add(dl => '/dl/{file}{.format}', {});
        my $url = $r->url('dl', file => 'foo', format => 'mp3');
        is $url, '/dl/foo.mp3';
      };

      it 'not supplied' => sub {
        $r->add(dl => '/dl/{file}{.format}', {});
        my $url = $r->url('dl', file => 'foo');
        is $url, '/dl/foo';
      };
    };

    it 'with non-special format placeholder' => sub {
      $r->add(dl => '/dl/{file}{format}', {});
      my $url = $r->url('dl', file => 'foo', format => '.mp3');
      is $url, '/dl/foo.mp3';
    };

    it 'from literal url' => sub {
      my $url = $r->url('/foo/zort', q => 'abc');
      is $url, '/foo/zort?q=abc';
    };

    it 'from literal url with placeholders' => sub {
      my $url = $r->url('/entries/{year}', year => '1916', q => 'abc');
      is $url, '/entries/1916?q=abc';
    };

    it 'but raises exception if unknown name and not a url' => sub {
      eval { $r->url('unknown') }; # isn't route name or a url string
      ok $@;
    };
  };

  it 'can have an error code set' => sub {
    is $r->error(404), undef;
    is $r->error, 404;
  };
};

runtests unless caller;

1;
