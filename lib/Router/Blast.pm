package Router::Blast;
# ABSTRACT: FIX ME

use strict;
use warnings;
use Carp;
use URI;
use URI::QueryParam;

our $VERSION = 0.01;

require 5.10.0; # for named captures

sub new {
  my $class = shift;

  $class = ref($class) || $class;
  my $self = bless {}, $class;

  $self->{routes} = []; # routes by insertion order
  $self->{index}  = {}; # same routes, but indexed by name
 
  # route index of the last successful match
  my $match;
  $self->{match} = \$match;

  return $self;
}


sub connect {
  my $self  = shift;
  my $name  = shift;
  my $route = shift // croak 'no route supplied';
  my %args  = @_;

  croak "Route '$name' already defined" if $self->{index}{ $name };
  $route =~ m{^/} or croak "route '$route' must begin with slash";

  delete $self->{regex}; # force recompile

  my @route = split /{([^}]+)}/, $route;
  my $is_placeholder = 0;
  my @regex;
  foreach (@route) {
    if ($is_placeholder) {
      /^([^:]+):?(.*)$/ or croak "invalid placeholder '$_'";
      my ($pname, $regex) = ($1, $2);

      my $optional = 0;
      my $pre = ''; # match before placeholder content
      if ($pname eq '.format') {
        $optional = 1;
        $pname = 'format';
        $regex = '[^.\s/]+?' unless length $regex;
        $pre = '\\.';
      } else {
        $optional = exists $args{ $pname } ? 1 : 0;
        $regex = '[^/]+?' unless length $regex;
      }

      $_ = {
        pname    => $pname,
        regex    => $regex,
        optional => $optional,
      };

      my $opt = $optional ? '?' : '';
      push @regex, "(?:$pre(?<$pname>$regex))$opt";
    } else {
      push @regex, quotemeta($_); # literal
    }
  } continue {
    $is_placeholder = !$is_placeholder;
  }

  local $_ = {
    name  => $name,
    route => \@route,
    regex => (join '', @regex),
    args  => \%args,
  };

  push @{ $self->{routes} }, $_;
  $self->{index}{ $name } = $_;

  return $self;
}


sub _compile {
  my $self = shift;

  my $routes = $self->{routes};

  my $match = $self->{match};

  # Tested faster to terminate each route with \z rather than placing
  # at end of combined regex.
  my $regex = join '|',
    map { "(?: $_->[1]{regex} \\z (?{ \$\$match = $_->[0] }))" }
    map { [$_, $routes->[$_]] }
    (0..$#{ $routes })
  ;

  # warn "Regex: $regex\n";
  use re 'eval';
  return qr/\A (?: $regex )/xu;
}


sub match {
  my $self = shift;
  my $path = shift;

  my $regex = $self->{regex} ||= $self->_compile;

  $path =~ /$regex/ or return undef;

  my $idx = ${ $self->{match} };
  my $route = $self->{routes}[ $idx ]
    or croak "no route defined for match index '$idx'?!";

  return { %{ $route->{args} }, %+ };
}


sub url {
  my $self = shift;
  my $name = shift or croak 'no url name supplied';
  my %args = @_;

  my @route;
  if (my $route = $self->{index}{ $name }) {
    @route = @{ $route->{route} };    
  } elsif ($name =~ m{^/}) {
    @route = ($name); # url, not name
  } else {
    croak "url name '$name' not found";
  }

  my $is_placeholder = 0;
  my @path;
  foreach (@route) {
    if (!$is_placeholder) {
      push @path, $_;
      next;
    }

    my $pname = $_->{pname};

    unless (exists $args{ $pname }) {
      $_->{optional}
        or croak "required param '$pname' missing from url '$name'";
      next;
    }

    my $val = delete $args{ $pname } // '';
    $val =~ /$_->{regex}/
      or croak "invalid value for param '$pname' in url '$name'";

    push @path, $val;
  } continue {
    $is_placeholder = !$is_placeholder;
  }

  my $uri = URI->new(join '', @path);
  $uri->query_param($_ => $args{$_}) foreach keys %args;

  return $uri;
}


sub with {
  my $self = shift;

  return Router::Blast::Submapper->new(
    $self,
    @_,
  );
}


package Router::Blast::Submapper;

use strict;
use warnings;
use Carp;

sub new {
  my $class  = shift;
  my $parent = shift or croak 'no parent supplied';
  my $name   = shift;
  my $route  = shift;

  my $func = (@_ && @_ % 2 && ref $_[-1] eq 'CODE') ? pop @_ : undef;

  $class = ref($class) || $class;
  my $self = bless {
    parent => $parent,
    name   => $name,
    route  => $route,
    args   => [ @_ ],
  };

  $func->($self) if $func;

  return $self;
}


sub connect {
  my $self  = shift;
  my $name  = shift;
  my $route = shift // croak 'no route supplied';
  my %args  = (@{ $self->{args} }, @_);

  my $parent = $self->{parent} or croak 'no parent?!';

  $name  = join '_', grep { defined } $self->{name}, $name;
  $route = join '', grep { defined } $self->{route}, $route;

  $parent->connect(
    $name,
    $route,
    %args,
  );

  return $self;
}


# nested submapper
sub with {
  my $self = shift;

  $self->new($self, @_);
}


1;

__END__

# vim: set foldmethod=marker:
