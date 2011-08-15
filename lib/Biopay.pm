package Biopay;
use 5.12.0;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Dancer::Plugin::Auth::RBAC;
use Dancer::Plugin::Bcrypt;
use Biopay::Transaction;
use Biopay::Member;
use Biopay::Stats;
use Biopay::Prices;
use AnyEvent;
use DateTime;
use DateTime::Duration;
use Biopay::Util qw/email_admin host/;
use Try::Tiny;

our $VERSION = '0.1';

my %public_paths = (
    map { $_ => 1 }
    qw( / /login /logout /terms /refunds /privacy ),
    '/admin-login',
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
    if (my $m = session 'member') {
        # TODO
    }
    elsif (session 'is_admin') {
        # TODO
    }
    else {
        unless ($public_paths{$path} or $path =~ m{^/(login|set-password)}) {
            debug "no bio session, redirecting to login (from $path)";
            forward '/login', {
                message => "Please log-in first.",
                path => request->path_info,
            };
        }
    }
};

get '/' => sub {
    template 'index', {
        stats => Biopay::Stats->new,
    };
};
for my $page (qw(privacy refunds terms)) {
    get "/$page" => sub { template $page };
}

before_template sub {
    my $tokens = shift;

    if (session 'is_admin') {
        $tokens->{admin_username} = session 'username';
        $tokens->{is_admin} = 1;
    }
    elsif (my $m = session 'member') {
        my $m = $tokens->{member} ||= try {
            Biopay::Member->By_id($m->{member_id})
        };
        $tokens->{is_member} = $tokens->{member} ? 1 : 0;

        unless ($m->payment_hash) {
            $tokens->{member_message} ||= <<EOT;
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
    my $member = Biopay::Member->By_email($user);
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
        return forward "/login";
    }
    my $member = Biopay::Member->By_email($user);
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
    $member->password(bcrypt($password1));
    $member->login_hash(undef);
    $member->save;
    return redirect host() . "/login";
};

get '/admin-login' => sub {
    template 'admin-login' => { 
        message => param('message') || '',
        path => param('path'),
        host => host(),
    };
};

post '/admin-login' => sub {
    my $user = param('username');
    my $auth = auth($user, param('password'));
    if (my $errors = $auth->errors) {
        my $msg = join(', ', $auth->errors);
        debug "Auth errors: $msg";
        return forward "/login", {message => $msg}, { method => 'GET' };
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
    my $txns;
    if (my $m = session 'member') {
    }
    else {
    }
    template 'txns', {
        txns => Biopay::Transaction->All_most_recent,
    };
};

get '/txns/:txn_id' => sub {
    my $txn = Biopay::Transaction->By_id(params->{txn_id});
    my %vars = ( txn => $txn );
    if (params->{mark_as_unpaid} and $txn->paid) {
        $txn->paid(0);
        $txn->save;
        $vars{message} = "This transaction is now marked as <strong>not paid</strong>."
    }
    if (params->{mark_as_paid} and !$txn->paid) {
        $txn->paid(1);
        $txn->save;
        $vars{message} = "This transaction is now marked as <strong>paid</strong>."
    }
    template 'txn', \%vars;
};

get '/members' => sub {
    if (my $mid = params->{jump_to}) {
        redirect "/members/$mid" if $mid =~ m/^\d+$/;
    }
    my $members = Biopay::Member->All;
    template 'members', { members => $members };
};

sub new_member_dates {
    my $now = DateTime->now;
    $now->set_time_zone('America/Vancouver');
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
    redirect "/members/" . $member->id . "?message=Created";
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
        redirect '/members/' . $member->id . '?frozen=1';
    }
    elsif (params->{please_unfreeze} and $member->frozen) {
        $member->unfreeze;
        redirect '/members/' . $member->id . '?thawed=1';
    }
    template 'freeze', {
        member => $member,
    };
};

get '/members/:member_id/cancel' => sub {
    my $member = member();
    if (params->{please_cancel} and $member->active) {
        $member->cancel;
        $member->send_cancel_email if params->{send_email};
        redirect '/members/' . $member->id . '?cancelled=1';
    }
    template 'cancel', {
        member => $member,
    };
};

get '/members/:member_id/change-pin' => sub {
    my $msg = 'Please choose a 4-digit PIN.';
    $msg = "That PIN is invalid. $msg" if params->{bad_pin};
    template 'change-pin', {
        member => member(),
        message => $msg,
    };
};
post '/members/:member_id/change-pin' => sub {
    my $member = member();
    my $new_PIN = params->{new_PIN} || '';
    $new_PIN = 0 unless $new_PIN =~ m/^\d{4}$/;
    if ($new_PIN) {
        $member->change_PIN($new_PIN);
        return redirect '/members/' . $member->id . '?PIN_changed=1';
    }
    return redirect '/members/' . $member->id . '/change-pin?bad_pin=1';
};

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
    redirect "/members/" . $member->id . "?message=Saved";
};

get '/members/:member_id' => sub {
    my $msg = params->{message};
    $msg = "A freeze request was sent to the cardlock." if params->{frozen};
    $msg = "An un-freeze request was sent to the cardlock." if params->{thawed};
    $msg = "A PIN change request was sent to the cardlock." if params->{PIN_changed};
    $msg = "This membership has been cancelled." if params->{PIN_changed};
    my $member = member();
    template 'member', {
        member => $member,
        message => $msg,
        ( $member->active ? 
            ( stats => Biopay::Stats->new,
            ( $member ? (payment_return_url => host()
                        . '/members/' . $member->id . '/payment') : ())
            ) : ())
    };
};

get '/members/:member_id/payment' => sub {
    my $member = member();
    forward '/members/' . $member->id, { message => update_payment_profile_message() };
};

sub update_payment_profile_message {
    # XXX How to verify response?
    my $member = member();
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
        message => update_payment_profile_message() || params->{message},
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
    die "not yet implemented";
    my $member = session_member();
    my $msg = params->{message};
    template 'member', {
        member => $member,
        stats => Biopay::Stats->new,
        message => $msg,
    };
};


get '/member/change-pin' => sub {
    die "not yet implemented";
    my $member = session_member();
    my $msg = params->{message};
    template 'member', {
        member => $member,
        stats => Biopay::Stats->new,
        message => $msg,
    };
};

get '/member/cancel' => sub {
    die "not yet implemented";
    my $member = session_member();
    my $msg = params->{message};
    template 'member', {
        member => $member,
        stats => Biopay::Stats->new,
        message => $msg,
    };
};

true;
