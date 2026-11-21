#!/usr/bin/env perl

# with() scopes and resource(), beyond what 10_submapper.t and
# 20_resource.t cover.

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

describe 'Router' => sub {
  my $r;

  before each => sub {
    $r = $CLASS->new;
  };

  describe 'with' => sub {
    it 'adds nothing by itself' => sub {
      $r->with(admin => '/admin', 'Admin');

      is scalar(() = $r->routes), 0;
    };

    it 'names a route after the scope alone when the route name is empty' =>
      sub {
        $r->with(cart => '/cart', 'Cart')->add('' => '');

        is $r->url('cart'), '/cart';
      };

    it 'leaves a route unnamed when its name is undefined' => sub {
      $r->with(cart => '/cart', 'Cart')->add(undef, '/x');

      is_deeply [ map { $_->{name} } $r->routes ], [undef];
    };

    it 'takes the route name alone when the scope has no name' => sub {
      $r->with(undef, '/cart', 'Cart')->add(items => '/items');

      is $r->url('items'), '/cart/items';
    };

    it 'takes the route path alone when the scope has no path' => sub {
      $r->with(cart => undef, 'Cart')->add(items => '/items');

      is $r->url('cart_items'), '/items';
    };

    it 'carries a placeholder in the scope path' => sub {
      $r->with(posting => '/postings/{posting_id}', 'Posting')
        ->add(offers => '/offers', '::Offer');

      is_deeply $r->match('/postings/9/offers'),
        { controller => 'Posting::Offer', posting_id => 9 };
      is $r->url('posting_offers', posting_id => 9), '/postings/9/offers';
    };

    it 'merges payload keys, the route winning' => sub {
      $r->with(admin => '/admin', { controller => 'Admin', ssl => 1, x => 1 })
        ->add(users => '/users', { action => 'users', x => 2 });

      is_deeply $r->match('/admin/users'),
        { controller => 'Admin', action => 'users', ssl => 1, x => 2 };
    };

    it 'does not leak one route payload into the next' => sub {
      $r->with(admin => '/admin', 'Admin')
        ->add(users => '/users', '#users')
        ->add(log   => '/log');

      is_deeply $r->match('/admin/log'), { controller => 'Admin' };
    };

    it 'appends :: controllers through every level' => sub {
      $r->with(a => '/a', 'A', call => sub {
        $_->with(b => '/b', '::B', call => sub {
          $_->add(c => '/c', '::C#show');
        });
      });

      is_deeply $r->match('/a/b/c'),
        { controller => 'A::B::C', action => 'show' };
      is $r->url('a_b_c'), '/a/b/c';
    };

    it 'keeps a :: controller as written when no outer one exists' => sub {
      $r->with(a => '/a')->add(b => '/b', '::B');

      is $r->match('/a/b')->{controller}, '::B';
    };

    it 'passes the scope to the callback as $_ and as an argument' => sub {
      my @seen;
      $r->with(a => '/a', 'A', call => sub { @seen = ($_, $_[0]) });

      is $seen[0], $seen[1];
      isa_ok $seen[0], 'Router::Right::Submapper';
    };

    it 'returns the scope, so a chain keeps adding to it' => sub {
      my $scope = $r->with(a => '/a', 'A');

      is $scope->add(b => '/b'), $scope;
      is $scope->resource('thing', '::Thing'), $scope;
    };

    it 'is built from the submapper class the router names' => sub {
      my $scoped = Router::Right::Test::Scoped->new;

      isa_ok $scoped->with(a => '/a', 'A'),
        'Router::Right::Test::Scoped::Submapper';
      isa_ok $scoped->with(a => '/a', 'A')->with(b => '/b'),
        'Router::Right::Test::Scoped::Submapper';
    };

    it 'answers can() for a router method' => sub {
      my $scope = $r->with(a => '/a', 'A')->add(b => '/b');

      my $url = $scope->can('url');
      ok $url;
      is $scope->$url('a_b'), '/a/b';
      ok !$scope->can('no_such_method');
    };

    it 'forwards router methods to the router' => sub {
      my $scope = $r->with(a => '/a', 'A')->add(b => '/b');

      is $scope->url('a_b'), '/a/b';
      is_deeply $scope->match('/a/b'), { controller => 'A' };
      like $scope->as_string, qr{/a/b};
    };

    it 'takes a method from the scope path' => sub {
      $r->with(a => 'POST /a', 'A')->add(b => '/b');

      is_deeply [ $r->allowed_methods('a_b') ], ['POST'];
    };

    it 'takes methods from the methods option' => sub {
      $r->with(a => '/a', 'A', methods => [qw/ GET POST /])->add(b => '/b');

      is_deeply [ $r->allowed_methods('a_b') ], [qw/ GET POST /];
    };

    it 'leaves one scope untouched by another on the same prefix' => sub {
      $r->with(admin => '/admin', 'Admin')->add(a => '/a');
      $r->with(admin => '/admin', 'Other')->add(b => '/b');

      is $r->match('/admin/a')->{controller}, 'Admin';
      is $r->match('/admin/b')->{controller}, 'Other';
    };
  };

  describe 'resource' => sub {
    before each => sub {
      $r->resource('message', 'Message');
    };

    it 'routes each method and path to its action' => sub {
      my @expect = (
        [ GET    => '/messages',          'index'  ],
        [ POST   => '/messages',          'create' ],
        [ GET    => '/messages/new',      'new'    ],
        [ GET    => '/messages/7',        'show'   ],
        [ PUT    => '/messages/7',        'update' ],
        [ DELETE => '/messages/7',        'delete' ],
        [ GET    => '/messages/7/edit',   'edit'   ],
        [ GET    => '/messages.json',     'index'  ],
        [ POST   => '/messages.json',     'create' ],
        [ GET    => '/messages/new.json', 'new'    ],
        [ GET    => '/messages/7.json',   'show'   ],
        [ PUT    => '/messages/7.json',   'update' ],
      );

      foreach (@expect) {
        my ($method, $path, $action) = @$_;
        my $match = $r->match($path, $method);
        is $match && $match->{action}, $action, "$method $path";
      }
    };

    it 'carries the id and format' => sub {
      is_deeply $r->match('/messages/7.json', 'GET'), {
        controller => 'Message',
        action     => 'show',
        id         => 7,
        format     => 'json',
      };
    };

    it 'refuses methods a path does not take' => sub {
      foreach (
        [ DELETE => '/messages' ],
        [ POST   => '/messages/7' ],
        [ PATCH  => '/messages/7' ],
        [ POST   => '/messages/7/edit' ],
      ) {
        my ($method, $path) = @$_;
        ok !$r->match($path, $method), "$method $path";
        is $r->error, 405, "$method $path is 405";
      }
    };

    it 'reports the methods a member path takes' => sub {
      $r->match('/messages/7', 'POST');

      is_deeply [ $r->allowed_methods ], [qw/ DELETE GET PUT /];
    };

    it 'gives /new to the new action, not to show' => sub {
      is $r->match('/messages/new', 'GET')->{action}, 'new';
    };

    it 'builds each named url' => sub {
      is $r->url('messages'), '/messages';
      is $r->url('new_message'), '/messages/new';
      is $r->url('message', id => 7), '/messages/7';
      is $r->url('edit_message', id => 7), '/messages/7/edit';
      is $r->url('message', id => 7, format => 'json'), '/messages/7.json';
      is $r->url('formatted_message', id => 7, format => 'json'),
        '/messages/7.json';
    };

    it 'requires a format for a formatted_ url' => sub {
      eval { $r->url('formatted_messages') };
      like $@, qr/required param 'format' missing/;
    };

    it 'pluralizes irregular member names' => sub {
      $r->resource('tax', 'Tax')->resource('category', 'Category');

      ok $r->match('/taxes', 'GET');
      ok $r->match('/categories/3', 'GET');
      is $r->url('categories'), '/categories';
    };

    it 'can follow its own routes with extra member routes' => sub {
      $r->add(message_reply => 'POST /messages/{id}/reply', 'Message#reply');

      is $r->match('/messages/7/reply', 'POST')->{action}, 'reply';
      is $r->match('/messages/7', 'GET')->{action}, 'show';
    };

    it 'nests under a scope, whose name leads each route name' => sub {
      $r->with(trip => '/trips/{trip_id}', 'Trip')
        ->resource('note', '::Note');

      is_deeply $r->match('/trips/3/notes/9', 'GET'), {
        controller => 'Trip::Note',
        action     => 'show',
        trip_id    => 3,
        id         => 9,
      };
      is $r->url('trip_edit_note', trip_id => 3, id => 9),
        '/trips/3/notes/9/edit';
    };

    it 'nests two scopes deep through a callback' => sub {
      $r->with(admin => '/admin', 'Admin', call => sub {
        $_->with(resort => '/resorts/{resort_id}', '::Resort', call => sub {
          $_->resource('note', '::Note');
        });
      });

      is_deeply $r->match('/admin/resorts/4/notes/2', 'GET'), {
        controller => 'Admin::Resort::Note',
        action     => 'show',
        resort_id  => 4,
        id         => 2,
      };
      is $r->url('admin_resort_notes', resort_id => 4),
        '/admin/resorts/4/notes';
    };

    it 'nests under a scope with an empty payload' => sub {
      $r->with(admin => '/admin', 'Admin', call => sub {
        $_->with(loc => '/{location_id}', '', call => sub {
          $_->resource('note', '::Note');
        });
      });

      my $match = $r->match('/admin/7/notes/3', 'GET');
      is $match->{controller}, 'Admin::Note';
      is $match->name, 'admin_loc_note';
    };

    it 'refuses the same resource twice' => sub {
      eval { $r->resource('message', 'Other') };
      like $@, qr/route 'messages' already defined/;
    };
  };
};

runtests unless caller;
