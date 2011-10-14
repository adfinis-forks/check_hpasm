package HP::Proliant::Component::EventSubsystem;
our @ISA = qw(HP::Proliant::Component);

use strict;
use constant { OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 };

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    runtime => $params{runtime},
    rawdata => $params{rawdata},
    method => $params{method},
    condition => $params{condition},
    status => $params{status},
    events => [],
    blacklisted => 0,
    info => undef,
    extendedinfo => undef,
  };
  bless $self, $class;
  if ($self->{method} eq 'snmp') {
    return HP::Proliant::Component::EventSubsystem::SNMP->new(%params);
  } elsif ($self->{method} eq 'cli') {
    return HP::Proliant::Component::EventSubsystem::CLI->new(%params);
  } else {
    die "unknown method";
  }
  return $self;
}

sub check {
  my $self = shift;
  my $errorfound = 0;
  $self->add_info('checking events');
  if (scalar (@{$self->{events}}) == 0) {
    #$self->overall_check(); 
    $self->add_info('no events found');
  } else {
    foreach (sort { $a->{cpqHeEventLogEntryNumber} <=> $b->{cpqHeEventLogEntryNumber}}
        @{$self->{events}}) {
      $_->check($self->{warningtime}, $self->{criticaltime});
    }
  }
}

sub dump {
  my $self = shift;
  foreach (@{$self->{events}}) {
    $_->dump();
  }
}


package HP::Proliant::Component::EventSubsystem::Event;
our @ISA = qw(HP::Proliant::Component::EventSubsystem);

use strict;
use constant { OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 };

{
  our $interesting_events = {
    # POST Error: 201-Memory Error Multi-bit error occurred during memory initialization, Board 1, Bank B. Bank containing DIMM(s) has been disabled..
    # POST Error: 201-Memory Error Single-bit error occured during memory initialization, Board 1, DIMM 1. Bank containing DIMM(s) has been disabled..
    # POST Error: 207-Memory initialization error on Memory Board 5 DIMM 7. The operating system may not have access to all of the memory installed in the system..
    # POST Error: 207-Invalid Memory Configuration-Mismatched DIMMs within DIMM Bank Memory in Bank A Not Utilized..  
    'POST Messages' => [
      '201-Memory', '207-Memory'
    ],
  };
}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    runtime => $params{runtime},
    cpqHeEventLogEntryNumber => $params{cpqHeEventLogEntryNumber},
    cpqHeEventLogEntrySeverity => lc $params{cpqHeEventLogEntrySeverity},
    cpqHeEventLogEntryClass => $params{cpqHeEventLogEntryClass},
    cpqHeEventLogEntryCount => $params{cpqHeEventLogEntryCount} || 1,
    cpqHeEventLogInitialTime => $params{cpqHeEventLogInitialTime},
    cpqHeEventLogUpdateTime => $params{cpqHeEventLogUpdateTime},
    cpqHeEventLogErrorDesc => $params{cpqHeEventLogErrorDesc},
    blacklisted => 0,
    info => undef,
    extendedinfo => undef,
  };
  if (! $self->{cpqHeEventLogInitialTime}) {
    $self->{cpqHeEventLogInitialTime} = $self->{cpqHeEventLogUpdateTime};
  }
  # 
  #
  #++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
  #                      |warn                 |crit                          |now
  #
  #<----- ignore -------><----- warning ------><---------- critical --------->
  #
  # If we have --eventrange <warnlookback>/<critlookback>
  #  Very young events are shown as critical
  #  If the event gets older, it is shown as warning
  #  At some time, the event is no longer shown
  # Without --eventrange the event is shown as critical until you manually repair it
  if ($params{runtime}->{options}->{eventrange}) {
    my ($warningrange, $criticalrange) = split(/\//, $params{runtime}->{options}->{eventrange});
    if (! $criticalrange) {
      $criticalrange = $warningrange;
    }
    if ($criticalrange =~ /^(\d+)[s]*$/) {
      $criticalrange = $1;
    } elsif ($criticalrange =~ /^(\d+)m$/) {
      $criticalrange = $1 * 60;
    } elsif ($criticalrange =~ /^(\d+)h$/) {
      $criticalrange = $1 * 3600;
    } elsif ($criticalrange =~ /^(\d+)d$/) {
      $criticalrange = $1 * 3600 * 24;
    } else {
      die "range has to be <number>[smhd]";
    }
    if ($warningrange =~ /^(\d+)[s]*$/) {
      $warningrange = $1;
    } elsif ($warningrange =~ /^(\d+)m$/) {
      $warningrange = $1 * 60;
    } elsif ($warningrange =~ /^(\d+)h$/) {
      $warningrange = $1 * 3600;
    } elsif ($warningrange =~ /^(\d+)d$/) {
      $warningrange = $1 * 3600 * 24;
    } else {
      die "range has to be <number>[smhd]";
    }
    $self->{warningtime} = time - $warningrange;
    $self->{criticaltime} = time - $criticalrange;
  } else {
    $self->{warningtime} = 0;
    $self->{criticaltime} = 0;
  }
  bless $self, $class;
  return $self;
}

sub check {
  my $self = shift;
  $self->blacklist('evt', $self->{cpqHeEventLogEntryNumber});
  # only check severity "critical" and "caution"
  # optional: only check interesting events
  # POST events only if they date maximum from reboot-5min
  # younger than critical? -> critical
  # 
  my $uptime = do { local (@ARGV, $/) = "/proc/uptime"; my $x = <>; close ARGV; $x };
  # also watch 10 minutes of booting before the operating system starts ticking
  my $boottime = time - int((split(/\s+/, $uptime))[0]) - 600;
  $self->add_info(sprintf "Event: %d Added: %s Class: (%s) %s %s",
      $self->{cpqHeEventLogEntryNumber},
      $self->{cpqHeEventLogUpdateTime},
      $self->{cpqHeEventLogEntryClass},
      $self->{cpqHeEventLogEntrySeverity},
      $self->{cpqHeEventLogErrorDesc});
  if ($self->{cpqHeEventLogEntrySeverity} eq "caution" ||
      $self->{cpqHeEventLogEntrySeverity} eq "critical") {
    if ($self->{cpqHeEventLogUpdateTime} >= $boottime) {
      foreach my $class (keys %{$HP::Proliant::Component::EventSubsystem::Event::interesting_events}) {
        foreach my $pattern (@{$HP::Proliant::Component::EventSubsystem::Event::interesting_events->{$class}}) {
          if ($self->{cpqHeEventLogErrorDesc} =~ /$pattern/) {
            if ($self->{cpqHeEventLogUpdateTime} < $self->{warningtime}) {
              # you didn't care for this problem too long.
              # don't say i didn't warn you.
              if (0) {
                # auto-ack?
              } 
            } elsif ($self->{cpqHeEventLogUpdateTime} < $self->{criticaltime}) {
              $self->add_message(WARNING, $self->{info});
            } else {
              $self->add_message(CRITICAL, $self->{info});
            }
          }
        }
      }
    }
  } else {
    # info, repair...
  }
}

sub dump { 
  my $self = shift;
  printf "[EVENT_%s]\n", $self->{cpqHeEventLogEntryNumber};
  foreach (qw(cpqHeEventLogEntryNumber cpqHeEventLogEntrySeverity
      cpqHeEventLogEntryCount cpqHeEventLogInitialTime
      cpqHeEventLogUpdateTime cpqHeEventLogErrorDesc)) {
    if ($_ =~ /.*Time$/) {
      printf "%s: %s\n", $_, scalar localtime $self->{$_};
    } else {
      printf "%s: %s\n", $_, $self->{$_};
    }
  }
  printf "info: %s\n\n", $self->{info};
}

1;

