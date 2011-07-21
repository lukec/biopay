package Biopay::Command;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use Dancer ':syntax';

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
                $job_cb->($job);
            }
            print "Done checking jobs...\n";
        }
    );
}

