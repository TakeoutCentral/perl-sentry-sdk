package Sentry::Integration::DBI;
use Mojo::Base 'Sentry::Integration::Base', -signatures;

use Mojo::Util qw(dumper monkey_patch);

has breadcrumbs => 1;
has tracing     => 1;

# DBI is special. Classes are generated on-the-fly.
sub around ($package, $method, $cb) {
  ## no critic (TestingAndDebugging::ProhibitNoStrict, TestingAndDebugging::ProhibitNoWarnings, TestingAndDebugging::ProhibitProlongedStrictureOverride)
  no strict 'refs';
  no warnings 'redefine';

  my $symbol = join('::', $package, $method);

  my $orig = \&{$symbol};
  *{$symbol} = sub { $cb->($orig, @_) };

  return;
}

sub setup_once ($self, $add_global_event_processor, $get_current_hub) {
  return if (!$self->breadcrumbs && !$self->tracing);

  my $do_around = sub {
    my ($method, @args) = @_;
    around(
      'DBI::db',
      $method => sub ($orig, $dbh, $statement, @args) {
        my $hub = $get_current_hub->();

        my $span;

        if ($self->tracing && (my $parent_span = $hub->get_scope()->get_span)) {
          $span = $parent_span->start_child({
            op          => 'db.sql.query',
            description => $statement,
            data        => { args => [@args], },
          });
        }

        my $value = $orig->($dbh, $statement, @args);

        if (defined $span && $self->tracing) {
          $span->finish();
        }

        return $value;
      }
    );
  };

  my @symbols = (
    'do',                 'selectrow_array',
    'selectrow_arrayref', 'selectrow_hashref',
    'selectall_arrayref', 'selectall_hashref',
    'selectcol_arrayref',
  );

  for (@symbols) {
    $do_around->($_);
  }

  around(
    'DBI::st',
    execute => sub ($orig, $sth, @args) {
      my $statement = $sth->{Statement};

      my $hub = $get_current_hub->();

      my $span;

      if ($self->tracing && (my $parent_span = $hub->get_scope()->get_span)) {
        $span = $parent_span->start_child({
          op          => 'db.sql.query',
          description => $statement,
          data        => { args => [@args], },
        });
      }

      my $value = $orig->($sth, @args);

      if (defined $span && $self->tracing) {
        $span->finish();
      }

      return $value;
    }
  );
}

1;
