package Biopay::Receipt;
use Moose;
use methods;
use Dancer::Plugin::Email;
use Dancer ':syntax';
use Biopay::Transaction;
use Dancer::Request;
use Dancer::SharedData;

has 'member_id' => (is => 'ro', isa => 'Str',      required => 1);
has 'txn_ids'   => (is => 'ro', isa => 'ArrayRef', required => 1);
has 'txns'      => (is => 'ro', isa => 'ArrayRef', lazy_build => 1);

with 'Biopay::Roles::HasMember';

method send {
    my $total_price = 0;
    my $total_litres = 0;
    for (@{ $self->txns }) {
        $total_price += $_->price;
        $total_litres += $_->litres;
    }
    $total_price = sprintf '%0.02f', $total_price;

    # Hack: Dancer needs a request object, so lets fake one.
    Dancer::SharedData->request(Dancer::Request->new_for_request('GET', '/'))
        unless Dancer::SharedData->request;

    my $html = template 'email/receipt', {
        member => $self->member,
        txns   => $self->txns,
        total_price  => $total_price,
        total_litres => $total_litres,
    }, { layout => 'email' };
    email {
        to => $self->member->email,
        bcc => 'lukecloss@gmail.com',
        from => config->{email_from},
        subject => "Biodiesel Receipt - \$$total_price",
        type => 'html',
        message => $html,
    };
    debug "Just sent email receipt to " . $self->member->email;
}


method _build_txns {
    return [ map { Biopay::Transaction->By_id($_) } @{ $self->txn_ids } ];
}
