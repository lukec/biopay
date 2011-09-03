package Biopay::EmailReceipt;
use Dancer ':syntax';
use Dancer::Plugin::Email;
use Moose;
use Biopay::Transaction;
use methods;

has 'member_id' => (is => 'ro', isa => 'Str',      required => 1);
# Pass in one of these two:
has 'txn_ids'   => (is => 'ro', isa => 'ArrayRef');
has 'txns'      => (is => 'ro', isa => 'ArrayRef', lazy_build => 1);
has 'dues'      => (is => 'ro', isa => 'Num', default => 0);

with 'Biopay::Roles::HasMember';

method send {
    unless ($self->member->email) {
        debug "Member " . $self->member->id. " does not have an email address.";
        return;
    }

    my $total_price = 0;
    my $total_litres = 0;
    my $total_tax = 0;
    my $total_HST = 0;
    for (@{ $self->txns }) {
        $total_price  += $_->price;
        $total_litres += $_->litres;
        $total_tax    += $_->total_taxes;
        $total_HST    += $_->HST;
    }
    my $dues     = sprintf '%0.02f', $self->dues;
    $total_price = sprintf '%0.02f', $total_price + $dues;
    $total_tax   = sprintf '%0.02f', $total_tax;
    $total_HST   = sprintf '%0.02f', $total_HST;

    my $html = template 'email/receipt', {
        member => $self->member,
        txns   => $self->txns,
        ($dues > 0 ? (dues => $dues) : ()),
        total_price  => $total_price,
        total_litres => $total_litres,
        total_taxes  => $total_tax,
        total_HST    => $total_HST,
    }, { layout => 'email' };
    email {
        to => $self->member->email,
        bcc => 'lukecloss@gmail.com',
        from => config->{email_from},
        subject => "Biodiesel Co-op Receipt - \$$total_price",
        type => 'html',
        message => $html,
    };
}


method _build_txns {
    die "txn_ids are required if no transactions are given!"
        unless $self->txn_ids;
    return [ map { Biopay::Transaction->By_id($_) } @{ $self->txn_ids } ];
}
