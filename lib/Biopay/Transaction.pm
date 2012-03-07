package Biopay::Transaction;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use DateTime;
use Biopay::Member;

extends 'Biopay::Resource';

has 'epoch_time'      => (isa => 'Num',  is => 'ro', required => 1);
has 'date'            => (isa => 'Str',  is => 'ro', required => 1);
has 'price_per_litre' => (isa => 'Num',  is => 'ro', required => 1);
has 'txn_id'          => (isa => 'Str',  is => 'ro', required => 1);
has 'cardlock_txn_id' => (isa => 'Str',  is => 'ro');
has 'litres'          => (isa => 'Num',  is => 'ro', required => 1);
has 'member_id'       => (isa => 'Num',  is => 'ro', required => 1);
has 'price'           => (isa => 'Num',  is => 'ro', required => 1);
has 'pump'            => (isa => 'Str',  is => 'ro', required => 1);
has 'paid'            => (isa => 'Bool', is => 'rw', default => 0);
has 'paid_date'       => (isa => 'Num',  is => 'rw');
has 'payment_notes'   => (isa => 'Maybe[Str]',  is => 'rw');

with 'Biopay::Roles::HasMember';

has 'HST'         => (is => 'ro', isa => 'Num',    lazy_build => 1);
has 'total_taxes' => (is => 'ro', isa => 'Num',    lazy_build => 1);
has 'tax_rate'    => (is => 'ro', isa => 'Num',    lazy_build => 1);
has 'datetime'    => (is => 'ro', isa => 'Object', lazy_build => 1);
has 'pretty_date' => (is => 'ro', isa => 'Str',    lazy_build => 1);
has 'pretty_paid_date' => (is => 'ro', isa => 'Str',    lazy_build => 1);

sub view_base {'txns'}
method id { $self->txn_id }
method age_in_seconds { time() - $self->epoch_time }

sub All_unpaid { shift->All_for_view('/unpaid',  @_) }
sub By_date    { shift->All_for_view('/by_date', @_) }

method All_most_recent {
    my %p = @_;
    my $nsk = $p{next_startkey};
    my $page_size = 200;
    my $txns = $self->All_for_view('/recent', 
        {
            ($nsk ? (startkey => $nsk) : ()),
            limit => $page_size + 1,
        }
    );
    if (@$txns == $page_size + 1) {
        $nsk = pop(@$txns)->epoch_time;
    }
    return {
        next_startkey => $nsk,
        txns => $txns,
    };
}

sub All_for_member {
    my ($class, $key, @args) = @_;
    my $opts = {
        startkey => [$key],
        endkey => [$key, {}],
    };
    $class->All_for_view('/by_member', $opts );
}

after 'paid' => sub {
    my $self = shift;
    return unless $self->{paid} and not $self->paid_date;
    my $now = time;
    $self->paid_date($now);
};

method as_hash {
    my $hash = {};
    for my $key (qw/_id _rev epoch_time date price_per_litre txn_id paid Type
                    litres member_id price pump paid_date payment_notes/) {
        $hash->{$key} = $self->$key;
    }
    return $hash;
}

method _build_pretty_date {
    my $t = $self->datetime;
    return $t->month_name . ' ' . $t->day . ', ' . $t->year
        . ' at ' . sprintf("%2d:%02d", $t->hour_12, $t->minute) . ' ' . $t->am_or_pm;
}

method _build_pretty_paid_date {
    my $t = DateTime->from_epoch(epoch => $self->paid_date);
    $t->set_time_zone('America/Vancouver');
    return $t->month_name . ' ' . $t->day . ', ' . $t->year
        . ' at ' . sprintf("%02d:%02d", $t->hour_12, $t->minute) . ' ' . $t->am_or_pm;
}

method _build_datetime {
    my $dt = DateTime->from_epoch(epoch => $self->epoch_time);
    $dt->set_time_zone('America/Vancouver');
    return $dt;
}

method _build_HST {
    # Calculate the HST from the total
    sprintf '%0.02f', $self->price - ($self->price / 1.05);
}

method _build_total_taxes {
    sprintf '%0.02f', $self->HST
        + $self->litres * 0.24   # Road Fuels Tax
        + $self->litres * 0.0639 # Carbon Tax
}

method _build_tax_rate {
    return 0 if $self->price == 0;
    sprintf '%0.01f', $self->total_taxes / $self->price * 100;
}
