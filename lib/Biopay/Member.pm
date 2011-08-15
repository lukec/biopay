package Biopay::Member;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Dancer::Plugin::Email;
use Moose;
use DateTime;
use Try::Tiny;
use Biopay::Command;
use Biopay::Util qw/now_dt host/;
use Data::UUID;
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
has 'active' => (isa => 'Bool', is => 'rw', default => 1);
has 'password' => (isa => 'Maybe[Str]', is => 'rw');

# Frozen: if the member is _allowed_ to withdraw fuel. Sets cardlock PIN
has 'frozen' => (isa => 'Bool', is => 'rw');

# Billing Error: 
has 'billing_error' => (isa => 'Maybe[Str]', is => 'rw');


# Lazy Built Attributes:

has 'name'       => (is  => 'ro',         isa => 'Str', lazy_build => 1);
has 'login_hash' => (isa => 'Maybe[Str]', is  => 'rw',  lazy_build => 1);
has 'set_password_link' => (isa => 'Maybe[Str]', is => 'ro', lazy_build => 1);

# Lazy Built Date helpers
has 'start_ymd'         => (is => 'ro', isa => 'Str', lazy_build => 1);
has 'start_pretty_date' => (is => 'ro', isa => 'Str', lazy_build => 1);
has 'dues_paid_until_pretty_date' =>
    (is => 'ro', isa => 'Str', lazy_build => 1);
has 'start_datetime' =>
    (is => 'ro', isa => 'Maybe[DateTime]', lazy_build => 1);
has 'dues_paid_until_datetime' =>
    (is => 'ro', isa => 'Maybe[DateTime]', lazy_build => 1);

sub view_base { 'members' }
method id { $self->member_id }

method as_hash {
    my %p = @_;
    my $hash = { Type => 'member' };

    my @minimal_keys = qw/member_id first_name last_name email active/;
    map { $hash->{$_} = $self->$_ } @minimal_keys;
    return $hash if $p{minimal};

    map { $hash->{$_} = $self->$_ }
        qw/_id _rev phone_num start_epoch dues_paid_until payment_hash
           frozen PIN billing_error login_hash password/;
    return $hash;
}

sub Create {
    my $class = shift;
    my %p = @_;
    my $success_cb = delete $p{success_cb};
    my $error_cb = delete $p{error_cb};

    my $key = "member:$p{member_id}";
    my $new_doc = { _id => $key, Type => 'member', %p };

    my $cv = couchdb->save_doc($new_doc);
    if ($success_cb or $error_cb) { # keep it async
        $cv->cb( sub {
                my $cv2 = shift;
                try { 
                    $cv2->recv;
                    $success_cb->( $class->new_from_hash($new_doc) );
                }
                catch {
                    print " (save_doc($key) failed: $_) ";
                    return $error_cb->($_) if $error_cb;
                }
            },
        );
    }
    else { # do it blocking
        try {
            $cv->recv;
            return $class->new_from_hash($new_doc);
        }
        catch {
            die "Member $p{member_id} already exists!";
        }
    }
}

sub By_email { shift->By_view('by_email', @_) }
sub By_hash  { shift->By_view('by_hash', @_) }

method cancel {
    $self->active(0);
    $self->payment_hash(undef);
    $self->freeze(forget_pin => 1); # Does an implicit save()
}

method unpaid_transactions {
    my $mid = $self->member_id;
    return Biopay::Transaction->All_unpaid({key => "$mid"});
}

method freeze   { $self->set_freeze(1, @_) }
method unfreeze { $self->set_freeze(0, @_) }
method set_freeze {
    my $val = shift;
    Biopay::Command->Create( @_,
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

method send_cancel_email {
    return unless $self->email;
    my $new_PIN = shift;
    my $html = template 'email/cancel', {
        member => $self,
    }, { layout => 'email' };
    email {
        to => $self->email,
        bcc => 'lukecloss@gmail.com',
        from => config->{email_from},
        subject => "Biodiesel Membership Cancelled",
        type => 'html',
        message => $html,
    };
    debug "Just sent membership cancellation email to " . $self->email;
}

method send_new_pin_email {
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

method send_billing_error_email {
    my $error = shift;
    my $amount = shift;
    my $html = template 'email/billing-error', {
        member => $self,
        error => $error,
        amount => $amount,
    }, { layout => 'email' };
    email {
        to => $self->email,
        bcc => 'lukecloss@gmail.com',
        from => config->{email_from},
        subject => "Biodiesel Co-op Billing Error!",
        type => 'html',
        message => $html,
    };
    debug "Just sent billing error email to " . $self->email;
}

method send_set_password_email {
    delete $self->{login_hash}; # Cause it to be re-created
    my $html = template 'email/set-password', {
        member => $self,
    }, { layout => 'email' };
    email {
        to => $self->email,
        bcc => 'lukecloss@gmail.com',
        from => config->{email_from},
        subject => "Biodiesel Co-op - Set your password",
        type => 'html',
        message => $html,
    };
    debug "Just sent set-password email to " . $self->email;
}

method membership_is_expired {
    # Assume dues are not expired if we do not have any date
    return 0 unless $self->dues_paid_until;

    return $self->dues_paid_until_datetime < now_dt();
}

method renew_membership {
    my $new_expiry = now_dt() + DateTime::Duration->new(years => 1);
    $self->dues_paid_until($new_expiry->epoch);
    $self->save(@_);
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

method _build_login_hash { Data::UUID->new->create_str }
method _build_set_password_link {
    host() . '/set-password/' . $self->login_hash;
}

