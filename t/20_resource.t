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

  describe 'resource' => sub {

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
};

runtests unless caller;

1;
