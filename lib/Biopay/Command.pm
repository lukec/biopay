package Biopay::Command;
use Moose;
use Dancer::Plugin::CouchDB;
use Dancer ':syntax';
use Time::HiRes qw/time/;
use Try::Tiny;
use Data::Dumper;
use Biopay::Util qw/email_admin/;
use methods;

extends 'Biopay::Resource';

has 'command' => (is => 'ro', isa => 'Str',     required => 1);
has 'args'    => (is => 'ro', isa => 'HashRef', required => 1);

method view_base { 'jobs' }

sub Create {
    my $class = shift;
    my %args  = @_;

    couchdb->save_doc( {
            _id => "command:" . time(),
            Type => 'command',
            command => delete $args{command},
            args => \%args,
        },
    )->recv;
}

sub Run_jobs {
    my $class = shift;
    my $job_cb = shift;
    couchdb->view('jobs/all')->cb(
        sub {
            my $cv = shift;
            my $result = $cv->recv;
            return unless @{ $result->{rows} };
            for my $row (@{ $result->{rows} }) {
                my $job = $class->new($row->{value});
                $job->run($job_cb);
            }
        }
    );
}

method run {
    my $job_cb = shift;
    my $runner = sub {
        try {
            $job_cb->($self, @_);
        }
        catch {
            email_admin("Error running job $self->{command}",
                "Tried to run the job but got error: $_"
                . "\n\n" . Dumper($self)
            );
        }
    };
    if (my $member_id = $self->args->{member_id}) {
        Biopay::Member->By_id($member_id, $runner);
    }
    else {
        $runner->();
    }
}

