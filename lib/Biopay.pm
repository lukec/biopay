package Biopay;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Dancer::Plugin::Auth::RBAC;
use Biopay::Transaction;

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

get '/txns/:txn_id' => sub {
    my $txn = Biopay::Transaction->By_id(params->{txn_id});
    template 'txn', { txn => $txn };
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
