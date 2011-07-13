package Biopay;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Dancer::Plugin::Auth::RBAC;
use Biopay::Transaction;
use Biopay::Member;

our $VERSION = '0.1';

before sub {
    if (!session('user') && request->path_info !~ m{^/login}) {
        var requested_path => request->path_info;
        request->path_info('/login');
    }
};

get '/' => sub { template 'index' };
for my $page (qw(privacy refunds terms)) {
    get "/$page" => sub { template $page };
}

get '/login' => sub {
    template 'login' => { 
        message => join(', ', auth()->errors) || param('message'),
    };
};

post '/login' => sub {
    my $auth = auth(param('username'), param('password'));
    if ($auth->errors) {
        debug "Auth errors: " . join(', ', $auth->errors);;
        return forward "/login", {message => join(', ', $auth->errors)}, { method => 'GET' };
    }
    if ($auth->asa('admin')) {
        session user => { username => param('username') };
        return redirect param('path') || "/admin";
    }
    return forward "/login", {}, { method => 'GET' };
};

get '/logout' => sub {
    session->destroy;
    return forward '/';
};

get '/admin' => sub {
    template 'admin';
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

get '/unpaid/mark-as-paid' => sub {
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

get '/members/:member_id' => sub {
    my $member = Biopay::Member->By_id(params->{member_id});
    template 'member', { member => $member };
};

sub is_admin {
    my $auth = auth();
    if ($auth->errors) {
        debug "ZOMG: " . join(', ', $auth->errors);
        return 0;
    }
    return 1 if $auth->asa('admin');
}

true;
