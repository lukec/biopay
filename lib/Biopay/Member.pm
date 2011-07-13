package Biopay::Member;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use DateTime;
use Try::Tiny;

extends 'Biopay::Resource';

has '_id' => (isa => 'Str', is => 'ro', required => 1);
has 'member_id' => (isa => 'Num', is => 'ro', required => 1);
has 'first_name' => (isa => 'Str', is => 'ro', required => 1);
has 'last_name'  => (isa => 'Str', is => 'ro', required => 1);
has 'phone_num'  => (isa => 'Str', is => 'ro', required => 1);
has 'email'  => (isa => 'Str', is => 'ro', required => 1);
has 'start_epoch'  => (isa => 'Num', is => 'ro', required => 1);
has 'dues_paid_until'  => (isa => 'Num', is => 'ro', required => 1);
has 'payment_hash' => (isa => 'Str', is => 'ro');
has 'frozen' => (isa => 'Bool', is => 'rw');

has 'name'              => (is => 'ro', isa => 'Str',      lazy_build => 1);
has 'start_datetime'    => (is => 'ro', isa => 'DateTime', lazy_build => 1);
has 'start_pretty_date' => (is => 'ro', isa => 'Str', lazy_build => 1);

sub view_base { 'members' }
sub empty { 0 }

override 'new_from_couch' => sub {
    my $class = shift;
    my $hash = shift;
    try {
        return $class->new($hash);
    }
    catch {
        Biopay::EmptyMember->new(member_id => $hash->{member_id});
    }
};

method _build_name { join ' ', $self->first_name, $self->last_name }

method _build_start_pretty_date {
    my $t = $self->datetime;
    return $t->ymd;
}

method _build_start_datetime {
    my $dt = DateTime->from_epoch(epoch => $self->start_epoch);
    $dt->set_time_zone('America/Vancouver');
    return $dt;
}

package Biopay::EmptyMember;
use Moose;
use methods;

has 'member_id' => (isa => 'Num', is => 'ro', required => 1);

sub empty { 1 }
sub name { 'No name yet' }
