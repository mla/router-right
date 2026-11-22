#!/usr/bin/env perl

# Behaviour pinned as it is today where the right behaviour is a design
# decision. Changing one of these should be deliberate; once it is decided,
# the test moves to the file for its subject.
#
# A known defect goes here as a TODO test asserting the behaviour wanted, so
# its fix shows up as an unexpected pass.

use strict;
use warnings;
use Test::Spec;

my $CLASS = 'Router::Right';

use_ok $CLASS;

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
