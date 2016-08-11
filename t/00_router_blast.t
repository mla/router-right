#!/usr/bin/env perl

use strict;
use warnings;
use POSIX ':locale_h';
use Test::More;

my $CLASS = 'Router::Blast';

use_ok $CLASS;

isa_ok $CLASS->new, $CLASS, 'constructor';
