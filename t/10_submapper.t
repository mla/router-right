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
    my $payload = { controller => 'A' };
    $r->with(a => '/a', $payload)
        ->with(b => '/b')
          ->with(c => '/c')
            ->add(show => '/{username}')
    ;

    ok $r->match('/a/b/c/foo');
  };

  it 'can apply callback' => sub {
    my $payload = { controller => 'Admin' };
    $r->with(admin => '/admin', $payload, call => sub {
      $_->add(users => '/users', { action => 'users' });
    });

    is_deeply $r->match('/admin/users'),
      { controller => 'Admin', action => 'users' };
  };

  it 'can append controller' => sub {
    $r->with(admin => '/admin', 'Admin')
      ->add(users => '/users', '::User')
    ;
    is_deeply $r->match('/admin/users'), { controller => 'Admin::User' };
  };

  it 'can override controller' => sub {
    $r->with(admin => '/admin', 'Admin')
      ->add(users => '/users', 'User')
    ;
    is_deeply $r->match('/admin/users'), { controller => 'User' };
  };

  # Should produce a route name of "admin_report". Before, was producing
  # "admin_report_" (was tacking on blank name).
  it 'nested route name inherited when name is defined but blank' => sub {
    $r->with(admin_report => '/admin/resort', 'Admin::Report')
      ->add('' => '/{action}')
    ;
    ok $r->_route('admin_report');
  };
};

runtests unless caller;

1;
