package Biopay;
use 5.12.0;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Dancer::Plugin::Auth::RBAC;
use Dancer::Plugin::Bcrypt;
use Biopay::Transaction;
use Biopay::Member;
use Biopay::PotentialMember;
use Biopay::Stats;
use Biopay::Prices;
use AnyEvent;
use DateTime;
use DateTime::Duration;
use Biopay::Util qw/email_admin host now_dt/;
use Try::Tiny;
use Email::Valid;
use Number::Phone;
use Data::Dumper;

our $VERSION = '0.1';

my %public_paths = (
    map { $_ => 1 }
    qw( / /login /logout /terms /refunds /privacy),
    '/forgot-password', '/admin-login', '/biodiesel-faq',
    '/new-member',
);

before sub {
    # XXX hack to try to work around the 596 bug from AE::HTTP
    # If this issue persists using other couch instances
    # Let AE run until idle.
    #  - The thinking here is that maybe this will allow AE::HTTP to
    #    close down any lingering old connections before blindly trying
    #    to reuse them.
    {
        my $w = AnyEvent->condvar;
        my $idle = AnyEvent->idle (cb => sub { $w->send });
        $w->recv; # enters "main loop" till $condvar gets −>send
    }

    my $path = request->path_info;
    return if $public_paths{$path}
               or $path =~ m{^/(login|set-password|new-member)};

    if (my $m = session 'member') {
        unless ($path =~ m{^/member/}) {
            debug "Member cannot access '$path'";
            session message => "Sorry, that is not available to you.";
            redirect '/';
        };
        return;
    }
    elsif (session 'is_admin') {
        if ($path =~ m{^/member/}) {
            debug "Admin cannot access '$path'";
            session message => "Sorry, that is not available to you.";
            return redirect '/';
        };
        return;
    }

    debug "no bio session, redirecting to login (from $path)";
    forward '/login', {
        message => "Please log-in first.",
        path => request->path_info,
    };
};

get '/' => sub {
    template 'index', {
        stats => Biopay::Stats->new,
    };
};
for my $page (qw(privacy refunds terms biodiesel-faq)) {
    get "/$page" => sub { template $page };
}

before_template sub {
    my $tokens = shift;

    $tokens->{info_email_link} = '<a href="mailto:info@vancouverbiodiesel.org">info@vancouverbiodiesel.org</a>';
    $tokens->{host} = host();

    if (my $msg = session 'message') {
        $tokens->{message} ||= $msg;
        session 'message' => undef;
    }

    if (session 'is_admin') {
        $tokens->{admin_username} = session 'username';
        $tokens->{is_admin} = 1;
    }
    elsif (my $m = session 'member') {
        my $m = $tokens->{member} ||= try {
            Biopay::Member->By_id($m->{member_id})
        };
        $tokens->{is_member} = $tokens->{member} ? 1 : 0;

        unless ($m->active or $tokens->{message}) {
            $tokens->{message} ||= <<'EOT';
Your account is cancelled. <a href="mailto:info@vancouverbiodiesel.org">Email us</a> if you have any problems.
EOT
        }
        unless ($m->payment_hash or $tokens->{message}) {
            $tokens->{message} ||= <<EOT;
We do not have any payment info for you!<br />
<p>
<a href="/member/update-payment"><strong>Please click here to update your payment details.</strong></a>
</p>
EOT
        }
    }
};

get '/login' => sub {
    template 'login' => { 
        message => param('message') || '',
        path => param('path'),
        host => host(),
    };
};

post '/login' => sub {
    my $user = param('username');
    my $auth = auth($user, param('password'));
    if (my $errors = $auth->errors) {
        my $msg = join(', ', $auth->errors);
        debug "Auth errors: $msg";
        if ($msg =~ m/No password has been set/) {
            return forward "/set-password", {},
                { method => 'GET' };
        }
        return forward "/login", {message => $msg}, { method => 'GET' };
    }
    my $member = Biopay::Member->By_id($user);
    unless ($member) {
        return forward "/login", { message => "That user does not exist." },
            { method => 'GET' };
    }
    unless ($member->active) {
        return forward "/login",
            { message => "That user is no longer active." },
            { method  => 'GET' };
    }

    debug "Allowing access to member user $user";
    session username => $user;
    session member => $member->as_hash(minimal => 1);
    return redirect host() . param('path') || "/";
};

get '/set-password' => sub {
    my $user = param('username');
    unless ($user) {
        return redirect "/login";
    }
    my $member = Biopay::Member->By_id($user);
    if ($member and !$member->password) {
        $member->send_set_password_email;
        # Remember to save the hash
        $member->save;
    }
    template 'set-password' => { member => $member };
};

get '/set-password/:hash' => sub {
    my $hash = param('hash');
    my $member = Biopay::Member->By_hash($hash);

    template 'set-password' => { 
        member => $member,
        confirmed => 1,
        path => param('path'),
    };
};

post '/set-password' => sub {
    my $hash = param('hash');
    my $password1 = param('password1');
    my $password2 = param('password2');

    my $member = Biopay::Member->By_hash($hash);
    unless ($member) {
        my $msg = "Sorry, we could not find that member.";
        return forward "/login", {message => $msg}, { method => 'GET' };
    }
    unless ($password1 eq $password2) {
        return template 'set-password' => { 
            member => $member,
            confirmed => 1,
            message => "The passwords do not match. Try again.",
        };
    }
    unless (length($password1) >= 8) {
        return template 'set-password' => { 
            member => $member,
            confirmed => 1,
            message => "The password must be at least 8 characters.",
        };
    }
    $member->password(bcrypt($password1));
    $member->login_hash(undef);
    $member->save;
    session message => "Successfully saved your password. Please login.";
    set_member_session($member);
    my $path = param('path') || '/';
    return redirect host() . $path;
};

get '/admin-login' => sub {
    template 'admin-login' => { 
        message => param('message') || '',
        path => param('path'),
    };
};

post '/admin-login' => sub {
    my $user = param('username');
    my $auth = auth($user, param('password'));
    if (my $errors = $auth->errors) {
        my $msg = join(', ', $auth->errors);
        debug "Auth errors: $msg";
        return forward "/admin-login", {message => $msg}, { method => 'GET' };
    }
    if ($auth->asa('admin')) {
        debug "Allowing access to admin user $user";
        session username => $user;
        session is_admin => 1;
        return redirect host() . param('path') || "/";
    }
    debug "Found the $user user, but they are not an admin.";
    return forward "/login", {message => "Sorry, you are not an admin."},
                             { method => 'GET' };
};

get '/logout' => sub {
    session->destroy;
    session->flush;
    return redirect '/';
};

get '/unpaid' => sub {
    my $txns = Biopay::Transaction->All_unpaid;
    my %by_member;
    for my $t (@$txns) {
        push @{ $by_member{ $t->member_id } }, $t;
    }
    template 'unpaid', {
        txns => [ map { $by_member{$_} } sort { $a <=> $b } keys %by_member ],
        now => scalar(localtime),
    };
};

post '/unpaid/mark-as-paid' => sub {
    my $txn_param = params->{txns};
    my @txn_ids = ref $txn_param ? @$txn_param : ($txn_param);
    my @txns;
    my %paid;
    for my $txn_id (@txn_ids) {
        my $txn = Biopay::Transaction->By_id($txn_id);
        next unless $txn;
        next if $txn->paid;

        $txn->paid(1);
        $txn->save;
        push @txns, $txn;
        push @{ $paid{ $txn->{member_id} } }, $txn->id;
    }

    if (params->{send_receipt}) {
        for my $mid (keys %paid) {
            my $member = Biopay::Member->By_id($mid);
            debug "Creating receipt job for member $mid";
            Biopay::Command->Create(
                command => 'send-receipt',
                member_id => $mid,
                txn_ids => $paid{$mid},
            );
        }
    }

    template 'mark-as-paid', {
        txns => \@txns,
    };
};

get '/txns' => sub {
    template 'txns', {
        txns => Biopay::Transaction->All_most_recent,
    };
};

get '/txns/:txn_id' => sub {
    my $txn = Biopay::Transaction->By_id(params->{txn_id});
    if (params->{mark_as_unpaid} and $txn->paid) {
        $txn->paid(0);
        $txn->save;
        session message =>
            "This transaction is now marked as <strong>not paid</strong>."
    }
    if (params->{mark_as_paid} and !$txn->paid) {
        $txn->paid(1);
        $txn->save;
        session message =>
            "This transaction is now marked as <strong>paid</strong>."
    }
    template 'txn', { txn => $txn };
};

get '/members' => sub {
    if (my $mid = params->{jump_to}) {
        redirect "/members/$mid" if $mid =~ m/^\d+$/;
    }
    my $members = Biopay::Member->All;
    template 'members', { members => $members };
};

sub new_member_dates {
    my $now = now_dt();
    my $one_year = $now + DateTime::Duration->new(years => 1);
    return (
        start_date => $now->ymd('/'),
        dues_paid_until_date => $one_year->ymd('/'),
    );
}

get '/members/create' => sub {
    template 'member-create', {
        member_id => params->{member_id},
        new_member_dates(),
    };
};

post '/members/create' => sub {
    my @member_attrs = qw/member_id first_name last_name phone_num email 
                   start_date dues_paid_until_date payment_hash/;
    my %hash = map { $_ => params->{$_} } @member_attrs;

    my $member = member();
    if ($member) {
        return template 'member-create', {
            message => "That member_id is already in use!",
            %hash,
            new_member_dates(),
        };
    }

    $hash{start_epoch} = ymd_to_epoch(delete $hash{start_date});
    $hash{dues_paid_until} = ymd_to_epoch(delete $hash{dues_paid_until_date});
    $member = Biopay::Member->Create(%hash);
    session message => "Created new co-op member " . $member->name;
    redirect "/members/" . $member->id;
};

sub ymd_to_epoch {
    my $ymd = shift;
    return try {
        my ($y, $m, $d) = split m#[/-]#, $ymd;
        my $dt = DateTime->new(year => $y, month => $m, day => $d);
        $dt->set_time_zone('America/Vancouver');
        return $dt->epoch;
    } || undef;
}

get '/members/:member_id/txns' => sub {
    template 'member-txns', {
        member => member(),
        txns   => Biopay::Transaction->All_for_member(params->{member_id}),
    };
};

get '/members/:member_id/unpaid' => sub {
    template 'member-unpaid', {
        member => member(),
        txns   => Biopay::Transaction->All_unpaid({key => params->{member_id}}),
    };
};

get '/members/:member_id/freeze' => sub {
    my $member = member();
    if (params->{please_freeze} and not $member->frozen) {
        $member->freeze;
        session message => "A freeze request was sent to the cardlock.";
        redirect '/members/' . $member->id;
    }
    elsif (params->{please_unfreeze} and $member->frozen) {
        $member->unfreeze;
        session message => "An un-freeze request was sent to the cardlock.";
        redirect '/members/' . $member->id;
    }
    template 'freeze', {
        member => $member,
    };
};

get '/members/:member_id/cancel' => sub {
    my $member = member();
    if (params->{force} and $member->active) {
        $member->cancel;
        $member->send_cancel_email if params->{send_email};
        session message => "This membership has been cancelled.";
        return redirect '/members/' . $member->id;
    }
    template 'cancel', {
        member => $member,
    };
};

get '/members/:member_id/change-pin' => sub {
    my $m = member();
    template 'change-pin', {
        member => $m,
        action => '/members/' . $m->id . '/change-pin',
        message => session('message') || 'Please choose a 4-digit PIN.',
    };
};

post '/members/:member_id/change-pin' => sub {
    my $member = member();
    return handle_change_pin(
        member => $member,
        good_url => '/members/' . $member->id,
        bad_url  => '/members/' . $member->id . '/change-pin',
    );
};

sub handle_change_pin {
    my %p = @_;
    my $new_PIN = params->{new_PIN} || '';
    $new_PIN = 0 unless $new_PIN =~ m/^\d{4}$/;
    if ($new_PIN) {
        $p{member}->change_PIN($new_PIN);
        session message => "A PIN change request was sent to the cardlock.";
        return redirect $p{good_url};
    }
    session message => 'Sorry, the PIN must be 4 digits. Try again';
    return redirect $p{bad_url};
}

get '/members/:member_id/edit' => sub {
    template 'member-edit', {
        member => member(),
    };
};

post '/members/:member_id/edit' => sub {
    my $member = member();
    for my $key (qw/first_name last_name phone_num email/) {
        $member->$key(params->{$key});
    }
    $member->start_epoch(ymd_to_epoch(params->{start_date}));
    $member->dues_paid_until(ymd_to_epoch(params->{dues_paid_until_date}));
    $member->save;
    session message => 'Saved';
    redirect "/members/" . $member->id;
};

get '/members/:member_id' => sub {
    my $member = member();
    template 'member', {
        member => $member,
        ( $member->active ? 
            ( stats => Biopay::Stats->new,
            ( $member ? (payment_return_url => host()
                        . '/members/' . $member->id . '/payment') : ())
            ) : ())
    };
};

get '/members/:member_id/payment' => sub {
    my $member = member();
    forward '/members/' . $member->id, { message => update_payment_profile_message($member) };
};

sub update_payment_profile_message {
    # XXX How to verify response?
    my $member = shift;
    given (params->{responseCode}) {
        when (undef) { return undef }
        when (1) { # Successful!
            $member->payment_hash(params->{customerCode});
            $member->billing_error(undef);
            $member->save;
            return "Successfully updated payment profile.";
        }
        when (21) { # Cancelled, do nothing
            return "Payment profile update cancelled.";
        }
        when (7) { # Duplicate card used, likely due to testing.
            return params->{responseMessage};
        }
        default {
            my $name = $member ? $member->name : 'no-name';
            my $id   = $member ? $member->id   : 0;
            email_admin("Error saving payment profile",
                "I tried to update a payment profile for member $name"
                . " ($id) but it failed with code: "
                . params->{responseCode} . "\n\n"
                . "Message: " . params->{responseMessage}
            );
            return "Error updating payment profile: " . params->{responseMessage};
        }
    }
}

get '/fuel-price' => sub {
    template 'fuel-price', {
        current_price => Biopay::Prices->new->fuel_price,
    };
};
post '/fuel-price' => sub {
    my $new_price = params->{new_price};
    my $prices = Biopay::Prices->new;
    my $msg = '';
    if ($new_price and $new_price =~ m/^[123]\.\d{2}$/) {
        $msg = "Updated the price to \$$new_price per Litre.";
        $prices->set_fuel_price($new_price);
    }
    else {
        $msg = "That price doesn't look valid - try again.";
    }
    template 'fuel-price', {
        current_price => $prices->fuel_price,
        message => $msg,
    };
};

sub member {
    my $id = params->{member_id} or return undef;
    return Biopay::Member->By_id($id);
}

sub session_member {
    if (my $m = session 'member') {
        return Biopay::Member->By_id($m->{member_id});
    }
    return undef;
}

get '/member/view' => sub {
    my $member = session_member();
    template 'member', {
        member => $member,
        stats => Biopay::Stats->new,
        message => update_payment_profile_message($member) || params->{message},
    };
};

get '/member/update-payment' => sub {
    my $member = session_member();
    if ($member) {
        my $url = "https://www.beanstream.com/scripts/PaymentProfile/"
            . "webform.asp?serviceVersion=1.0&merchantId=" 
            . config->{merchant_id}
            . "&trnReturnURL=" . host() . '/member/view';
        if (my $h = $member->payment_hash) {
            $url .= "&operationType=M&customerCode=$h";
        }
        else {
            $url .= "&operationType=N";
        }
        return redirect $url;
    }
    debug "No member found, could not satisfy /update-payment";
    return redirect "/";
};

get '/member/edit' => sub {
    my $member = session_member();
    my $msg = params->{message};
    template 'member-edit', {
        member => $member,
        message => $msg,
    };
};

post '/member/edit' => sub {
    my $member = session_member();
    for my $key (qw/first_name last_name phone_num email/) {
        $member->$key(params->{$key});
    }
    $member->save;
    session message => "Saved!";
    redirect "/member/view";
};


get '/member/change-pin' => sub {
    template 'change-pin', {
        member => session_member(),
        action => '/member/change-pin',
        message => session('message') || 'Please choose a 4-digit PIN.',
    };
};

post '/member/change-pin' => sub {
    my $member = session_member();
    return handle_change_pin(
        member => $member,
        good_url => '/member/view',
        bad_url  => '/member/change-pin',
    );
};

get '/member/cancel' => sub {
    my $member = session_member();
    if (params->{force} and $member->active) {
        $member->cancel;
        $member->send_cancel_email;
        session message => <<'EOT';
This membership has been cancelled.<br />
<p>If you have any feedback for our co-op, please send it to us at <a href="mailto:info@vancouverbiodiesel.org">info@vancouverbiodiesel.org</a>.</p>
EOT
        forward '/member/view';
    }
    template 'cancel', {
        member => $member,
    };
};

get '/member/txns' => sub {
    my $m = session_member();
    template 'txns', {
        txns => Biopay::Transaction->All_for_member($m->id)
    };
};

get '/member/txns/:txn_id' => sub {
    my $m = session_member();
    my $txn = Biopay::Transaction->By_id(params->{txn_id});
    if ($txn->member_id != $m->id) {
        session message => "You are not allowed to view that transaction.";
        return redirect '/member/txns';
    }
    template 'txn', { txn => $txn };
};

get '/member/unpaid' => sub {
    my $m = session_member();
    template 'member-unpaid', {
        member => $m,
        txns   => Biopay::Transaction->All_unpaid({key => $m->id}),
    };
};

get '/forgot-password' => sub {
    template 'forgot-password', {message => params->{message}};
};
post '/forgot-password' => sub {
    my $member_id = params->{member_id};
    unless ($member_id) {
        return forward '/forgot-password', {
            message => "Please enter your member ID.",
        }, {method => 'GET'};
    }

    my $m = Biopay::Member->By_id($member_id);
    unless ($m) {
        return forward '/forgot-password', {
            message => "Sorry, a member with that member ID cannot "
                           . "be found.",
        }, {method => 'GET'};
    }

    $m->send_set_password_email;
    # Remember to save the hash
    $m->save;
    template 'forgot-password', { email_sent => 1 };
};

get '/member/change-password' => sub {
    template 'change-password', {message => params->{message}};
};
post '/member/change-password' => sub {
    my $member = session_member();
    my $old_password = param('old_password');
    my $password1 = param('password1');
    my $password2 = param('password2');

    unless (bcrypt_validate_password($old_password, $member->{password})) {
        return template 'change-password' => { 
            member => $member,
            confirmed => 1,
            message => "The current password is not correct.",
        };
    }
    unless ($password1 eq $password2) {
        return template 'change-password' => { 
            member => $member,
            confirmed => 1,
            message => "The passwords do not match. Try again.",
        };
    }
    unless (length($password1) >= 8) {
        return template 'change-password' => { 
            member => $member,
            confirmed => 1,
            message => "The password must be at least 8 characters.",
        };
    }
    $member->password(bcrypt($password1));
    $member->login_hash(undef);
    $member->save;
    session message => 'Your password was updated.';
    return redirect host() . "/";
};

get '/new-member' => sub {
    my $dt = now_dt();
    my $date = sprintf('%s %d, %d', $dt->month_name, $dt->day, $dt->year);
    template 'new-member', {
        today_date => $date,
        show_agreement => params->{show_agreement},
        message => params->{message},
        first_name => params->{first_name} || 'First name',
        last_name => params->{last_name} || 'Last name',
        map { $_ => params->{$_} } qw/email phone address PIN/
    };
};

post '/new-member' => sub {
    my $msg;
    (my $fname = params->{first_name}) =~ s/^First name.*//;
    (my $lname = params->{last_name}) =~ s/^Last name.*//;
    my $phone = params->{phone};
    my $np = Number::Phone->new('+1' . $phone);
    my $phone_is_valid = $np && $np->is_valid;
    my $address = params->{address};
    my $email = params->{email};
    my $pin = params->{PIN};
    my $checked
        = params->{chk_video} && params->{chk_vehicle} && params->{chk_terms};
    if (!$fname or !$lname) {
        $msg = "Your first and last name are required!";
    }
    elsif (!$address) {
        $msg = "Your home address is required!";
    }
    elsif (!$email) {
        $msg = "Your email address is required!";
    }
    elsif (!Email::Valid->address($email)) {
        $msg = "Sorry, that does not look like a valid email address.";
    }
    elsif (!$phone) {
        $msg = "Your phone number is required!";
    }
    elsif (!$phone_is_valid) {
        $msg = "Sorry, that does not look like a valid phone number.";
    }
    elsif (!$pin) {
        $msg = "A 4 digit cardlock PIN is required!";
    }
    elsif ($pin !~ m/^\d{4}$/) {
        $msg = "Sorry, the cardlock PIN must be 4 digits.";
    }
    elsif (!$checked) {
        $msg = "Please click the checkboxes to agree to the terms.";
    }


    my $member = try {
        Biopay::PotentialMember->Create(
            first_name => $fname,
            last_name  => $lname,
            phone_num  => $phone,
            email      => $email,
            PIN         => $pin,
        );
    }
    catch {
        if ($_ =~ m/^409/) {
            Biopay::PotentialMember->By_email($email);
        }
        else {
            $msg = "Sorry, there was an error creating your account: $_";
            email_admin("Error creating new member account",
                "Error creating new potential member: $_\n\n"
                . "First='$fname' Last='$lname' phone='$phone'\n"
                . "Email='$email' PIN='$pin'\n");
        }
    };

    if ($msg) {
        return forward '/new-member', {
            show_agreement => 1,
            message => "Error: $msg",
            map { $_ => params->{$_} }
                qw/first_name last_name email phone address PIN/
        }, { method => 'GET' };
    }

    return template 'new-member-payment', {
        member => $member,
        payment_url => $member->payment_setup_url,
    };
};

get '/new-member/:hash' => sub {
    my $hash = params->{hash};
    my ($msg, $pm, $member);
    try {
        $pm = Biopay::PotentialMember->By_hash($hash);
        unless ($pm) {
            $msg = "We could not find a member at that location.";
            return;
        }
        $msg = update_payment_profile_message($pm);
        if ($pm->payment_hash) {
            debug "Payment profile for " .$pm->email. " was created.";
            $member = $pm->make_real;
            Biopay::Command->Create(
                command => 'register-member',
                member_id => $member->id,
                PIN => $pm->PIN,
            );
        }
    }
    catch {
        email_admin("Failed to process payment profile from new member",
            "When accepting payment info at /new-member/$hash, we had"
            . " the following error: $_\n\n"
            . ($pm ? "Member email=" . $pm->email." and PIN=".$pm->PIN . "\n\n"
                   : '')
            . Dumper(scalar params));
        $msg = "Sorry, we had an error: $_";
    };

    unless ($pm) {
        session message => $msg;
        return redirect '/';
    }

    return template 'new-member-complete' if $member;
    template 'new-member-payment', {
        member => $pm,
        payment_url => $pm->payment_setup_url,
        message => $msg,
    };
};

true;
