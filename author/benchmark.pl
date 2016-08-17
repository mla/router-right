#!/usr/bin/env perl

# Taken from Router::Boom distribution
# https://github.com/tokuhirom/Router-Boom/tree/master/author

use strict;
use warnings;
use utf8;
use lib 'lib';
use 5.010000;
use autodie;
use Benchmark qw/ :all /;
use Router::Boom;
use Router::Boom::Method;
use Router::Simple;
use Router::Right;

my $router_boom = do {
  my $router = Router::Boom->new();
  $router->add('/', 'Root');
  $router->add('/entrylist', 'EntryList');
  $router->add("/$_", "$_") for 'a'..'z';
  $router->add('/:user', 'User#index');
  $router->add('/:user/:year', 'UserBlog#year_archive');
  $router->add('/:user/:year/:month', 'UserBlog#month_archive');
  $router;
};

my $router_boom_method = do {
  my $router = Router::Boom::Method->new();
  $router->add(undef, '/', 'Root');
  $router->add(undef, '/entrylist', 'EntryList');
  $router->add(undef, "/$_", "$_") for 'a'..'z';
  $router->add(undef, '/:user', 'User#index');
  $router->add(undef, '/:user/:year', 'UserBlog#year_archive');
  $router->add(undef, '/:user/:year/:month', 'UserBlog#month_archive');
  $router;
};

my $router_simple = do {
  my $router = Router::Simple->new();
  $router->connect('/', { controller => 'Root' });
  $router->connect('/entrylist', 'EntryList');
  $router->connect("/$_", "$_") for 'a'..'z';
  $router->connect('/:user', 'User#index');
  $router->connect('/:user/:year', 'UserBlog#year_archive');
  $router->connect('/:user/:year/:month', { controller => 'UserBlog#month_archive' });
  $router;
};

my $router_right = do {
  my $payload = { controller => 'Test' };
  my $router = Router::Right->new;
  $router->add(root => '/', $payload);
  $router->add(entrylist => '/entrylist', $payload);
  $router->add($_ => "/$_", $payload) for 'a'..'z';
  $router->add(user_index => '/{user}', $payload);
  $router->add(user_blog_year_archive => '/{user}/{year}', $payload);
  $router->add(user_blog_month_archive => '/{user}/{year}/{month}', $payload);
  $router;
};

cmpthese(
  -1,
  {
    'Router::Simple' => sub {
      $router_simple->match('/dankogai/2013/02') or die "failed"
    },

    'Router::Boom' => sub {
      $router_boom->match('/dankogai/2013/02') or die "failed"
    },

    'Router::Boom::Method' => sub {
      $router_boom_method->match('GET', '/dankogai/2013/02') or die "failed"
    },
    
    'Router::Right' => sub {
      $router_right->match('/dankogai/2013/02') or die "failed"
    },
  }
);

