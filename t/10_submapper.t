#!/usr/bin/env perl

use strict;
use warnings;
use Test::Spec;

my $CLASS = 'Router::Right';

use_ok $CLASS;

describe 'Submapper' => sub {
  my $r;

  before each => sub {
    $r = $CLASS->new;
  };

  it 'applies defaults' => sub {
    my $payload = { controller => 'Admin' };

    $r->with(admin => '/admin', $payload)
      ->add(users  => '/users')
      ->add(status => 'GET /status')
    ;

    is_deeply $r->match('/admin/users'), $payload;
    is_deeply $r->match('/admin/status'), $payload;
    ok !$r->match('/foo');
    is_deeply $r->_route('admin_status')->{methods}, ['GET'];
  };

  it 'can be nested' => sub {
    my $payload = { controller => 'Admin' };
    $r->with(admin => '/admin', $payload)
        ->with(users => '/users')
          ->add(show => '/{username}')
    ;

    ok $r->match('/admin/users/foo');
  };

  it 'can apply callback' => sub {
    my $payload = { controller => 'Admin' };
    $r->with(admin => '/admin', $payload, call => sub {
      $_->add(users => '/users');
    });

    ok $r->match('/admin/users');
  };
};

runtests unless caller;

1;
