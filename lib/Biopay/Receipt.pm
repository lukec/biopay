package Biopay::Receipt;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use Dancer ':syntax';
use Biopay::Transaction;

has 'member_id' => (is => 'ro', isa => 'Str',     required => 1);
has 'txn_ids'   => (is => 'ro', isa => 'HashRef', required => 1);
has 'txns'      => (is => 'ro', isa => 'ArrayRef', lazy_build => 1);

with 'Biopay::Roles::HasMember';

method send {
    my $html = render 'email/receipt', {
        member => $self->member,
        txns   => $self->txns,
    };
}


sub _build_txns {
    return [ map { Biopay::Transaction->By_id($_) } @{ $self->txn_ids } ];
}
