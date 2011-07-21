package Biopay::Receipt;
use Moose;
use methods;
use Dancer::Plugin::Email;
use Dancer ':syntax';
use Biopay::Transaction;

has 'member_id' => (is => 'ro', isa => 'Str',      required => 1);
has 'txn_ids'   => (is => 'ro', isa => 'ArrayRef', required => 1);
has 'txns'      => (is => 'ro', isa => 'ArrayRef', lazy_build => 1);

with 'Biopay::Roles::HasMember';

method send {
    my $total_price = 0;
    my $total_litres = 0;
    my $total_tax = 0;
    for (@{ $self->txns }) {
        $total_price += $_->price;
        $total_litres += $_->litres;
        $total_tax += $_->taxes;
    }
    $total_price = sprintf '%0.02f', $total_price;
    $total_tax   = sprintf '%0.02f', $total_tax;

    my $html = template 'email/receipt', {
        member => $self->member,
        txns   => $self->txns,
        total_price  => $total_price,
        total_litres => $total_litres,
        total_tax    => $total_tax,
    }, { layout => 'email' };
    email {
        to => $self->member->email,
        bcc => 'lukecloss@gmail.com',
        from => config->{email_from},
        subject => "Biodiesel Co-op Receipt - \$$total_price",
        type => 'html',
        message => $html,
    };
    debug "Just sent email receipt to " . $self->member->email;
}


method _build_txns {
    return [ map { Biopay::Transaction->By_id($_) } @{ $self->txn_ids } ];
}
