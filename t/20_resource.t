#!/usr/bin/env perl

use strict;
use warnings;
use Test::Spec;


sub trimmed($) {
  my $str = shift;

  $str =~ s/^\s+|\s+$//g;
  $str =~ s/\s+/ /g;

  return $str;
}


my $CLASS = 'Router::Right';

use_ok $CLASS;

describe 'Router' => sub {
  my $r;

  before each => sub {
    $r = $CLASS->new;
  };

  it 'has no routes to start' => sub {
    is $r->as_string, '', 'no routes to start';
  };

  describe 'resource with legacy_resources' => sub {
    before each => sub {
      $r = $CLASS->new(legacy_resources => 1);
    };

    it 'can be added' => sub {
      $r->resource('message');
      
      my $expected = qq{
                      messages GET    /messages{.format}           { action => "index" }
                               POST   /messages{.format}           { action => "create" }
            formatted_messages GET    /messages.{format}           { action => "index" }
                   new_message GET    /messages/new{.format}       { action => "new" }
         formatted_new_message GET    /messages/new.{format}       { action => "new" }
                       message GET    /messages/{id}{.format}      { action => "show" }
                               PUT    /messages/{id}{.format}      { action => "update" }
                               DELETE /messages/{id}{.format}      { action => "delete" }
             formatted_message GET    /messages/{id}.{format}      { action => "show" }
                  edit_message GET    /messages/{id}{.format}/edit { action => "edit" }
        formatted_edit_message GET    /messages/{id}.{format}/edit { action => "edit" }
      };

      is trimmed($r->as_string), trimmed($expected);
    };

    it 'can override plural collection name' => sub {
      $r->resource('message', collection => 'mailboxes');

      my $expected = q{
                     mailboxes GET    /mailboxes{.format}           { action => "index" }
                               POST   /mailboxes{.format}           { action => "create" }
           formatted_mailboxes GET    /mailboxes.{format}           { action => "index" }
                   new_message GET    /mailboxes/new{.format}       { action => "new" }
         formatted_new_message GET    /mailboxes/new.{format}       { action => "new" }
                       message GET    /mailboxes/{id}{.format}      { action => "show" }
                               PUT    /mailboxes/{id}{.format}      { action => "update" }
                               DELETE /mailboxes/{id}{.format}      { action => "delete" }
             formatted_message GET    /mailboxes/{id}.{format}      { action => "show" }
                  edit_message GET    /mailboxes/{id}{.format}/edit { action => "edit" }
        formatted_edit_message GET    /mailboxes/{id}.{format}/edit { action => "edit" }
      };

      is trimmed($r->as_string), trimmed($expected);
    };

    it 'can be nested' => sub {
      $r->with(a => '/a', 'A')
          ->with(b => '/b', '::B')
            ->with(c => '/c', '::C')
              ->resource('user', { controller => '::User' });

      my $expected = qq{
                      a_b_c_users GET    /a/b/c/users{.format}           { action => "index", controller => "A::B::C::User" }
                          POST   /a/b/c/users{.format}           { action => "create", controller => "A::B::C::User" }
    a_b_c_formatted_users GET    /a/b/c/users.{format}           { action => "index", controller => "A::B::C::User" }
           a_b_c_new_user GET    /a/b/c/users/new{.format}       { action => "new", controller => "A::B::C::User" }
 a_b_c_formatted_new_user GET    /a/b/c/users/new.{format}       { action => "new", controller => "A::B::C::User" }
               a_b_c_user GET    /a/b/c/users/{id}{.format}      { action => "show", controller => "A::B::C::User" }
                          PUT    /a/b/c/users/{id}{.format}      { action => "update", controller => "A::B::C::User" }
                          DELETE /a/b/c/users/{id}{.format}      { action => "delete", controller => "A::B::C::User" }
     a_b_c_formatted_user GET    /a/b/c/users/{id}.{format}      { action => "show", controller => "A::B::C::User" }
          a_b_c_edit_user GET    /a/b/c/users/{id}{.format}/edit { action => "edit", controller => "A::B::C::User" }
a_b_c_formatted_edit_user GET    /a/b/c/users/{id}.{format}/edit { action => "edit", controller => "A::B::C::User" }
      };

      is trimmed($r->as_string), trimmed($expected);
    };
  };

  describe 'resource' => sub {

    it 'can be added' => sub {
      $r->resource('message');

      my $expected = qq{
             messages GET       /messages{.format}           { action => "index" }
                      POST      /messages{.format}           { action => "create" }
          new_message GET       /messages/new{.format}       { action => "new" }
              message GET       /messages/{id}{.format}      { action => "show" }
                      PATCH,PUT /messages/{id}{.format}      { action => "update" }
                      DELETE    /messages/{id}{.format}      { action => "delete" }
         edit_message GET       /messages/{id}/edit{.format} { action => "edit" }
      };

      is trimmed($r->as_string), trimmed($expected);
    };

    it 'can override the plural' => sub {
      $r->resource('message', plural => 'mailboxes', only => 'index');
      is trimmed($r->as_string),
        'mailboxes GET /mailboxes{.format} { action => "index" }';
    };

    it 'takes a string collection as the plural' => sub {
      $r->resource('message', collection => 'mailboxes', only => 'show');
      is trimmed($r->as_string),
        'message GET /mailboxes/{id}{.format} { action => "show" }';
    };

    it 'can be nested' => sub {
      $r->with(a => '/a', 'A')
          ->with(b => '/b', '::B')
            ->resource('user', '::User', only => [qw/ index edit /]);

      my $expected = q{
        a_b_users GET /a/b/users{.format}
          { action => "index", controller => "A::B::User" }
        a_b_edit_user GET /a/b/users/{id}/edit{.format}
          { action => "edit", controller => "A::B::User" }
      };

      is trimmed($r->as_string), trimmed($expected);
    };

    it 'builds only the actions listed' => sub {
      $r->resource('message', 'Message', only => [qw/ index show /]);

      is_deeply [ map { $_->{payload}{action} } $r->routes ],
        [qw/ index show /];
    };

    it 'leaves out the actions excepted' => sub {
      $r->resource('message', 'Message', except => [qw/ delete new create /]);

      is_deeply [ map { $_->{payload}{action} } $r->routes ],
        [qw/ index show update edit /];
    };

    it 'constrains the id' => sub {
      $r->resource('message', 'Message', id => '\d+');

      ok $r->match('/messages/7', 'GET');
      ok !$r->match('/messages/seven', 'GET');
      is $r->url('edit_message', id => 7), '/messages/7/edit';
      eval { $r->url('message', id => 'seven') };
      like $@, qr/invalid value for param 'id'/;
    };

    it 'takes PUT or PATCH for update' => sub {
      $r->resource('message', 'Message');

      is $r->match('/messages/7', $_)->{action}, 'update' foreach qw/ PUT PATCH /;
    };

    it 'puts the format last on an edit path' => sub {
      $r->resource('message', 'Message');

      is $r->url('edit_message', id => 7, format => 'json'),
        '/messages/7/edit.json';
      is $r->match('/messages/7/edit.json', 'GET')->{format}, 'json';
    };

    describe 'member and collection routes' => sub {
      before each => sub {
        $r->resource(
          'booking', 'Booking',
          collection => [ 'dashboard', 'POST bulk-action' ],
          member     => [
            'POST take', 'history{.format}', 'POST {op}-hold',
            'GET|POST confirm/guest',
          ],
        );
      };

      it 'are named after the resource and the action' => sub {
        is $r->url('bookings_dashboard'), '/bookings/dashboard';
        is $r->url('bookings_bulk_action'), '/bookings/bulk-action';
        is $r->url('booking_take', id => 7), '/bookings/7/take';
        is $r->url('booking_history', id => 7, format => 'csv'),
          '/bookings/7/history.csv';
        is $r->url('booking_hold', id => 7, op => 'lock'),
          '/bookings/7/lock-hold';
        is $r->url('booking_confirm_guest', id => 7),
          '/bookings/7/confirm/guest';
      };

      it 'route to the action named by the path' => sub {
        foreach (
          [ GET  => '/bookings/dashboard',       'dashboard'     ],
          [ POST => '/bookings/bulk-action',     'bulk_action'   ],
          [ POST => '/bookings/7/take',          'take'          ],
          [ GET  => '/bookings/7/history',       'history'       ],
          [ POST => '/bookings/7/lock-hold',     'hold'          ],
          [ GET  => '/bookings/7/confirm/guest', 'confirm_guest' ],
          [ POST => '/bookings/7/confirm/guest', 'confirm_guest' ],
          [ GET  => '/bookings/7',               'show'          ],
          [ GET  => '/bookings/new',             'new'           ],
        ) {
          my ($method, $path, $action) = @$_;
          my $match = $r->match($path, $method);
          is $match && $match->{action}, $action, "$method $path";
        }
      };

      it 'take GET alone when no method is given' => sub {
        ok !$r->match('/bookings/dashboard', 'POST');
        is $r->error, 405;
      };

      it 'carry the id constraint' => sub {
        my $c = $CLASS->new;
        $c->resource('booking', 'Booking', id => '\d+', member => 'POST take');

        ok $c->match('/bookings/7/take', 'POST');
        ok !$c->match('/bookings/x/take', 'POST');
      };
    };

    describe 'actions' => sub {
      it 'adds to the payload of one action' => sub {
        $r->resource(
          'tax', 'Tax',
          member  => 'POST archive',
          actions => {
            update  => { view => 'edit' },
            archive => { audit => 1 },
          },
        );

        is_deeply $r->match('/taxes/7', 'PUT'),
          { controller => 'Tax', action => 'update', view => 'edit', id => 7 };
        is $r->match('/taxes/7/archive', 'POST')->{audit}, 1;
        ok !exists $r->match('/taxes/7', 'GET')->{view};
      };

      it 'sends one action to another' => sub {
        $r->resource('tax', 'Tax', actions => { new => '#edit' });

        is_deeply $r->match('/taxes/new', 'GET'),
          { controller => 'Tax', action => 'edit' };
      };
    };

    describe 'refuses' => sub {
      my %bad = (
        'an unknown action in only'    => [ only => 'zap' ],
        'an unknown action in except'  => [ except => [qw/ show zap /] ],
        'an unknown action in actions' => [ actions => { zap => {} } ],
      );
      foreach my $what (sort keys %bad) {
        it $what => sub {
          eval { $r->resource('message', 'Message', @{ $bad{ $what } }) };
          like $@, qr/unknown resource action 'zap'/;
        };
      }

      it 'only and except together' => sub {
        eval { $r->resource('message', only => 'show', except => 'edit') };
        like $@, qr/'only' or 'except', not both/;
      };

      it 'a member route with no path' => sub {
        eval { $r->resource('message', member => 'POST {id2}') };
        like $@, qr/no action name in resource route/;
      };

      it 'a formatted_ name outside legacy_resources' => sub {
        $r->resource('message', 'Message');
        eval { $r->url('formatted_message', id => 7, format => 'json') };
        like $@, qr/url name 'formatted_message' not found/;
      };
    };

    it 'converts dashes to underscores in generated names' => sub {
      $r->resource('unit-type');
      ok $r->_route('unit_type');
    };
  };
};

runtests unless caller;

1;
