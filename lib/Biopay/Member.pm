package Biopay::Member;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use DateTime;

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

sub By_id {
    my $class = shift;
    my $member_id = shift;
    my $results
        = couchdb->view('members/by_id', { key => qq($member_id) })->recv;
    return Biopay::EmptyMember->new(member_id => $member_id)
        unless $results->{total_rows} > 0;
    return $class->new( $results->{rows}[0]{value} );
}

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

sub name { 'No name yet' }
