package Router::Right;
# ABSTRACT: Fast, framework-agnostic URL routing engine for web applications

use strict;
use warnings;
use 5.10.0; # named captures, see perlver
use Carp;
use Data::Dump ();
use Lingua::EN::Inflect qw/ PL_N /;
use List::Util qw/ max /;
use List::MoreUtils qw/ any uniq /;
use URI;

our $VERSION = '2.00';

use parent qw/ Exporter /;

our @EXPORT_OK = qw/ NOT_FOUND METHOD_NOT_ALLOWED /;

sub NOT_FOUND          () { 404 }
sub METHOD_NOT_ALLOWED () { 405 }

# Set by a successful match to the name of the (*MARK) it passed through,
# which is the index of the route group that matched. Perl sets it in the
# package of the code running the match, so it must be this one.
our $REGMARK;

# A node with more routes than this matches without the placeholders'
# captures, and the matched route's own regex takes them: each capture in
# the alternation slows every branch tried, so a large node pays for many.
our $CAPTURE_LIMIT = 32;


sub new {
  my $class = shift;
  my %args  = @_;

  $class = ref($class) || $class;

  # Every scope made by with() shares this table; what differs between them
  # is the prefix below.
  my %table = (
    routes      => [],      # routes in insertion order, grouped by path
    route_index => {},      # path => route index of group in above routes[]
    name_index  => {},      # route name => route
    match       => undef,   # route group index of last match
    error       => undef,   # status code of last match
    compiled    => {},      # per method: regex and literal paths; see _compile
    shared      => {},      # regex and literal paths by the groups they cover
    methods     => {},      # every method some route names
    refused     => undef,   # path of the last match refused for its method
    legacy_methods => $args{legacy_methods} // $args{legacy},
    legacy      => $args{legacy},
    legacy_resources => $args{legacy_resources} // $args{legacy},
  );

  return bless {
    table => \%table,
    name  => undef,         # prefix joined to each route name
    path  => undef,         # prefix joined to each route path
    args  => {},            # defaults merged under each route's args
  }, $class;
}


# The values given, with array refs flattened and undefs dropped.
sub _list {
  my $class = shift;

  return grep { defined } map { ref $_ eq 'ARRAY' ? @$_ : $_ } @_;
}


# mainly for testing right now
sub _route {
  my $self = shift;
  my $name = shift // croak 'no name supplied';

  return $self->{table}{name_index}{ $name };
}


# Given a route path, returns the associated route group index
sub _group_index {
  my $self = shift;
  my $path = shift or croak 'no route path supplied';

  my $table = $self->{table};
  return $table->{route_index}{ $path } //= @{ $table->{routes} };
}


sub error {
  my $self = shift;

  if (@_) {
    $self->{table}{error} = shift;
    return;
  }

  return $self->{table}{error};
}


sub _parse_payload {
  my $self = shift;
  my $payload = shift || {};

  return $payload      if ref $payload eq 'HASH';

  !ref $payload or croak "unexpected payload '$payload'";

  my ($controller, $action) = split /#/, $payload, 2;

  return {
    $controller ? (controller => $controller) : (),
    $action     ? (action => $action) : (),
  };
}


sub _merge_payload {
  my $self = shift;
  my ($payload, $add) = @_;

  $payload ||= {};

  my %add = %$add;
  my $controller = $add{controller};
  if ($controller && $controller =~ /^::/ && $payload->{controller}) {
    $add{controller} = $payload->{controller} . $controller;
  }

  @{ $payload }{ keys %add } = values %add;

  return $payload;
}


sub _args {
  my $self = shift;
  my @args = (@_ % 2 ? (payload => @_) : @_);

  my %merged;
  while (@args) {
    my $key = shift @args;
    if ($key eq 'payload') {
      my $payload = $self->_parse_payload(shift @args);
      $merged{ $key } = $self->_merge_payload($merged{ $key }, $payload);
    } elsif ($key eq 'methods') {
      $merged{ $key } = [ $self->_list($merged{ $key }, shift @args) ];
    } else {
      $merged{ $key } = shift @args;
    }
  }

  return %merged;
}


# Given a route path, splits off the allowed methods prefix, if any.
# See ROUTE DEFINTION in the POD.
sub _split_route_path {
  my $self = shift;
  my $path = shift or return;

  $path =~ m{^\s* (?:([^/]+)\s+)? ([/\{].*)}x
    or croak "invalid route path specification '$path'";
  return ($1, $2); # methods, path
}


sub _methods {
  my $self = shift;

  my @methods = 
    sort { $a cmp $b }
    uniq 
    map  { s/^\s+|\s+$//g; uc $_ }
    map  { split '[|,]' }
    $self->_list(@_)
  ;
  @methods = () if any { $_ eq '*' } @methods;

  return wantarray ? @methods : \@methods;
}


# A placeholder's pattern may hold braces of its own ({id:\d{3}}), as long
# as they balance.
my $PLACEHOLDER = qr/
  \{ ( (?: [^{}]++ | ( \{ (?: [^{}]++ | (?-1) )*+ \} ) )*+ ) \}
/x;


# Alternating literals and placeholder specs, starting with a literal that
# is empty when the path opens with a placeholder.
sub _split_placeholders {
  my $class = shift;
  my $route = shift;

  my @parts;
  my $literal = '';
  pos($route) = 0;
  while (pos($route) < length $route) {
    if ($route =~ /\G([^{]+)/gc) {
      $literal .= $1;
    } elsif ($route =~ /\G$PLACEHOLDER/gc) {
      push @parts, $literal, $1;
      $literal = '';
    } else {
      croak "unbalanced brace in route path '$route'";
    }
  }
  push @parts, $literal if length $literal;

  return @parts;
}


sub _build_route {
  my $class = shift;
  my $route = shift or croak 'no route supplied';

  my @route = $class->_split_placeholders($route);
  my @regex;
  my @bare;
  my @captures;
  my $is_placeholder = 0;
  my %placeholders;
  foreach (@route) {
    if ($is_placeholder) {
      /^([^:]+):?(.*)$/s or croak "invalid placeholder '$_'";
      my ($pname, $regex) = ($1, $2);
      $pname =~ /\A(?:\.format|[A-Za-z_]\w*)\z/
        or croak "invalid placeholder name '$pname'";

      # {.format} is optional, and written after a dot.
      my $format = $pname eq '.format';
      if ($format) {
        $pname = 'format';
        $regex = '[^.\s/]+?' unless length $regex;
      }

      croak "placeholder '$pname' redefined" if $placeholders{ $pname }++;

      # url() tests the default pattern without a regex, which is slower.
      # A pattern of one's own keeps its own flags: (?^:...) stops the
      # combined regex's /x dropping a space or reading # as a comment.
      my $check;
      if (length $regex) {
        eval { qr/\A(?:$regex)\z/ }
          or croak "invalid pattern for placeholder '$pname': $@";
        _refers_to_group($regex) and croak "pattern for placeholder "
          . "'$pname' refers to a group (\\1, \\g, \\k, (?1), (?&name), "
          . "(?R) or a condition on one); groups are numbered across all "
          . "routes, so write it without";
        $regex = "(?^:$regex)";
        $check = qr/\A$regex\z/;
      } else {
        $regex = '[^/]+?';
      }

      $_ = { pname => $pname, check => $check, format => $format };

      # A pattern may name captures of its own; match() returns those too.
      push @captures, $pname, $regex =~ /\(\?P?[<']([A-Za-z_]\w*)[>']/g;

      push @regex, $format
        ? "(?:\\.(?<$pname>$regex))?"
        : "(?<$pname>$regex)";
      push @bare, $format ? "(?:\\.(?:$regex))?" : "(?:$regex)";
    } else {
      push @regex, quotemeta($_); # literal
      push @bare, quotemeta($_);
    }
  } continue {
    $is_placeholder = !$is_placeholder;
  }

  # The regex without the placeholders' own captures, for the combined
  # regex: a capture in each of many alternatives slows every branch.
  my $regex = join '', @regex;
  my $bare = join '', @bare;

  return \@route, $regex, \@captures, $bare;
}


# Whether a pattern refers to one of its groups: a back-reference,
# recursion, or a condition on a group. Perl would resolve it against the
# combined regex, where the groups are numbered after every other route's
# and a name may be another route's. Escapes and character classes are
# skipped, so \\1 and [\1] are not references.
my $REFERENCE = qr{
    \\ [1-9gk]                       # \1, \g1, \g{-1}, \g{name}, \k<name>
  | \( \? (?: [-+]?\d | R\) | & | P[=>] )  # (?1), (?-1), (?R), (?&n), (?P=n)
  | \( \? \( (?! \? )                 # (?(1)...), (?(<n>)...), (?(R)...)
}x;

sub _refers_to_group {
  my $pattern = shift;

  my $skip = qr{ \\. | \[ \^? \]? (?: \\. | [^\]] )* \] | . }xs;
  while ($pattern =~ /\G (?: ($REFERENCE) | $skip )/gcx) {
    return 1 if defined $1;
  }

  return 0;
}


# What a route or scope declared under this one is called, where it lives
# and its args laid over this scope's. Methods it names replace the scope's
# rather than adding to them, so a route can narrow what its scope allows.
# A route with no name stays unnamed whatever the scope is called.
sub _declare {
  my $self = shift;
  my $name = shift;
  my $path = shift;

  (my $methods, $path) = $self->_split_route_path($path);

  $name = join '_', grep { defined && length } $self->{name}, $name
    if defined $name;
  $path = join '', grep { defined } $self->{path}, $path;

  my %args  = $self->_args(@_, methods => $methods);
  my %scope = %{ $self->{args} };
  delete $scope{methods} if @{ $args{methods} };

  return ($name, $path, $self->_args(%scope, %args));
}


sub add {
  my $self = shift;
  my $name = shift;
  my $path = shift // croak 'no route path supplied';

  ($name, $path, my %args) = $self->_declare($name, $path, @_);
  length $path or croak 'no route path supplied';

  my $table = $self->{table};

  my $payload = delete $args{payload} or croak 'no payload defined';
  if (defined $name && $table->{name_index}{ $name }) {
    croak "route '$name' already defined";
  }

  my @methods = $self->_methods($args{methods});

  my ($route, $regex, $captures, $bare) = $self->_build_route($path);

  my $index = $self->_group_index($path);

  # A second name for a route is fine; a second payload is never reached.
  foreach my $earlier (@{ $table->{routes}[ $index ] || [] }) {
    my %taken = map { $_ => 1 } @{ $earlier->{methods} };
    next if %taken and !@methods || grep { !$taken{ $_ } } @methods;
    last if Data::Dump::dump($earlier->{payload}) eq Data::Dump::dump($payload);

    my $error = sprintf "route %s can never match: %s already takes %s %s",
      map({ defined $_->{name} ? "'$_->{name}'" : 'with no name' }
        { name => $name }, $earlier),
      join(',', @methods) || 'every method on', $path;
    $table->{legacy} or croak $error;
    carp $error;
    last;
  }

  local $_ = {
    name    => $name,
    path    => $path,
    route   => $route,
    index   => $index,
    regex   => $regex,
    bare    => $bare,
    captures => $captures,
    methods => \@methods,
    payload => $payload,
    args    => \%args,
  };

  push @{ $table->{routes}[ $index ] ||= [] }, $_;
  $table->{name_index}{ $name } = $_ if defined $name;
  $table->{methods}{ $_ } = 1 foreach @methods;
  $table->{compiled} = {};
  $table->{shared} = {};

  return $self;
}


# The matcher for one request method, over the paths with a route that
# takes it: an index of literal paths, and a tree of the others keyed by
# the whole literal segments they start with. Each node holds a regex over
# its routes and its ancestors', in the order defined, so the first match
# in the node a path reaches is the answer, and a request is tried only
# against routes that could match it. A literal path is looked up in the
# index instead, unless an earlier route with a placeholder matches it.
#
# $method is '' for every path whatever its methods, and '*' for a method
# no route names, which only routes taking every method answer.
sub _compile {
  my $self   = shift;
  my $method = shift // '';

  my $table = $self->{table};

  # Group index => its route for the method. Routes in a group share a
  # path, so the one taken stands for the group.
  my @takes =
    map { scalar $self->_route_for_method($_, $method) }
    @{ $table->{routes} };
  my @groups = grep { $_ } @takes;

  # Methods taken on the same paths, as GET and HEAD usually are, share a
  # tree and literal index; only the route each takes differs.
  my $paths = join ',', map { $_->{index} } @groups;
  my $shared = $table->{shared}{ $paths } ||= do {
    # child by segment, regex, its groups, chain, lowest index, captures,
    # fast (see _compile_node)
    my $root = [ {}, undef, [], undef, undef ];
    foreach my $group (grep { @{ $_->{route} } > 1 } @groups) {
      my $node = $root;
      $node = $node->[0]{ $_ } ||= [ {}, undef, [], undef, undef ]
        foreach _segments($group->{route}[0]);
      push @{ $node->[2] }, $group;
    }
    _compile_node($root, []);

    my %static;
    foreach (grep { @{ $_->{route} } == 1 } @groups) {
      my $earlier = _search(_node($root, $_->{path}), $_->{path});
      next if defined $earlier && $earlier < $_->{index};
      $static{ $_->{path} } = $_->{index};
    }

    [ $root, \%static ];
  };

  return $table->{compiled}{ $method } = [ @$shared, \@takes ];
}


# The whole segments a route's leading literal holds: '/a/b/' and '/a/b/c'
# give (a, b), the segment holding the first placeholder left out.
sub _segments {
  my $literal = shift;

  $literal =~ s{\A/}{} or return;
  my @segments = split m{/}, $literal, -1;
  pop @segments;

  return @segments;
}


# A node's regex is over its own routes only, in the order defined, so its
# first match is the earliest of them to match. A route an ancestor holds
# is not repeated below it: the chain, the node and its ancestors that hold
# routes, ordered by the earliest route each holds, is searched instead.
sub _compile_node {
  my ($node, $ancestors) = @_;

  my $groups = $node->[2];

  if (@$groups) {
    # The literal every route here starts with is matched once, ahead of
    # the alternation. Left in it, Perl would build a trie on it, and a trie
    # whose words all match tries them in quadratic time.
    my $prefix = $groups->[0]{route}[0];
    foreach (@$groups) {
      chop $prefix while index($_->{route}[0], $prefix) != 0;
    }
    my $skip = length quotemeta $prefix;

    # Tested faster to terminate each route with \z rather than placing
    # at end of combined regex.
    my $captures = @$groups <= $CAPTURE_LIMIT;
    my $field = $captures ? 'regex' : 'bare';
    my $regex = join '|',
      map { '(?: ' . substr($_->{ $field }, $skip) . " \\z (*MARK:$_->{index}))" }
      @$groups;
    $node->[5] = $captures;
    $node->[1] = qr/\A \Q$prefix\E (?: $regex )/x;
    $node->[4] = $groups->[0]{index};
  }

  my @holding = grep { @{ $_->[2] } } @$ancestors, $node;
  $node->[3] = [ sort { $a->[4] <=> $b->[4] } @holding ];

  # The usual case, which match() takes without the chain: the node is the
  # only one holding routes for its paths, and captures their values.
  $node->[6] = @holding == 1 && $holding[0] == $node && $node->[5];

  _compile_node($_, \@holding) foreach values %{ $node->[0] };
}


# The earliest route in a node's chain to match the path, or undef.
# In the chain's order, a node whose earliest route comes after the best
# match so far cannot improve on it, nor can any node after it.
sub _search {
  my ($node, $path) = @_;

  my $best;
  foreach my $n (@{ $node->[3] }) {
    last if defined $best && $best < $n->[4];
    $path =~ $n->[1] or next;
    $best = $REGMARK if !defined $best || $REGMARK < $best;
  }

  return $best;
}


# The deepest node a path reaches, a whole segment at a time.
sub _node {
  my ($node, $path) = @_;

  my $at = 1;
  while ((my $end = index $path, '/', $at) > 0) {
    $node = $node->[0]{ substr $path, $at, $end - $at } || last;
    $at = $end + 1;
  }

  return $node;
}


# The compiled matcher for a request method, which is upper case or ''.
# Methods no route names share one, so a request cannot make more of them.
sub _matcher {
  my $self   = shift;
  my $method = shift;

  my $table = $self->{table};
  my $key = !length $method || $table->{methods}{ $method } ? $method : '*';

  return $table->{compiled}{ $key } || $self->_compile($key);
}


sub _match_class { 'Router::Right::Match' }


# The first of a path's routes to take the method, which is upper case; the
# first of them when it is ''.
sub _route_for_method {
  my $self   = shift;
  my $routes = shift;
  my $method = shift;

  length $method or return $routes->[0];

  foreach my $route (@$routes) {
    my $allowed = $route->{methods};
    return $route if !@$allowed or any { $method eq $_ } @$allowed;
  }

  return;
}


# Every path that matches, whatever its methods.
sub _groups_matching {
  my $self = shift;
  my $path = shift;

  my $table = $self->{table};
  my ($root) = @{ $self->_matcher('') };

  # A literal route's path is the path it matches.
  my $literal = $table->{route_index}{ $path };
  $literal = undef
    if defined $literal && @{ $table->{routes}[ $literal ][0]{route} } > 1;

  return sort { $a <=> $b }
    (grep { defined } $literal),
    map  { $_->{index} }
    grep { $path =~ ($_->{anchored} ||= qr/\A(?:$_->{regex})\z/) }
    map  { @{ $_->[2] } }
    @{ _node($root, $path)->[3] };
}


sub match {
  my $self   = shift;
  my $path   = shift;
  my $method = shift;

  my $table = $self->{table};
  $table->{match} = $table->{error} = $table->{refused} = undef;

  $method = uc($method // '');

  # The matcher of the routes taking this method: its first match is the
  # route. Under legacy_methods, the matcher of every path: its first match
  # owns the request, and is a 405 when none of its routes takes the method.
  my $legacy = $table->{legacy_methods};
  my $key = $legacy ? '' : $method;
  my ($root, $static, $takes) =
    @{ $table->{compiled}{ $key } || $self->_matcher($key) };

  my %captured;
  my $index = $static->{ $path };
  if (!defined $index) {
    # _node(), inline: this is the hot path.
    my ($node, $at) = ($root, 1);
    while ((my $end = index $path, '/', $at) > 0) {
      $node = $node->[0]{ substr $path, $at, $end - $at } || last;
      $at = $end + 1;
    }

    # _search(), inline: this is the hot path. A node that captures has
    # its values read here, while %+ is its own, and by name: copying %+
    # walks every name in the regex.
    my $read = $node->[6];
    if ($read) {
      if ($path =~ $node->[1]) {
        $index = $REGMARK;
        foreach (@{ $table->{routes}[ $index ][0]{captures} }) {
          my $value = $+{ $_ };
          $captured{ $_ } = $value if defined $value;
        }
      }
    } else {
      foreach my $n (@{ $node->[3] }) {
        last if defined $index && $index < $n->[4];
        $path =~ $n->[1] or next;
        next if defined $index && $REGMARK > $index;
        $index = $REGMARK;
        %captured = ();
        $read = $n->[5] or next;
        foreach (@{ $table->{routes}[ $index ][0]{captures} }) {
          my $value = $+{ $_ };
          $captured{ $_ } = $value if defined $value;
        }
      }
    }

    if (!defined $index) {
      # A 405 if a route for another method has the path. Not when this
      # matcher already covers every path, as the one for '' does.
      my ($all, $paths) = @{ $table->{compiled}{''} || $self->_matcher('') };
      $all != $root && (exists $paths->{ $path }
        || defined _search(_node($all, $path), $path))
        or return $self->error(NOT_FOUND);

      $table->{refused} = $path;
      return $self->error(METHOD_NOT_ALLOWED);
    }

    # A node that does not capture leaves the values to the route's regex.
    my $route;
    if (!$read && @{ ($route = $table->{routes}[ $index ][0])->{captures} }) {
      $path =~ ($route->{anchored} ||= qr/\A(?:$route->{regex})\z/);
      foreach (@{ $route->{captures} }) {
        my $value = $+{ $_ };
        $captured{ $_ } = $value if defined $value;
      }
    }
  }

  $table->{match} = $index;
  my $matched_route = $legacy
    ? $self->_route_for_method($table->{routes}[ $index ], $method)
    : $takes->[ $index ];
  $matched_route or return $self->error(METHOD_NOT_ALLOWED);

  my $payload = { %{ $matched_route->{payload} }, %captured };
  my $match_class = $self->_match_class;

  $match_class or return $payload; # Raw hash, no blessing

  if (ref $match_class eq 'CODE') {
    return $match_class->($self, $payload, $matched_route);
  }

  # The default class, without the method call and checks of new().
  return Router::Right::Match::_make($payload, $matched_route)
    if $match_class eq 'Router::Right::Match';

  return $match_class->new($payload, $matched_route);
}


# Characters a path segment may carry as they are (RFC 3986 pchar), plus the
# slash, which only a placeholder whose pattern admits it can receive.
# Not handed to URI::Escape: its 3.31 (URI 1.72) compiles a custom class in a
# string eval, so '$&' and '@/' here interpolated as variables.
my $PATH_UNSAFE = qr{([^A-Za-z0-9\-._~!\$&'()*+,;=:\@/])};


my %ESCAPE = map { chr($_) => sprintf '%%%02X', $_ } 0 .. 255;


sub _escape_path {
  my $class = shift;
  my $value = shift;

  utf8::encode($value);
  $value =~ s/$PATH_UNSAFE/$ESCAPE{ $1 }/g;

  return $value;
}


sub url {
  my $self = shift;
  my $name = shift;
  defined $name && length $name or croak 'no url name supplied';

  my %args = (@_, @_ % 2 ? undef : ());

  my $route;
  if (my $named = $self->{table}{name_index}{ $name }) {
    $route = $named->{route};
  } elsif ($name =~ m{^/}) { # url, not a route name
    # has placeholders? if so, parse it; otherwise it is a string literal
    $route = $name =~ /{/ ? ($self->_build_route($name))[0] : [ $name ];
  } else {
    croak "url name '$name' not found";
  }

  my $path = '';
  foreach (@$route) {
    if (!ref) {
      $path .= $_;
      next;
    }

    my $pname = $_->{pname};

    my $supplied = exists $args{ $pname };
    $supplied || $_->{format}
      or croak "required param '$pname' missing from url '$name'";

    my $pval = delete $args{ $pname } // '';
    $pval = $self->_resolve_param($pname, $pval) // '' if $supplied;
    next if $_->{format} && !length $pval;

    ($_->{check} ? $pval =~ $_->{check} : length $pval && $pval !~ tr{/}{})
      or croak "invalid value for param '$pname' in url '$name': '$pval'";

    $path .= '.' if $_->{format};
    $path .= $pval =~ tr{-A-Za-z0-9._~!$&'()*+,;=:@/}{}c
      ? $self->_escape_path($pval)
      : $pval;
  }

  %args or return URI->new($path);

  # What is left is the query: each param in the place it was first
  # passed, with the value it was last passed.
  my @query;
  for (my $i = 0; $i < @_; $i += 2) {
    my $key = $_[ $i ];
    push @query, $key => delete $args{ $key } if exists $args{ $key };
  }

  # Written as query_form() writes it, so that URI parses the URL once.
  # Left to URI: a path holding its own query or fragment, one ending in
  # whitespace (URI->new trims it), and an undefined value, which URI
  # writes as a bare key in some releases and as 'key=' in others.
  my $simple = $path !~ /[?#]|\s\z/;
  my @pairs;
  for (my $i = 0; $simple && $i < @query; $i += 2) {
    my ($key, $vals) = @query[ $i, $i + 1 ];
    $key = '' unless defined $key;
    $key =~ s{([;/?:\@&=+,\$\[\]%])}{$ESCAPE{ $1 }}g;
    $key =~ tr/ /+/;
    foreach (ref $vals eq 'ARRAY' ? @$vals : $vals) {
      defined or $simple = 0, last;
      my $val = "$_";
      $val =~ s{([;/?:\@&=+,\$\[\]%])}{$ESCAPE{ $1 }}g;
      $val =~ tr/ /+/;
      push @pairs, "$key=$val";
    }
  }

  if (!$simple) {
    my $uri = URI->new($path);
    $uri->query_form(\@query);
    return $uri;
  }
  @pairs or return URI->new($path);

  my $query = join $URI::DEFAULT_QUERY_FORM_DELIMITER || '&', @pairs;
  $query =~ s/([^$URI::uric])/URI::Escape::escape_char($1)/ego;

  return URI->new("$path?$query");
}


# Hook for subclasses to transform parameter values before URL
# generation. Called for each placeholder parameter. Override to
# implement object deflation, type coercion, etc.
#
#  my ($self, $pname, $pval) = @_;
sub _resolve_param { $_[2] }


sub with {
  my $self = shift;
  my $name = shift;
  my $path = shift;

  ($name, $path, my %args) = $self->_declare($name // '', $path, @_);
  my $call = delete $args{call};

  my $scope = bless {
    table => $self->{table},
    name  => $name,
    path  => $path,
    args  => \%args,
  }, ref $self;

  if ($call) {
    local $_ = $scope;
    $call->($scope);
  }

  return $scope;
}


sub allowed_methods {
  my $self = shift;

  my $table = $self->{table};

  my @indexes;
  if (@_) {
    my $path;
    if ($_[0] !~ m{/}) { # route name, not path
      my $name = shift;
      my $route = $table->{name_index}{ $name } or return;
      $path = $route->{path};
    } else {
      $path = shift;
    }

    @indexes = ($table->{route_index}{ $path });
  } else {
    @indexes = defined $table->{refused}
      ? $self->_groups_matching($table->{refused})
      : ($table->{match});
  }
  defined $indexes[0] or return;

  my @routes = map {
    @{ $table->{routes}[ $_ ] or croak "no routes found for index '$_'?!" }
  } @indexes;

  return $self->_methods(map { $_->{methods} } @routes);
}


sub routes {
  my $self = shift;

  return map { @$_ } @{ $self->{table}{routes} };
}


sub as_string {
  my $self = shift;

  my @routes;
  my %max = (name => 0, method => 0, path => 0);
  foreach ($self->routes) {
    my $name    = $_->{name} // '';

    my $methods = join ',', @{ $_->{methods} };
    $methods ||= '*';

    $max{name}   = max($max{name}, length $name);
    $max{method} = max($max{method}, length $methods);
    $max{path}   = max($max{path}, length $_->{path});

    local $Data::Dump::INDENT = '';
    my $payload = Data::Dump::dump($_->{payload});
    $payload =~ s/\v+/ /g; # strip any vertical whitespace

    push @routes, [ $name, $methods, $_->{path}, $payload ];
  }

  my $str = '';
  foreach (@routes) {
    $str .= sprintf "%$max{name}s %-$max{method}s %-$max{path}s %s\n", @$_;
  }
  return $str;
}


# action, route name, methods, path below the collection. In a name, %m is
# the member and %c the collection.
my @RESOURCE = (
  [ index  => '%c',      'GET',       '{.format}' ],
  [ create => undef,     'POST',      '{.format}' ],
  [ new    => '%m_new',  'GET',       '/new{.format}' ],
  [ show   => '%m',      'GET',       '/{id}{.format}' ],
  [ update => undef,     'PUT|PATCH', '/{id}{.format}' ],
  [ delete => undef,     'DELETE',    '/{id}{.format}' ],
  [ edit   => '%m_edit', 'GET',       '/{id}/edit{.format}' ],
);

# What resource() built through 1.05, after Python's Routes.
my @LEGACY_RESOURCE = (
  [ index  => '%c',                'GET',    '{.format}' ],
  [ create => undef,               'POST',   '{.format}' ],
  [ index  => 'formatted_%c',      'GET',    '.{format}' ],
  [ new    => 'new_%m',            'GET',    '/new{.format}' ],
  [ new    => 'formatted_new_%m',  'GET',    '/new.{format}' ],
  [ show   => '%m',                'GET',    '/{id}{.format}' ],
  [ update => undef,               'PUT',    '/{id}{.format}' ],
  [ delete => undef,               'DELETE', '/{id}{.format}' ],
  [ show   => 'formatted_%m',      'GET',    '/{id}.{format}' ],
  [ edit   => 'edit_%m',           'GET',    '/{id}{.format}/edit' ],
  [ edit   => 'formatted_edit_%m', 'GET',    '/{id}.{format}/edit' ],
);


sub _resource_table {
  my $self = shift;

  return $self->{table}{legacy_resources} ? @LEGACY_RESOURCE : @RESOURCE;
}


# A member or collection route as a row of the resource table:
# 'POST {op}-hold' => [ 'hold', '%m_hold', 'POST', '/{op}-hold' ]. GET when
# no method is given, so a route cannot change something on a GET by
# omission.
sub _resource_extra {
  my $self = shift;
  my $on   = shift;
  my $spec = shift // '';

  my ($methods, $path) = $spec =~ m{\A\s* (?:(\S+)\s+)? /?(\S+) \s*\z}x
    or croak "invalid resource route '$spec'";

  (my $action = $path) =~ s/$PLACEHOLDER//g;
  $action =~ s/\W+/_/g;
  $action =~ s/^_+|_+$//g;
  length $action or croak "no action name in resource route '$spec'";

  return [ $action, "%${on}_$action", $methods // 'GET', "/$path" ];
}


sub resource {
  my $self   = shift;
  my $member = shift or croak 'no resource member name supplied';
  my %args   = $self->_args(@_);

  my $extra_collection = delete $args{collection};
  my $plural = delete $args{plural};
  if (defined $extra_collection && !ref $extra_collection) {
    $plural //= $extra_collection;
    $extra_collection = undef;
  }
  $plural //= PL_N($member);

  my %name = (m => $member, c => $plural);
  s/-/_/g foreach values %name;

  my $id = delete $args{id};
  $id = defined $id ? "{id:$id}" : '{id}';

  # A pattern for the format, or a false value for routes with no format.
  my $format = '{.format}';
  if (exists $args{format}) {
    my $pattern = delete $args{format};
    $format = $pattern ? "{.format:$pattern}" : '';
  }

  my @table = $self->_resource_table;
  @table = grep { $_->[3] !~ /\{format\}/ } @table if !$format;
  my %known = map { $_->[0] => 1 } @table;

  my $only   = delete $args{only};
  my $except = delete $args{except};
  !($only && $except) or croak "resource takes 'only' or 'except', not both";
  my $unknown = sub {
    $known{ $_ } or croak "unknown resource action '$_'" foreach sort @_;
  };

  my %listed = map { $_ => 1 } $self->_list($only // $except);
  $unknown->(keys %listed);
  @table = grep { $only ? $listed{ $_->[0] } : !$listed{ $_->[0] } } @table
    if $only || $except;

  foreach (@table) {
    $_ = [ @$_ ];
    $_->[3] =~ s/\{id\}/$id/;
    $_->[3] =~ s/\{\.format\}/$format/;
  }

  # Collection routes go first, or /{id} would take their paths.
  my @routes = (
    map({ $self->_resource_extra(c => $_) }
      $self->_list($extra_collection)),
    @table,
    map({ $_->[3] = "/$id$_->[3]"; $_ }
      map  { $self->_resource_extra(m => $_) }
      $self->_list(delete $args{member})),
  );

  my $actions = delete $args{actions} || {};
  $known{ $_->[0] } = 1 foreach @routes;
  $unknown->(keys %$actions);

  $self->with(delete $args{name}, delete $args{path}, %args, call => sub {
    my $scope = shift;

    foreach (@routes) {
      my ($action, $name, $methods, $path) = @$_;
      $name =~ s/%([mc])/$name{ $1 }/ if defined $name;

      $scope->add(
        $name => "$methods /$plural$path",
        payload => { action => $action },
        exists $actions->{ $action } ? (payload => $actions->{ $action }) : (),
      );
    }
  });

  return $self;
}


package Router::Right::Match;

# Default match object. Note that it uses inside-out object design
# (see the "Inside-Out Objects" section of perldoc perlobj)

use strict;
use warnings;
use Carp;
use Hash::Util qw/ fieldhash /;

fieldhash my %routes;


sub new {
  my $class = shift;
  my $data  = shift or croak 'no data supplied';
  my $route = shift or croak 'no route supplied';

  $class = ref($class) || $class;

  my $self = bless $data, $class;
  $routes{ $self } = $route;

  return $self;
}


# new() for match(), which has checked what it passes: data, route.
sub _make {
  $routes{ $_[0] } = $_[1];
  return bless $_[0], __PACKAGE__;
}


foreach my $field (qw/ name path methods payload route index regex args /) {
  no strict 'refs';
  *{ $field } = sub {
    my $route = $routes{ $_[0] } or return;
    return $route->{ $field };
  };
}


1;

__END__

=encoding utf8

=head1 SYNOPSIS

  use Router::Right;

  my $r = Router::Right->new;

  $r->add(home => '/', 'Home#show');
  $r->add(blog => '/blog/{year}/{month}', 'Blog#monthly');

  my $match = $r->match('/blog/1916/08'); 

  # Returns {
  #   controller => 'Blog',
  #   action => 'monthly',
  #   year => '1916',
  #   month => '08',
  # }

=head1 DESCRIPTION

Router::Right is a Perl5-based, framework-agnostic routing engine used to
map web application request URLs to application handlers.

=head1 METHODS

=over 4

=item new([ legacy => 1 ])

Returns a new Router::Right instance.

C<< legacy => 1 >> keeps the behaviour of 1.05 and earlier, so that a set
of routes written for it loads and matches as it did: it turns on
legacy_resources (see resource()) and legacy_methods (see match()), and a
route that can never match is warned about rather than refused. Either of
the two may be given on its own, or turned off beside legacy
(C<< legacy => 1, legacy_resources => 0 >>), to move over one at a time.

=item add($name => $route_path, \%payload [, %options])

Define a route. $name is used to reference the route elsewhere. On a successful match, the payload hash reference is returned; by convention, a payload includes "controller" and "action" values. For example:

  $r->add(entries => '/entries', { controller => 'Entries', action => 'show' })

See the ROUTE DEFINITION section for details on how $route_path values are specified.

Also, if the payload consists solely of controller and action values, it can be specified as a string in the format "controller#action". For example:

  $r->add(entries => '/entries', 'Entries#show')

is exactly equivalent to specifying a payload of: { controller => 'Entries', action => 'show' }.

By default, routes match any HTTP request method (e.g., GET, POST). To restrict them, supply a "methods" option. e.g.,

  $r->add(entries => '/entries', 'Entries#show', methods => 'GET')

That would only match GET requests. The value may be either a string or an array reference of
strings. e.g.,

  $r->add(entries => '/entries', 'Entries#show', methods => [qw/ GET POST /])

Method strings are case-insensitive. As a convenience, the allowed methods can also be specified
as part of the route path itself. e.g.,

  $r->add(entries => 'GET|POST /entries', 'Entries#show')

=item match($url [, $method])

Attempts to find a route that matches the supplied $url. Routes are tried
in the order defined, and the first whose path matches and which takes
$method is the match. A route restricted to POST does not answer a GET for
its path, so a later route that matches the path and takes GET does;
restrict or order wide routes such as C</x/{id}/{action}> with that in mind.

A router built with C<< legacy_methods => 1 >> keeps the rule of 1.05 and
earlier: the first path to match owns the request, and when none of the
routes with that path takes $method the result is a 405, though a later
route would have taken it. Routes share a path there only when it is
written identically; C</x/{id}> and C</x/{id:\d+}> are two paths.

If a match is found, its associated payload is returned. If not, undef is returned and the error() method will indicate why the match failed.

While the payload is always a hash reference, starting with version 1.05,
it is also blessed into the Router::Right::Match class, which provides
access to the route definition that resulted in the match through the
methods C<name>, C<path>, C<methods>, C<payload>, C<route>, C<index>,
C<regex> and C<args>. Any other method name dies.

$method, if supplied, is the HTTP method of the request (e.g., GET, POST, etc.). Specifying $method may prevent a route from otherwise matching if the route was defined with a restricted set of allowed methods (see ROUTE DEFINITION). By default, all request methods are allowed.

A placeholder's value replaces a payload value of the same name, so a
route such as C</{controller}/{action}> lets the path choose both.

=item error()

Returns the error code of the last failed match.

  404 = no match found
  405 = method not allowed

A 405 result indicates that routes have this path, but none of them takes
the request method. allowed_methods() can be called to obtain the methods
they do take. A route that takes every method, such as a catch-all at the
end, matches instead, so there is no 405 for a path it covers.

The above error codes are also available as symbolic constants through the NOT_FOUND and
METHOD_NOT_ALLOWED functions.

=item allowed_methods([ $name ])

Returns the list of allowed methods for a given route name or path. In list context, returns a list. In scalar context, returns an array reference. An empty list/array indicates that all methods are
permitted.

If route $name is supplied, returns its permitted methods. Returns undef in scalar context if the route is unknown. If $name contains a forward slash, it's intepreted as a route path, instead.

With no argument, returns the methods permitted by the last match()
attempt: those of the matched path, or after a 405 those of every route
whose path matched. Returns undef in scalar context if there was no prior
match.

  $r->add(entries => 'PUT|GET /entries', { controller => 'Entries' });
  print join(', ', $r->allowed_methods('entries')), "\n"; # prints GET, PUT

=item url($name [, %params])

Constructs a URL from the $name route. Placeholder values are supplied as %params. Unknown placeholder values are appended as query string parameters.

Example:

  $r->add(entry => '/entries/{year}', { controller => 'Entry' });
  $r->url('entry', year => '1916', q => 'abc'); # produces /entries/1916?q=abc 

Each placeholder value must match the placeholder's whole pattern, or url()
dies. Values are percent-encoded as UTF-8, except for the characters a path
segment may carry as they are and the forward slash, which only a placeholder
whose pattern admits it will accept. An optional placeholder passed as undef
or an empty string is left out.

The return value is a L<URI> instance.

=item routes()

Returns the defined routes as hash references with C<name>, C<path>,
C<methods>, C<payload> and C<route> (the parsed path), grouped by path:
paths in the order each was first defined, and the routes on one path in
the order they were added. Treat them as read-only.

=item as_string()

Returns a report of the defined routes, in order of definition.

=item with($name => $route_path [, %options]

Returns a scope: a router of the same class that adds to the same routes,
with $name, $route_path and the options applied to everything added through
it. For example:

  $r->with(admin => '/admin',        'Admin')
    ->add(users  => '/users',        '#users')
    ->add(trx    => '/transactions', '#transactions')
  ;

  print $r->as_string;

  # prints:
  #   admin_users * /admin/users        { action => "users", controller => "Admin" }
  #   admin_trx   * /admin/transactions { action => "transactions", controller => "Admin" }

The payload contents are merged. The route names are joined by an underscore. The paths are concatenated. Either or both of $name and $route_path may be undefined.

If a nested route specifies a controller beginning with '::', it is concatenated with
the outer controller name. For example:

  $r->with(admin => '/admin', 'Admin')
    ->add(users  => '/users', '::User#show')
  ;

  print $r->as_string;

  # prints:
  #   admin_users * /admin/users { action => "show", controller => "Admin::User" }

A callback is accepted, which allows chaining with() calls:

  $r->with(admin => '/admin',  { controller => 'Admin' }, call => sub {
    $_->add(users => '/users', { action => 'users' });
    $_->add(log   => '/log',   { action => 'log' });
  })->with(dashboard => '/dashboard', { controller => 'Admin::Dashboard' }, call => sub {
    $_->add(view => '/{action}');
  });

  print $r->as_string;

  # prints:
  #   admin_users          * /admin/users
  #   admin_log            * /admin/log
  #   admin_dashboard_view * /admin/dashboard/{action}

Within the callback function, $_ is set to the scope. It is also supplied as a parameter.

A scope answers every router method. match(), url() and the rest act on the
whole set of routes, whichever scope they are called on, and a scope made by
a subclass is an instance of that subclass. Scopes nest: calling with() on a
scope joins the names with an underscore, concatenates the paths and merges
the options.

Methods are the exception to merging. A route or inner scope that names
its own methods takes those alone; one that names none takes its scope's.

=item resource($name, \%payload [, %options])

Adds the routes to list, create, read, update and delete a resource:

  my $r = Router::Right->new->resource('message', 'Message');
  print $r->as_string, "\n";

  #     messages GET       /messages{.format}           index
  #              POST      /messages{.format}           create
  #  message_new GET       /messages/new{.format}       new
  #      message GET       /messages/{id}{.format}      show
  #              PATCH,PUT /messages/{id}{.format}      update
  #              DELETE    /messages/{id}{.format}      delete
  # message_edit GET       /messages/{id}/edit{.format} edit

Each route's payload is the one supplied plus the action shown. Options:

=over 4

=item only => \@actions, except => \@actions

Build just these actions, or all but these.

=item member => \@routes, collection => \@routes

More routes on one member (/messages/{id}/...) or on the collection
(/messages/...). Each is the last part of a route path, with the methods
in front as for add(); a route given no method takes GET only.

  $r->resource(
    'booking', 'Booking',
    collection => [ 'dashboard' ],
    member     => [ 'POST take', 'GET|POST confirm/guest' ],
  );

  # bookings_dashboard    GET      /bookings/dashboard
  # booking_take          POST     /bookings/{id}/take
  # booking_confirm_guest GET,POST /bookings/{id}/confirm/guest

The action is the path with its placeholders dropped and anything that is
not a word character turned into an underscore; the route is named for the
member or collection followed by the action. Collection routes are matched
before /messages/{id}.

=item id => $regex

A pattern the id must match, as in C<{id:\d+}>.

=item format => $regex

A pattern the format must match, as in C<{.format:json|csv}>; an id may
then contain a dot. A false value builds the routes with no format.

=item actions => { $action => $payload }

Payload merged into one action's routes. A string payload works as it does
for add(), so C<< new => '#edit' >> sends /messages/new to the edit action.

  $r->resource('tax', 'Tax', actions => { update => { view => 'edit' } });

=item plural => $name

The collection name, when it is not the plural of $name. A string passed
as C<collection> means the same.

=item name => $name, path => $path, and anything with() accepts

The routes are added in a scope made by with().

=back

A router built with C<< legacy_resources => 1 >> keeps the routes of 1.05
and earlier, which followed Python's Routes: a formatted_ twin of each
named route, new_message and edit_message as names, PUT alone for update,
and the format ahead of /edit (/messages/{id}{.format}/edit).

=back

=head1 ROUTE DEFINITION

A route path is a normal URL path with the addition of placeholder variables. For example:

  $r->add(entries => '/entries/{year}/{month}');

defines a route path containing two placeholders, "year" and "month'. By default, a placeholder matches any string up to the next forward slash.

A placeholder name is a letter or underscore followed by letters, digits or
underscores.

The default match rule may be overridden. For example:

  $r->add(entries => '/entries/{year:\d+}/{month:\d+}');

is the same as above, except it will only match if both the year and month contain only digits.

A pattern may contain braces of its own, as long as they balance:

  $r->add(code => '/codes/{code:[A-Z]{3}}');

A pattern that does not compile is reported when the route is added.

A pattern may not refer to its own groups: no back-references (C<\1>,
C<\g{-1}>, C<\k<name>>), recursion (C<(?1)>, C<(?&name)>, C<(?R)>) or
conditions on a group (C<(?(1)...)>). The patterns of all routes are
matched as one regex, where a group's number counts every route's groups
and a name may be another route's, so such a pattern is refused when the
route is added. Named captures, lookarounds and conditions on them are
fine, and spaces and C<#> in a pattern are literal.

The special {.format} placeholder can be used to allow an optional file extension to be appended. For example:

  $r->add(download => '/dl/{file}{.format}', { controller => 'Download' });
  $r->match('/dl/foo.gz'); # returns { controller => 'Download', file => 'foo', format => 'gz' }
  $r->match('/dl/foo');    # returns { controller => 'Download', file => 'foo' }

  # And to build a URL from it:
  $r->url('download', file => 'foo', format => 'bz2'); # /dl/foo.bz2

The format is what follows the last dot, so /dl/a.b.gz gives the file
"a.b". Give the format a pattern to leave other dots to the placeholder
before it: with C<{file}{.format:gz|bz2}>, /dl/john.smith is all file.

A route is refused when an earlier route with the same path already takes
all of its methods and has a different payload, since it could never
match. With the same payload it is accepted, as a second name for url().

=head1 PERFORMANCE

A route path with no placeholder is found with one hash lookup. The others
are kept in a tree keyed by the whole literal segments they start with
(C</admin/users/{id}> under C<admin>, then C<users>). A request walks the
tree a segment at a time and is tried only against the routes in the node
it reaches and the nodes above it. A match costs about the same with a
hundred routes or a hundred thousand.

Routes that start with a placeholder, such as C</{lang}/about> or a
catch-all C</{path:.*}>, sit at the root, and a node's regex holds its own
routes only. A request is tried against its node first and against the
root only if a root route was defined earlier than the routes it matched,
or it matched none; a catch-all defined last costs nothing until then.
Defined first, the root's routes are tried on every request: three
hundred of them add about six microseconds. A node with more than 32
routes matches without capturing, then takes the values from the matched
route's own regex, because captures in a long alternation slow every
branch tried.

The matchers are compiled on the first match for each request method. A
server that forks its workers can call match() once per method before the
fork, so the workers share them.

A match is the payload hash blessed into Router::Right::Match, which keeps
the route it came from aside in a field hash, so that the hash holds only
the payload and the values while its methods can still name the route.
That costs about a microsecond a match, as much as the matching itself for
a path with no placeholder. A router that needs only the hash can return
a false value from C<_match_class> and get it unblessed:

  package My::Router;
  use parent 'Router::Right';
  sub _match_class { undef }

=head2 Placeholders that can split the same text

A regex tries every way of dividing a path between placeholders before it
gives up. When two or more placeholders in one segment can each take the
text between them, a request that nearly matches costs time in proportion
to its length raised to the number of such placeholders. These routes
take seconds for one crafted request of a few thousand characters:

  /a/{x}{y}{z}         # three ways to split any run of text
  /a/{x}-{y}-{z}       # each may hold a '-' as well
  /a/{x:.+}/{y:.+}/{z:.+}/end

Give each placeholder a pattern that cannot take its neighbour's text
(C</a/{x:[^/-]+}-{y:[^/-]+}>), or one segment of its own. These are safe:
one default placeholder per segment, C<{id}{.format}>, and a final
C<{rest:.*}>, which accepts whatever is left. Nested quantifiers inside a
pattern of your own, such as C<{x:(?:a+)+}>, are a hazard in any regex.


=head1 SEE ALSO

Router::Right is based on Tokuhiro Matsuno's Router::Simple and Router::Boom modules.

This module seeks to implement most features of Python's Routes:
L<https://routes.readthedocs.io/en/latest/index.html>

=cut

# vim: set foldmethod=marker:
