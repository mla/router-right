requires 'perl', '5.010';

requires 'Data::Dump';
requires 'Lingua::EN::Inflect';
requires 'List::MoreUtils';
requires 'List::Util', '1.33';
requires 'Tie::IxHash';
requires 'URI';

on test => sub {
  requires 'Test::More';
  requires 'Test::Spec';
};

on develop => sub {
  requires 'Devel::Cover';
};
