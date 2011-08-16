package Biopay::PotentialMember;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Moose;
use Data::UUID;
use Carp qw/croak/;
use Biopay::Util qw/host/;
use methods;

extends 'Biopay::Resource';

has 'first_name' => (isa => 'Str', is => 'ro', required => 1);
has 'last_name'  => (isa => 'Str', is => 'ro', required => 1);
has 'phone_num'  => (isa => 'Str', is => 'ro', required => 1);
has 'email'      => (isa => 'Str', is => 'ro', required => 1);
has 'PIN'        => (isa => 'Str', is => 'ro', required => 1);
has 'hash'       => (isa => 'Str', is => 'ro', required => 1);
has 'payment_hash' => (isa => 'Maybe[Str]', is => 'ro');

sub view_base { 'potential_members' }

method name { $self->first_name . ' ' . $self->last_name }
method billing_error {} # ignore
method id { $self->email }

method as_hash {
    return {
        Type => 'potential_member',
        map { $_ => $self->$_ }
            qw/first_name last_name phone_num email PIN hash payment_hash/,
    };
}

sub Create {
    my $class = shift;
    my %p = @_;

    my $key = "potential_member:$p{email}";
    my $new_doc = {
        _id => $key,
        Type => 'potential_member',
        hash => Data::UUID->new->create_str,
        %p,
    };

    my $cv = couchdb->save_doc($new_doc);
    try {
        $cv->recv;
        return $class->new_from_hash($new_doc);
    }
    catch {
        croak "Error creating $key: $_";
    }
}

sub By_email { shift->By_view('by_email', @_) }
sub By_hash  { shift->By_view('by_hash', @_) }

method payment_setup_url {
    return "https://www.beanstream.com/scripts/PaymentProfile/"
        . "webform.asp?serviceVersion=1.0&merchantId=" 
        . config->{merchant_id}
        . "&trnReturnURL=" . host() . '/new-member/' . $self->hash
        . "&operationType=N";
}
