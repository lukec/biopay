package Biopay::Member;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Dancer::Plugin::Email;
use Moose;
use DateTime;
use Try::Tiny;
use Biopay::Command;
use methods;

extends 'Biopay::Resource';

has 'member_id' => (isa => 'Num', is => 'ro', required => 1);
has 'first_name' => (isa => 'Maybe[Str]', is => 'rw');
has 'last_name'  => (isa => 'Maybe[Str]', is => 'rw');
has 'phone_num'  => (isa => 'Maybe[Str]', is => 'rw');
has 'email'  => (isa => 'Maybe[Str]', is => 'rw');
has 'start_epoch'  => (isa => 'Maybe[Num]', is => 'rw');
has 'dues_paid_until'  => (isa => 'Maybe[Num]', is => 'rw');
has 'payment_hash' => (isa => 'Maybe[Str]', is => 'rw');
has 'PIN' => (isa => 'Maybe[Str]', is => 'rw');

# Frozen: if the member is _allowed_ to withdraw fuel. Sets cardlock PIN
has 'frozen' => (isa => 'Bool', is => 'rw');

# Billing Error: 
has 'billing_error' => (isa => 'Maybe[Str]', is => 'rw');


has 'name'              => (is => 'ro', isa => 'Str',      lazy_build => 1);
has 'start_ymd'         => (is => 'ro', isa => 'Str',      lazy_build => 1);
has 'start_datetime'    => (is => 'ro', isa => 'Maybe[DateTime]', lazy_build => 1);
has 'start_pretty_date' => (is => 'ro', isa => 'Str', lazy_build => 1);
has 'dues_paid_until_datetime' => (is => 'ro', isa => 'Maybe[DateTime]', lazy_build => 1);
has 'dues_paid_until_pretty_date' => (is => 'ro', isa => 'Str', lazy_build => 1);

sub view_base { 'members' }
method id { $self->member_id }

method as_hash {
    my $hash = { Type => 'member' };
    for my $key (qw/_id _rev member_id first_name last_name phone_num 
                    email start_epoch dues_paid_until payment_hash frozen
                    PIN billing_error/) {
        $hash->{$key} = $self->$key;
    }
    return $hash;
}

sub Create {
    my $class = shift;
    my %p = @_;
    my $success_cb = delete $p{success_cb};
    my $error_cb = delete $p{error_cb} || sub {};

    my $key = "member:$p{member_id}";
    my $new_doc = { _id => $key, Type => 'member', %p };

    my $cv = couchdb->open_doc($key);
    if ($success_cb or $error_cb) { # keep it async
        $cv->cb( sub {
                my $cv2 = shift;
                try { $cv2->recv }
                catch {
                    # Member didn't exist, so create them now
                    my $cv3 = couchdb->save_doc($new_doc);
                    return $cv3->cb( $success_cb );
                }
                return $error_cb->();
            },
        );
    }
    else { # do it blocking
        eval { $cv->recv };
        if ($@) {
            couchdb->save_doc($new_doc)->recv;
            return $class->new_from_couch($new_doc);
        }
        else {
            die "Member $p{member_id} already exists!";
        }
    }
}

method unpaid_transactions {
    my $mid = $self->member_id;
    return Biopay::Transaction->All_unpaid({key => "$mid"});
}

method freeze   { $self->set_freeze(1) }
method unfreeze { $self->set_freeze(0) }
method set_freeze {
    my $val = shift;
    Biopay::Command->Create(
        command => $val ? 'freeze' : 'unfreeze',
        member_id => $self->member_id,
    );
    $self->frozen($val);
    $self->save;
}

method change_PIN {
    my $new_PIN = shift;
    Biopay::Command->Create(
        command => 'change_PIN',
        new_PIN => $new_PIN,
        member_id => $self->id,
    );
}

method send_new_pin {
    my $new_PIN = shift;
    my $html = template 'email/new_pin', {
        member => $self,
        PIN => $new_PIN,
    }, { layout => 'email' };
    email {
        to => $self->email,
        bcc => 'lukecloss@gmail.com',
        from => config->{email_from},
        subject => "Biodiesel Co-op PIN change",
        type => 'html',
        message => $html,
    };
    debug "Just sent PIN change email to " . $self->email;
}

method _build_name {
    my $name = join ' ', grep { defined } ($self->first_name, $self->last_name);
    $name = "Member #" . $self->member_id if $name =~ m/^\s*$/;
    return $name;
}

method _build_start_pretty_date {
    return 'Unknown' unless $self->start_datetime;
    $self->start_datetime->ymd('-');
}

method _build_dues_paid_until_pretty_date {
    return 'Unknown' unless $self->dues_paid_until_datetime;
    $self->dues_paid_until_datetime->ymd('-')
}

method _build_start_datetime {
    return undef unless $self->start_epoch;
    my $dt = DateTime->from_epoch(epoch => $self->start_epoch);
    $dt->set_time_zone('America/Vancouver');
    return $dt;
}

method _build_dues_paid_until_datetime {
    return undef unless $self->dues_paid_until;
    my $dt = DateTime->from_epoch(epoch => $self->dues_paid_until);
    $dt->set_time_zone('America/Vancouver');
    return $dt;
}

