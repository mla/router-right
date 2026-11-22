#!/usr/bin/env perl

use strict;
use warnings;
use Test::Spec;

my $CLASS = 'Router::Right';

use_ok $CLASS;

{
  package Router::Right::Test::Deflate;
  use parent -norequire, 'Router::Right';

  sub _resolve_param {
    my ($self, $pname, $pval) = @_;

    return ref $pval eq 'HASH' ? $pval->{ $pname } : $pval;
  }
}

describe 'Router url' => sub {
  my $r;

  before each => sub {
    $r = $CLASS->new;
    $r->add(home  => '/', 'Home');
    $r->add(entry => '/entries/{year:\d+}/{month:\d+}', 'Entry');
    $r->add(user  => '/users/{id}', 'User');
  };

  it 'returns a URI' => sub {
    isa_ok $r->url('home'), 'URI';
  };

  it 'fills placeholders whatever order they are passed in' => sub {
    is $r->url('entry', month => '08', year => 1916), '/entries/1916/08';
  };

  it 'accepts zero as a placeholder value' => sub {
    is $r->url('user', id => 0), '/users/0';
  };

  it 'appends other params as a query string, in the order passed' => sub {
    is $r->url('user', z => 1, id => 7, a => 2, m => 3),
      '/users/7?z=1&a=2&m=3';
  };

  it 'repeats a query param given an array ref' => sub {
    is $r->url('user', id => 7, tag => [qw/ a b /]), '/users/7?tag=a&tag=b';
  };

  it 'leaves the values it is passed as they were' => sub {
    my @tags = ('a b', '100%', 'x&y');
    $r->url('user', id => 7, tag => \@tags) for 1 .. 2;

    is_deeply \@tags, [ 'a b', '100%', 'x&y' ];
    is $r->url('user', id => 7, tag => \@tags),
      '/users/7?tag=a+b&tag=100%25&tag=x%26y';
  };

  it 'keeps the last value of a query param passed twice' => sub {
    is $r->url('user', id => 7, q => 'a', q => 'b'), '/users/7?q=b';
  };

  it 'escapes query values' => sub {
    is $r->url('user', id => 7, q => 'a b&c=d'), '/users/7?q=a+b%26c%3Dd';
  };

  it 'writes an undefined query value as a bare or empty key' => sub {
    like $r->url('user', id => 7, q => undef), qr{\A/users/7\?q=?\z};
  };

  it 'escapes a space in a placeholder value' => sub {
    is $r->url('user', id => 'a b'), '/users/a%20b';
  };

  it 'escapes what would end or break the path' => sub {
    is $r->url('user', id => 'a?b'), '/users/a%3Fb';
    is $r->url('user', id => 'a#b'), '/users/a%23b';
    is $r->url('user', id => '100%'), '/users/100%25';
  };

  it 'escapes the same whatever the last regex matched' => sub {
    foreach my $last ('my-post', 'x', '$') {
      $last =~ /.+/;
      is $r->url('user', id => 'a$b&c'), '/users/a$b&c', "after '$last'";
    }
  };

  it 'leaves characters a path segment may hold' => sub {
    is $r->url('user', id => q{a-b.c_d~e!f$g&h'i(j)k*l+m,n;o=p:q@r}),
      q{/users/a-b.c_d~e!f$g&h'i(j)k*l+m,n;o=p:q@r};
  };

  it 'encodes a character value as UTF-8' => sub {
    is $r->url('user', id => "caf\x{e9}"), '/users/caf%C3%A9';
    is $r->url('user', id => "\x{2603}"), '/users/%E2%98%83';
  };

  it 'keeps the slashes a spanning placeholder holds' => sub {
    $r->add(file => '/files/{path:.+}', 'File');

    is $r->url('file', path => 'a/b c/d.txt'), '/files/a/b%20c/d.txt';
  };

  it 'builds a path that matches back to the same value' => sub {
    foreach my $id ('a?b', 'a#b', '100%', 'a b', "caf\x{e9}") {
      my $url   = $r->url('user', id => $id);
      my $match = $r->match($url->path);
      (my $got = $match->{id}) =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
      utf8::decode($got);

      is $got, $id, "id '$id'";
    }
  };

  it 'accepts a route named 0' => sub {
    $r->add(0 => '/zero', 'Zero');

    is $r->url(0), '/zero';
  };

  it 'does not change the route it reads' => sub {
    my $before = $r->as_string;
    $r->url('user', id => 7, q => 1);

    is $r->as_string, $before;
    is $r->url('user', id => 8), '/users/8';
  };

  it 'takes a route added after an earlier url call' => sub {
    $r->url('home');
    $r->add(late => '/late/{id}', 'Late');

    is $r->url('late', id => 3), '/late/3';
  };

  it 'passes a literal path through with a query string' => sub {
    is $r->url('/plain/path', q => 1), '/plain/path?q=1';
  };

  it 'refuses a missing placeholder in a literal path' => sub {
    eval { $r->url('/plain/{id}') };
    like $@, qr/required param 'id' missing/;
  };

  it 'cannot be built for an unnamed route' => sub {
    $r->add(undef, '/anon/{id}', 'Anon');

    eval { $r->url('anon', id => 1) };
    like $@, qr/url name 'anon' not found/;
  };

  describe 'format placeholder' => sub {
    before each => sub {
      $r->add(dl => '/dl/{file}{.format}', 'Download');
    };

    it 'is dropped when passed undefined or empty' => sub {
      is $r->url('dl', file => 'foo', format => undef), '/dl/foo';
      is $r->url('dl', file => 'foo', format => ''), '/dl/foo';
    };

    it 'is dropped when not passed' => sub {
      is $r->url('dl', file => 'foo'), '/dl/foo';
    };

    it 'is written after a dot' => sub {
      is $r->url('dl', file => 'foo', format => 'gz'), '/dl/foo.gz';
    };
  };

  describe '_resolve_param' => sub {
    it 'lets a subclass turn an object into a placeholder value' => sub {
      my $deflate = Router::Right::Test::Deflate->new;
      $deflate->add(user => '/users/{id}', 'User');

      is $deflate->url('user', id => { id => 42 }), '/users/42';
    };

    it 'is checked against the placeholder pattern afterwards' => sub {
      my $deflate = Router::Right::Test::Deflate->new;
      $deflate->add(user => '/users/{id:\d+}', 'User');

      eval { $deflate->url('user', id => { id => 'x' }) };
      like $@, qr/invalid value for param 'id'/;
    };

    it 'is not applied to query params' => sub {
      my $deflate = Router::Right::Test::Deflate->new;
      $deflate->add(user => '/users/{id}', 'User');

      is $deflate->url('user', id => 1, q => 'plain'), '/users/1?q=plain';
    };
  };

  describe 'round trip' => sub {
    it 'matches the url it built' => sub {
      my $url = $r->url('entry', year => 1916, month => '08');

      is_deeply $r->match($url->path),
        { controller => 'Entry', year => 1916, month => '08' };
    };

    it 'matches the url built for every resource route' => sub {
      $r->resource('message', 'Message');

      my %args = (id => 5, format => 'json');
      foreach my $route (grep { defined $_->{name} } $r->routes) {
        $route->{path} =~ /messages/ or next;
        my $url   = $r->url($route->{name}, %args);
        my $match = $r->match($url->path, 'GET');

        is $match && $match->{action}, $route->{payload}{action},
          "$route->{name} -> $url";
      }
    };
  };
};

runtests unless caller;
