package Biopay;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Dancer::Plugin::Auth::RBAC;
use Biopay::Transaction;
use Biopay::Member;
use Biopay::Stats;

our $VERSION = '0.1';

sub host {
    'http' . (request->host =~ m/localhost/ ? '' : 's')
    . '://' . request->host
}

before sub {
    my $path = request->path_info;
    return if session('bio');

    unless ($path eq '/' or $path =~ m{^/login}) {
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
    template 'unpaid', { txns => $txns };
};

get '/unpaid/process' => sub {
    my $txns = Biopay::Transaction->All_unpaid;
    my @current;
    my $current_id;
    my $total_price = 0;
    my $offset = params->{offset} || 0;
    my $orig_offset = $offset;
    my %skip_members;
    for my $txn (@$txns) {
        if ($offset) {
            if (!$skip_members{$txn->member_id}) {
                # Not yet seen this member.
                $offset--;
                $skip_members{$txn->member_id} = 1;
            }
        }
        next if $skip_members{$txn->member_id};

        $current_id ||= $txn->member_id;
        last if $current_id != $txn->member_id;
        push @current, $txn;
        $total_price += $txn->price;
    }
    template 'process-unpaid', {
        all => $txns,
        current => \@current,
        member_id => $current_id,
        total_price => $total_price,
        offset => $orig_offset,
        current_txn_ids => join ',', map { $_->txn_id } @current,
    };
};

post '/unpaid/mark-as-paid' => sub {
    my @txn_ids = split ',', params->{txns} || '';
    my @txns;
    for my $txn_id (@txn_ids) {
        my $txn = Biopay::Transaction->By_id($txn_id);
        next unless $txn;
        next if $txn->paid;
        $txn->paid(1);
        $txn->save;
        push @txns, $txn;
    }
    template 'mark-as-paid', {
        offset => params->{offset},
        txns => [ map { $_->txn_id } @txns ],
    };
};

get '/txns' => sub {
    template 'txns', {
        txns => Biopay::Transaction->All_most_recent,
    };
};

get '/txns/:txn_id' => sub {
    my $txn = Biopay::Transaction->By_id(params->{txn_id});
    template 'txn', { txn => $txn };
};

get '/members' => sub {
    my $members = Biopay::Member->All;
    template 'members', { members => $members };
};

get '/members/create' => sub {
    template 'member-create', { member_id => params->{member_id} };
};

get '/members/:member_id/txns' => sub {
    my $id = params->{member_id};
    my $member = Biopay::Member->By_id($id);
    template 'member-txns', {
        member => $member,
        txns   => Biopay::Transaction->All_for_member($id),
    };
};

get '/members/:member_id/unpaid' => sub {
    my $id = params->{member_id};
    my $member = Biopay::Member->By_id($id);
    template 'member-unpaid', {
        member => $member,
        txns   => Biopay::Transaction->All_unpaid({key => "$id"}),
    };
};

get '/members/:member_id/freeze' => sub {
    my $id = params->{member_id};
    my $member = Biopay::Member->By_id($id);

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

get '/members/:member_id/edit' => sub {
    my $id = params->{member_id};
    my $member = Biopay::Member->By_id($id);
    template 'member-edit', {
        member => $member,
    };
};

post '/members/:member_id/edit' => sub {
    my $id = params->{member_id};
    my $member = Biopay::Member->By_id($id);
    for my $key (qw/first_name last_name phone_num email payment_hash/) {
        # TODO save dates.
        $member->$key(params->{$key});
    }
    $member->save;
    redirect "/members/$id?message=Saved";
};

get '/members/:member_id' => sub {
    my $member = Biopay::Member->By_id(params->{member_id});
    my $msg = params->{message};
    $msg = "A freeze request was sent to the cardlock." if params->{frozen};
    $msg = "An un-freeze request was sent to the cardlock." if params->{thawed};
    template 'member', {
        member => $member,
        message => $msg,
        stats => Biopay::Stats->new,
    };
};

true;
