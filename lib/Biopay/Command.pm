package Biopay::Command;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use Dancer ':syntax';
use Biopay::Member;

extends 'Biopay::Resource';

has 'command' => (is => 'ro', isa => 'Str',       required => 1);
has 'args'    => (is => 'ro', isa => 'HashRef[]', required => 1);
has 'timestamp' => (is => 'ro', isa => 'Int',     required => 1);

has 'member'  => (is => 'ro', isa => 'Maybe[Object]', lazy_build => 1);

sub Create {
    my $class = shift;
    my %args  = @_;

    couchdb->save_doc( {
            Type => 'command',
            timestamp => time(),
            %args,
        },
    )->recv;
}

sub NextJob {
    my $class = shift;
    my $result = $couch->view('jobs/all')->recv;
    return undef unless @{ $result->{rows} };
    return $class->new( $result->{rows}[0]{value} );
}

method _build_member {
    my $id = $self->args->{member_id};
    return undef unless $id;
    return Biopay::Member->By_id($id);
}
