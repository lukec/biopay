package Biopay::Member;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Dancer::Plugin::Email;
use Moose;
use DateTime;
use Try::Tiny;
use Biopay::Command;
use Biopay::Util qw/now_dt host email_admin/;
use Data::UUID;
use methods;

extends 'Biopay::Resource';

has 'member_id' => (isa => 'Num', is => 'ro', required => 1);
has 'first_name' => (isa => 'Maybe[Str]', is => 'rw');
has 'last_name'  => (isa => 'Maybe[Str]', is => 'rw');
has 'address'    => (isa => 'Maybe[Str]', is => 'rw');
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
        qw/_id _rev address phone_num start_epoch dues_paid_until payment_hash
           frozen PIN billing_error login_hash password/;
    return $hash;
}

sub Create {
    my $class = shift;
    my %p = @_;
    my $success_cb = delete $p{success_cb};
    my $error_cb = delete $p{error_cb};

    unless ($p{member_id}) {
        try {
            $p{member_id} = $class->NextMemberID();
        }
        catch {
            email_admin("Error fetching NextMemberID",
                "Could not find the next member id: $_");
            die $_;
        };
    }
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
                    if ($error_cb) { $error_cb->($_) }
                    else {
                        print " (save_doc($key) failed: $_) ";
                    }
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

sub NextMemberID {
    my $class = shift;
    my $tries = shift // 3;

    my $cv = couchdb->open_doc("MemberIDs");
    try { 
        my $doc = $cv->recv;
        die "MemberIDs->{nextID} is not found!" unless $doc->{nextID};
        my $id = $doc->{nextID}++;
        couchdb->save_doc($doc);
        return $id;
    }
    catch {
        if ($_ =~ m/^404/) {
            die "Could not load the 'MemberIDs' doc! Make sure it exists.";
        }
        elsif ($_ =~ m/^409/) {
            debug "Conflict when fetching NextMemberID - tries=$tries";
            return $class->NextMemberID(--$tries) if $tries > 0;
            die "Failed to allocate a MemberID after 3 attempts!";
        }
        die "Failed to load 'MemberIDs' doc: $_";
    };
}

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
    $self->_send_email(
        template => 'cancel',
        subject  => 'Membership Cancelled',
    );
}

method send_new_pin_email {
    my $new_PIN = shift;
    $self->_send_email(
        template => 'new_pin',
        subject  => 'Cardlock PIN change',
        args => {
            PIN => $new_PIN,
        },
    );
}

method send_billing_error_email {
    my $error = shift;
    my $amount = shift;
    $self->_send_email(
        template => 'billing-error',
        subject  => 'Billing Error!',
        args => {
            error => $error,
            amount => $amount,
        },
    );
}

method send_set_password_email {
    delete $self->{login_hash}; # Cause it to be re-created
    $self->_send_email(
        template => 'set-password',
        subject  => 'Set your password',
    );
}

method send_welcome_email {
    my $pin = shift;
    $self->_send_email(
        template => 'welcome',
        subject  => 'Welcome to the Co-op!',
        args => {
            PIN => $pin,
        }
    );
}

method send_payment_update_email {
    $self->_send_email(
        template => 'update-payment',
        subject => 'Please update your payment details',
    );
}


method _send_email {
    my %p = @_;
    unless ($self->email) {
        debug "Attempted to send $p{template} email to " . $self->id
            . " but they have no email address set.";
        return;
    }
    try {
        my $html = template "email/$p{template}", {
            member => $self,
            %{ $p{args} || {} },
        }, { layout => 'email' };
        email {
            to => $self->email,
            bcc => 'lukecloss@gmail.com',
            from => config->{email_from},
            subject => "Biodiesel Co-op - $p{subject}",
            type => 'html',
            message => $html,
        };
        debug "Just sent $p{template} email to " . $self->email;
    }
    catch {
        debug "Failed to send $p{template} email to " . $self->email . ": $_";
        email_admin("Failed to send $p{template} email",
            "I attempted to send an email to " . $self->email
            . " but failed: $_");
    };
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
    my $hash = $self->login_hash;
    unless ($hash) {
        $hash = $self->{login_hash} = $self->_build_login_hash;
        $self->save;
    }
    host() . '/set-password/' . $self->login_hash;
}

