package Biopay::Receipt;
use strict;
use warnings;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Moose;
use Try::Tiny;
use Biopay::Util qw/now_dt email_admin/;
use JSON qw/encode_json/;
use methods;

extends 'Biopay::Resource';

has 'member_id' => (isa => 'Num', is => 'ro', required => 1);
has 'order_num' => (isa => 'Str', is => 'ro', required => 1);
has 'amount'    => (isa => 'Num', is => 'ro', required => 1);
has 'items'     => (isa => 'ArrayRef[HashRef]', is => 'ro', required => 1);
has 'at'        => (isa => 'Num', is => 'ro', required => 1);

has 'txns'      => (isa => 'ArrayRef', is => 'ro', lazy_build => 1);

sub By_date { shift->All_for_view('/by_date', @_) }
sub view_base { 'receipts' }

sub Create {
    my $class = shift;
    my %p = @_;
    my $success_cb = delete $p{success_cb};
    my $error_cb = delete $p{error_cb};

    die "order_num is mandatory!" unless $p{order_num};
    die "member_id is mandatory!" unless $p{member_id};
    die "items is mandatory!"     unless $p{items};
    $p{at} ||= time();

    my $key = "receipt:$p{order_num}-$p{at}";
    my $new_doc = { _id => $key, Type => 'receipt', %p };

    my $cv = couchdb->save_doc($new_doc);
    $cv->cb( sub {
            my $cv2 = shift;
            try { 
                $cv2->recv;
                print " ($key) ";
            }
            catch {
                email_admin("Failed to save '$key'",
                    "I tried to save a receipt to the database but failed: $_"
                    . "\n\nDocument was:\n" . encode_json($new_doc));
            }
        },
    );
}

sub All_for_member {
    my ($class, $key, @args) = @_;
    my $opts = { startkey => "$key", endkey => "$key" };
    $class->All_for_view('/by_member', $opts);
}

method txn_ids {
    my @txns;
    for my $item (@{ $self->items }) {
        next unless $item->{type} eq 'txn';
        push @txns, $item->{desc};
    }
    return \@txns;
}

method dues {
    for my $item (@{ $self->items }) {
        next if $item->{type} eq 'txn';
        return $item->{amount};
    }
    return 0;
}

method _build_txns {
    my @txns;
    for my $item (@{ $self->items }) {
        next unless $item->{type} eq 'txn';
        push @txns, Biopay::Transaction->By_id($item->{desc});
    }
    return \@txns;
}

method total_taxes {
    my $total_taxes = 0;
    for my $txn (@{$self->txns}) {
        $total_taxes += $txn->total_taxes;
    }
    return sprintf('%0.02f', $total_taxes);
}

method total_litres {
    my $total_litres = 0;
    for my $txn (@{$self->txns}) {
        $total_litres += $txn->litres;
    }
    return $total_litres;
}

method total_co2_reduction {
    my $total_co2 = 0;
    for my $txn (@{$self->txns}) {
        $total_co2 += $txn->co2_reduction;
    }
    return $total_co2;
}
