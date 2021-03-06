package Test::AnyEvent::plackup;
use strict;
use warnings;
our $VERSION = '1.0';
use File::Temp;
use AnyEvent;
use AnyEvent::Util;
use Net::TCP::FindPort;

sub new {
    return bless {options => {}}, $_[0];
}

# ------ Command construction ------

sub set_option {
    $_[0]->{options}->{$_[1]} = [$_[2]];
}

sub add_option {
    push @{$_[0]->{options}->{$_[1]} ||= []}, $_[2];
}

sub plackup {
    if (@_ > 1) {
        $_[0]->{plackup} = $_[1];
    }
    return defined $_[0]->{plackup} ? $_[0]->{plackup} :  'plackup';
}

sub app {
    if (@_ > 1) {
        $_[0]->set_option('--app' => $_[1]);
    }
    return $_[0]->{options}->{'--app'}->[0];
}

sub set_app_code {
    my ($self, $code) = @_;
    my $psgi_file_name = File::Temp->new(SUFFIX => '.psgi')->filename;
    $self->app($psgi_file_name);
    open my $psgi_file, '>:encoding(utf-8)', $psgi_file_name
        or die "$0: $psgi_file_name: $!";
    print $psgi_file $code;
    close $psgi_file;
    $self->{temp_psgi_file_name} = $psgi_file_name;
}

sub server {
    if (@_ > 1) {
        $_[0]->set_option('--server' => $_[1]);
    }
    return $_[0]->{options}->{'--server'}->[0];
}

sub port {
    if (@_ > 1) {
        $_[0]->set_option('--port' => $_[1]);
    }
    return defined $_[0]->{options}->{'--port'}->[0]
        ? $_[0]->{options}->{'--port'}->[0]
        : ($_[0]->{options}->{'--port'}->[0] = Net::TCP::FindPort->find_listenable_port);
}

sub get_command {
    my $self = shift;
    my @cmd = ($self->plackup);
    $self->port;
    for my $option (sort { $a cmp $b } keys %{$self->{options}}) {
        my $values = $self->{options}->{$option} or next;
        for my $value (@$values) {
            push @cmd, $option => $value;
        }
    }
    return \@cmd;
}

sub set_env {
    $_[0]->{envs}->{$_[1]} = $_[2];
}

sub envs {
    return (%ENV, %{$_[0]->{envs} or {}});
}

# ------ Server ------

sub onstdout {
    if (@_ > 1) {
        $_[0]->{onstdout} = $_[1];
    }
    return $_[0]->{onstdout};
}

sub onstderr {
    if (@_ > 1) {
        $_[0]->{onstderr} = $_[1];
    }
    return $_[0]->{onstderr};
}

sub pid {
    return $_[0]->{pid};
}

sub start_server {
    my $self = shift;

    local %ENV = ($self->envs);
    
    my $command = $self->get_command;
    push @$command, '--loader' => '+Test::AnyEvent::plackup::Loader';
    my $pid;

    my $cv = run_cmd
        $command,
        '>' => $self->onstdout || *STDOUT,
        '2>' => $self->onstderr || *STDERR,
        '$$' => \$pid,
    ;
    $self->{pid} = $pid;

    my $cv_start = AE::cv;
    my $cv_end = AE::cv;

    my $signal;
    my $w; $w = AnyEvent->signal(
        signal => 'USR1',
        cb => sub {
            $signal++;
            undef $w;
        },
    );

    my $port = $self->port;
    my $time = 0;
    my $timer; $timer = AE::timer 0, 0.6, sub {
        my $netstat;
        $time += 0.6;
        if ($time > 10) {
            undef $timer;
            warn "plackup timeout!\n";
            $cv_start->send(1);
        }
        if ($signal) {
            $cv_start->send(0);
            undef $timer;
        }
    };

    $cv->cb(sub {
        undef $timer;
        $cv_end->send($_[0]->recv);
    });

    return ($cv_start, $cv_end);
}

sub stop_server {
    my $self = shift;
    if ($self->{pid}) {
        kill 15, $self->{pid}; # SIGTERM
        delete $self->{pid} if kill 0, $self->{pid};
    }
}

sub DESTROY {
    {
        local $@;
        eval { die };
        if ($@ =~ /during global destruction/) {
            warn "Detected (possibly) memory leak";
        }
    }
    $_[0]->stop_server if $_[0]->{pid};
    if ($_[0]->{temp_psgi_file_name}) {
        unlink $_[0]->{temp_psgi_file_name};
    }
}

1;
