#!/usr/bin/env perl

# with() scopes and resource(), beyond what 10_with.t and
# 20_resource.t cover.

use strict;
use warnings;
use Test::Spec;

my $CLASS = 'Router::Right';

use_ok $CLASS;

{
  # GET implies HEAD, the way a subclass might add it.
  package Router::Right::Test::Head;
  use parent -norequire, 'Router::Right';

  sub _methods {
    my $self    = shift;
    my @methods = $self->SUPER::_methods(@_);

    push @methods, 'HEAD' if grep { $_ eq 'GET' } @methods;
    my %seen;
    @methods = sort grep { !$seen{ $_ }++ } @methods;

    return wantarray ? @methods : \@methods;
  }
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
      is ref $seen[0], ref $r;
    };

    it 'returns the scope, so a chain keeps adding to it' => sub {
      my $scope = $r->with(a => '/a', 'A');

      is $scope->add(b => '/b'), $scope;
      is $scope->resource('thing', '::Thing'), $scope;
    };

    it 'is a router of the same class, at every depth' => sub {
      my $head = Router::Right::Test::Head->new;

      is ref $r->with(a => '/a', 'A'), ref $r;
      is ref $head->with(a => '/a', 'A'), ref $head;
      is ref $head->with(a => '/a', 'A')->with(b => '/b'), ref $head;
    };

    it 'applies a subclass override to the routes it adds' => sub {
      my $head = Router::Right::Test::Head->new;
      $head->with(a => '/a', 'A', call => sub {
        $_->add(b => 'GET /b');
        $_->with(c => '/c')->add(d => 'GET /d');
        $_->resource('note', '::Note');
      });

      is_deeply [ $head->allowed_methods('a_b') ], [qw/ GET HEAD /];
      is_deeply [ $head->allowed_methods('a_c_d') ], [qw/ GET HEAD /];
      ok $head->match('/a/notes/3', 'HEAD');
    };

    it 'is not the router it came from' => sub {
      my $scope = $r->with(a => '/a', 'A');

      isnt $scope, $r;
      $r->add(top => '/top', 'Top');
      is $r->url('top'), '/top';
    };

    it 'shares one table with the router and its other scopes' => sub {
      my $a = $r->with(a => '/a', 'A');
      my $b = $r->with(b => '/b', 'B');
      $a->add(x => '/x');
      $b->add(y => '/y');
      $r->add(z => '/z', 'Z');

      foreach my $via ($r, $a, $b, $a->with(deep => '/deep')) {
        is_deeply [ map { $_->{name} } $via->routes ], [qw/ a_x b_y z /];
        is $via->match('/b/y')->{controller}, 'B';
        is $via->url('a_x'), '/a/x';
      }
    };

    it 'sees a route added through another scope after a match' => sub {
      my $a = $r->with(a => '/a', 'A');
      $a->add(x => '/x');
      ok !$r->match('/a/late');

      $a->add(late => '/late');
      ok $r->match('/a/late');
      ok $a->match('/a/late');
    };

    it 'reports the last match and its error through any scope' => sub {
      my $a = $r->with(a => '/a', 'A')->add(x => 'GET /x');

      ok !$r->match('/a/x', 'POST');
      is $a->error, 405;
      is_deeply [ $a->allowed_methods ], ['GET'];
    };

    it 'keeps adding under its prefix after other scopes were made' => sub {
      my $a = $r->with(a => '/a', 'A');
      $a->with(b => '/b', '::B')->add(x => '/x');
      $r->with(c => '/c', 'C')->add(y => '/y');
      $a->add(z => '/z');

      is $r->match('/a/z')->{controller}, 'A';
      is $r->url('a_z'), '/a/z';
    };

    it 'leaves the payload hash it was given alone' => sub {
      my $outer = { controller => 'Admin', ssl => 1 };
      my $inner = { controller => '::User', action => 'show' };
      $r->with(admin => '/admin', $outer)->add(user => '/user', $inner);
      $r->with(other => '/other', 'Other')->add(user => '/user', $inner);

      is_deeply $outer, { controller => 'Admin', ssl => 1 };
      is_deeply $inner, { controller => '::User', action => 'show' };
      is $r->match('/admin/user')->{controller}, 'Admin::User';
      is $r->match('/other/user')->{controller}, 'Other::User';
    };

    it 'keeps its callback out of the routes it adds' => sub {
      $r->with(a => '/a', 'A', call => sub { $_->add(b => '/b') });

      ok !exists $r->_route('a_b')->{args}{call};
    };

    it 'starts an empty router of its own from new()' => sub {
      my $scope = $r->with(a => '/a', 'A')->add(b => '/b');
      my $fresh = $scope->new;

      is scalar(() = $fresh->routes), 0;
      $fresh->add(c => '/c', 'C');
      is $fresh->url('c'), '/c';
      ok !$r->match('/c');
    };

    it 'answers can() for a router method' => sub {
      my $scope = $r->with(a => '/a', 'A')->add(b => '/b');

      my $url = $scope->can('url');
      ok $url;
      is $scope->$url('a_b'), '/a/b';
      ok !$scope->can('no_such_method');
    };

    it 'answers every router method itself' => sub {
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
        [ POST   => '/messages/7/edit' ],
      ) {
        my ($method, $path) = @$_;
        ok !$r->match($path, $method), "$method $path";
        is $r->error, 405, "$method $path is 405";
      }
    };

    it 'reports the methods a member path takes' => sub {
      $r->match('/messages/7', 'POST');

      is_deeply [ $r->allowed_methods ], [qw/ DELETE GET PATCH PUT /];
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
    };

    it 'requires a format for a legacy formatted_ url' => sub {
      my $legacy = $CLASS->new(legacy_resources => 1);
      $legacy->resource('message', 'Message');

      eval { $legacy->url('formatted_messages') };
      like $@, qr/required param 'format' missing/;
      is $legacy->url('formatted_message', id => 7, format => 'json'),
        '/messages/7.json';
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
