package Biopay::Daemon;
use 5.14.1;
use Dancer qw/:syntax/;
use FindBin;
use Cwd qw/realpath/;
use lib "$FindBin::Bin/../lib";
use Try::Tiny;
use AnyEvent;
use Dancer::Plugin::CouchDB;
use AnyEvent::CouchDB::Stream;
use Biopay::PaymentProcessor;
use Biopay::Util qw/email_admin/;
use Biopay::Command;
use Biopay::Prices;
use Moose;
use Data::Dumper;
use methods;

$| = 1; # auto-flush STDOUT

# Load appdir and templates
Dancer::Config::setting('appdir',realpath("$FindBin::Bin/.."));
Dancer::Config::setting('views',realpath("$FindBin::Bin/../views"));
Dancer::Config::load();

has 'name'      => (is => 'ro', isa => 'Str', required => 1);
has 'main_loop' => (is => 'ro', default => sub { AnyEvent->condvar });
has 'CVs' => (is => 'rw', isa => 'ArrayRef', default => sub { [] });
has 'job_handlers' => (is => 'rw', isa => 'HashRef',  default => sub { {} });
has 'update_handlers' => (is => 'ro', isa => 'HashRef', default => sub { {} });
has 'prices' => (is => 'ro', isa => 'Object', default => sub {
        my $p = Biopay::Prices->new; $p->_doc; $p });
has 'want_stream' => (is => 'ro', isa => 'Bool', default => sub { 0 });

has 'couch'  => (is => 'ro', isa => 'Object', lazy_build => 1);
has 'processor'  => (is => 'ro', isa => 'Object', lazy_build => 1);

has 'stream' => (is => 'rw', isa => 'Maybe[Object]');
has '_last_seq' => (is => 'rw', isa => 'Num', default => 0);

method BUILD {
    my $exitsub = sub { $self->main_loop->send };
    push $self->CVs, AnyEvent->signal(signal => 'INT', cb => $exitsub);
    push $self->CVs, AnyEvent->signal(signal => 'TERM', cb => $exitsub);

    $self->setup_couch_stream(
        on_change => sub {
            my $change = shift;
            given ($change->{id}) {
                when ('prices') { $self->prices->async_update }
                default {
                    my $handlers = $self->update_handlers;
                    for my $key (keys %$handlers) {
                        next unless $change->{id} =~ $key;
                        print " ($change->{id}) ";
                        $handlers->{$key}->($change);
                    }
                }
            }
        },
    ) if $self->want_stream;
}

method run {
    try {
        print "\nStarting @{[$self->name]} at " . localtime . "\n";
        my $t;
        if (%{ $self->job_handlers }) {
            $t = AnyEvent->timer(
                after => 0.1, interval => 3600,
                cb => sub {
                    print 'J';
                    Biopay::Command->Run_jobs( sub {
                        my $job = shift;
                        my $cb = $self->job_handler($job->command);
                        $job->run($cb) if $cb;
                    });
                }
            );
        }
        $self->main_loop->recv;
    }
    catch {
        (my $first_line = $_) =~ s/\n.+//s;
        warn $self->name . " Error: $_";
        email_admin(
            "Un-caught cardlock error: $first_line",
            "Not sure what happened: $_",
        );
    };
    finally {
        print $self->name, " shutting down.\n";
    };
}

method setup_couch_stream {
    my %p; %p = (
        on_change => sub {},
        on_error  => sub {
            my $error = shift;
            unless ($error eq 'timeout' or $error eq 'Broken pipe') {
                warn "Couch stream error: $error";
            }
            $self->setup_couch_stream(%p);
        },
        @_,
    );
    my $orig_on_change = delete $p{on_change};
    my $on_change = sub {
        my $change = shift;
        $self->_last_seq($change->{seq});
        try {
            if ($change->{id} =~ m/^command:/) {
                # Always load commands, to see if we should do them.
                my $cv; $cv = $self->couch->open_doc($change->{id}, {
                    success => sub {
                        my $doc = shift;
                        try {
                            my $job = Biopay::Command->new($doc);
                            my $cb = $self->job_handler($job->command);
                            $job->run($cb) if $cb;
                            print 'j' unless $cb;
                        }
                        catch {
                            email_admin(
                                "Error running command: $change->{id}",
                                "Error: $_\n\n" . Dumper($doc)
                            );
                        }
                        finally {
                            undef $cv;
                        }
                    },
                    error => sub { undef $cv },
                });
                return;
            }
            $orig_on_change->($change);
        }
        catch {
            debug "Error processing a change from the couch: $_";
        }
    };

    $self->_last_seq($self->couch->info->recv->{update_seq})
        unless $self->_last_seq;

    (my $couch_uri = couch_uri) =~ s/(.+)\/([^\/]+)$/$1/;
    my $couch_name = $2 || die "Couldn't load Couch name from '$couch_uri'";

    print 'S';
    my $couch_listener = AnyEvent::CouchDB::Stream->new(
        url => $couch_uri,
        database => $couch_name,
        since => $self->_last_seq,
        on_change => $on_change,
        %p,
    );
    $self->stream($couch_listener);
}

method job_handler {
    my $type = shift;
    my $cb = $self->job_handlers->{$type} || return;
    return sub {
        my $job = shift;
        print " (Running: $job->{command}) ";
        $cb->($job, @_);
        $self->remove_job($job);
    };
}

method remove_job {
    my $job = shift;
    my $cv;
    $cv = $self->couch->remove_doc($job,  {
        success => sub {
            print " (Removed $job->{_id}) ";
        },
        error => sub {
            my $err = shift;
            email_admin("Error removing a $job->{command} job",
                "Failed to remove $job->{_id}\n\n$err");
            $cv = undef;
        },
    });
}

method _build_couch {
    my $couch = couchdb();
    die "Could not connect to the couch!" unless $couch;
    return $couch;
}

method _build_processor { Biopay::PaymentProcessor->new }
