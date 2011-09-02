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
use Moose;
use methods;

$| = 1; # auto-flush STDOUT

# Load appdir and templates
Dancer::Config::setting('appdir',realpath("$FindBin::Bin/.."));
Dancer::Config::setting('views',realpath("$FindBin::Bin/../views"));
Dancer::Config::load();

has 'name'      => (is => 'ro', isa => 'Str', required => 1);
has 'main_loop' => (is => 'ro', default => sub { AnyEvent->condvar });
has 'handlers'  => (is => 'rw', isa => 'ArrayRef', default => sub { [] });

has 'couch'  => (is => 'ro', isa => 'Object', lazy_build => 1);
has 'processor'  => (is => 'ro', isa => 'Object', lazy_build => 1);

has 'stream' => (is => 'rw', isa => 'Maybe[Object]');
has '_last_seq' => (is => 'rw', isa => 'Num', default => 0);

method BUILD {
    my $exitsub = sub { $self->main_loop->send };
    push $self->handlers, AnyEvent->signal( signal => 'INT',  cb => $exitsub );
    push $self->handlers, AnyEvent->signal( signal => 'TERM', cb => $exitsub );
}

method run {
    try {
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

method _build_couch {
    my $couch = couchdb();
    die "Could not connect to the couch!" unless $couch;
    return $couch;
}

method _build_processor { Biopay::PaymentProcessor->new }
