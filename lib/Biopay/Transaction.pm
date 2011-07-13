package Biopay::Transaction;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use DateTime;
use Biopay::Member;

extends 'Biopay::Resource';

has '_id' => (isa => 'Str', is => 'ro', required => 1);
has '_rev' => (isa => 'Str', is => 'ro', required => 1);
has 'epoch_time' => (isa => 'Num', is => 'ro', required => 1);
has 'date' => (isa => 'Str', is => 'ro', required => 1);
has 'price_per_litre' => (isa => 'Num', is => 'ro', required => 1);
has 'txn_id' => (isa => 'Num', is => 'ro', required => 1);
has 'paid' => (isa => 'Bool', is => 'rw', required => 1);
has 'Type' => (isa => 'Str', is => 'ro', required => 1);
has 'litres' => (isa => 'Num', is => 'ro', required => 1);
has 'member_id' => (isa => 'Num', is => 'ro', required => 1);
has 'price' => (isa => 'Num', is => 'ro', required => 1);
has 'pump' => (isa => 'Str', is => 'ro', required => 1);

has 'member'      => (is => 'ro', isa => 'Object',   lazy_build => 1);
has 'datetime'    => (is => 'ro', isa => 'DateTime', lazy_build => 1);
has 'pretty_date' => (is => 'ro', isa => 'Str', lazy_build => 1);

sub view_base { 'txns' }

sub All_unpaid { shift->All_for_view('/unpaid') }

method save {
    couchdb->save_doc($self->as_hash)->recv;
}

method as_hash {
    my $hash = {};
    for my $key (qw/_id _rev epoch_time date price_per_litre txn_id paid Type
                    litres member_id price pump/) {
        $hash->{$key} = $self->$key;
    }
    return $hash;
}

method _build_pretty_date {
    my $t = $self->datetime;
    return $t->ymd . ' ' . sprintf("%02d:%02d", $t->hour, $t->minute);
}

method _build_datetime {
    my $dt = DateTime->from_epoch(epoch => $self->epoch_time);
    $dt->set_time_zone('America/Vancouver');
    return $dt;
}

method _build_member { Biopay::Member->By_id($self->member_id) }
