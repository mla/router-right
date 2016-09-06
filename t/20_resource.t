#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

my $CLASS = 'Router::Right';

use_ok $CLASS;

my $r = $CLASS->new;
is $r->as_string, '', 'no routes to start';

done_testing();
exit 0;

$r->resource('message');
my $str = $r->as_string;
$str =~ s/\s+//g;

my $expected = qq{
              messages GET    /messages{.format}
                       POST   /messages{.format}
    formatted_messages GET    /messages.{format}
           new_message GET    /messages/new{.format}
 formatted_new_message GET    /messages/new.{format}
               message GET    /messages/{id}{.format}
                       PUT    /messages/{id}{.format}
                       DELETE /messages/{id}{.format}
     formatted_message GET    /messages/{id}.{format}
          edit_message GET    /messages/{id}{.format}/edit
formatted_edit_message GET    /messages/{id}.{format}/edit
};
$expected =~ s/\s+//g;

is $str, $expected, 'resource routes added';

done_testing();

1;
