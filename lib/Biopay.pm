package Biopay;
use 5.14.0;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Dancer::Plugin::Auth::RBAC;
use Biopay::Transaction;
use Biopay::Member;
use Biopay::Stats;
use Biopay::Prices;
use AnyEvent;
use DateTime;
use DateTime::Duration;
use Biopay::Util qw/email_admin/;
use Try::Tiny;

our $VERSION = '0.1';

sub host {
    return 'http://' . request->host if request->host =~ m/localhost/;
    # Otherwise use the bona fide dotcloud SSL cert
    return 'https://biopay.ssl.dotcloud.com';
}

my %public_paths = (
    map { $_ => 1 }
    qw( / /login /terms /refunds /privacy )
);

before sub {
    my $path = request->path_info;
    if (session('bio')) {
        # Let AE run, it can cleanup any lingering AE::HTTP state
        my $w = AnyEvent->condvar;
        my $idle = AnyEvent->idle (cb => sub { $w->send });
        $w->recv; # enters "main loop" till $condvar gets −>send
        return;
    }

    unless ($public_paths{$path} or $path =~ m{^/login}) {
        debug "no bio session, redirecting to login (from $path)";
        forward '/login', {
            message => "Please log-in first.",
            path => request->path_info,
        };
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
    $tokens->{is_admin} = session('bio') ? 1 : 0;
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
        return forward "/login", {message => $msg}, { method => 'GET' };
    }
    if ($auth->asa('admin')) {
        debug "Allowing access to admin user $user";
        session bio => { username => $user };
        return redirect host() . param('path') || "/";
    }
    debug "Found the $user user, but they are not an admin.";
    return forward "/login", {}, { method => 'GET' };
};

get '/logout' => sub {
    session bio => undef;
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
    try {
        my ($y, $m, $d) = split m#[/-]#, $ymd;
        my $dt = DateTime->new(year => $y, month => $m, day => $d);
        $dt->set_time_zone('America/Vancouver');
        return $dt->epoch;
    };
    return undef;
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
    for my $key (qw/first_name last_name phone_num email payment_hash/) {
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
    template 'member', {
        member => member(),
        message => $msg,
        stats => Biopay::Stats->new,
        payment_return_url => host() . '/members/' . member()->id . '/payment',
    };
};

get '/members/:member_id/payment' => sub {
    my $member = member();
    my $msg = "Successfully updated payment profile.";
    given (params->{responseCode}) {
        when (1) { # Successful!
            $member->payment_hash(params->{customerCode});
            $member->save;
        }
        when (21) { # Cancelled, do nothing
            $msg = "Payment profile update cancelled.";
        }
        default {
            email_admin("Error saving payment profile",
                "I tried to update a payment profile for member " . $member->name
                . " (" . $member->id . ") but it failed with code: "
                . params->{responseCode} . "\n\n"
                . "Message: " . params->{responseMessage}
            );
            $msg = "Error updating payment profile: " . params->{responseMessage};
        }
    }
    forward '/members/' . $member->id, { message => $msg };
};

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

true;
