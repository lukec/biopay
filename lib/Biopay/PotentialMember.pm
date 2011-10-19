package Biopay::PotentialMember;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Moose;
use Data::UUID;
use Carp qw/croak/;
use Biopay::Util qw/host now_dt beanstream_url/;
use Biopay::Member;
use HTML::Strip;
use methods;

extends 'Biopay::Resource';

has 'first_name' => (isa => 'Str', is => 'ro', required => 1);
has 'last_name'  => (isa => 'Str', is => 'ro', required => 1);
has 'phone_num'  => (isa => 'Str', is => 'ro', required => 1);
has 'address'    => (isa => 'Str', is => 'ro', required => 1);
has 'email'      => (isa => 'Str', is => 'ro', required => 1);
has 'PIN'        => (isa => 'Str', is => 'ro', required => 1);
has 'hash'       => (isa => 'Str', is => 'ro', required => 1);
has 'payment_hash' => (isa => 'Maybe[Str]', is => 'rw');

sub view_base { 'potential_members' }

method name { $self->first_name . ' ' . $self->last_name }
method billing_error {} # ignore
method id { $self->email }

method as_hash {
    return {
        Type => 'potential_member',
        map { $_ => $self->$_ }
            qw/first_name last_name phone_num email PIN hash payment_hash
               address _id _rev/,
    };
}

sub Create {
    my $class = shift;
    my %p = @_;

    my $hs = HTML::Strip->new;
    for my $field (keys %p) {
        $p{$field} = $hs->parse($p{$field});
        $hs->eof;
    }

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
    my $query = "serviceVersion=1.0&merchantId=" . config->{merchant_id}
        . "&trnReturnURL=" . host() . '/new-member/' . $self->hash
        . "&operationType=N";
    return beanstream_url($query);
}

method make_real {
    my $now = now_dt();
    my $new_expiry = $now + DateTime::Duration->new(years => 1);
    my $name = join ' ', $self->first_name, $self->last_name;
    my $member = Biopay::Member->Create( @_,
        name => $name,
        (map { $_ => $self->$_ }
            qw/address phone_num email payment_hash/),
        start_epoch => $now->epoch,
        dues_paid_until => $new_expiry->epoch,
        login_hash => Data::UUID->new->create_str,
    );
    couchdb->remove_doc($self->as_hash)->recv;
    return $member;
}
