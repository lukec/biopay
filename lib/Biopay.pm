package Biopay;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use Dancer::Plugin::Auth::RBAC;

our $VERSION = '0.1';

get '/' => sub {
    template 'index';
};

get '/login' => sub {
    redirect '/admin' if is_admin();
    template 'login-form' => { message => join(', ', auth()->errors) || param('message') };
};

post '/login' => sub {
    my $auth = auth(param('username'), param('password'));
    if ($auth->errors) {
        return forward "/login", {message => join(', ', $auth->errors)}, { method => 'GET' };
    }
    if ($auth->asa('admin')) {
        return redirect "/admin";
    }
    return forward "/login", {}, { method => 'GET' };
};

get '/logout' => sub {
    session->destroy;
    return forward '/';
};

get '/admin' => sub {
    return redirect '/login' if is_admin();
    template 'admin-page';
};

sub is_admin {
    my $auth = auth();
    return 0 if $auth->errors;
    return 1 if $auth->asa('admin');
}

true;
