package biopay;
use Dancer ':syntax';

our $VERSION = '0.1';

get '/' => sub {
    template 'index';
};

get '/member/signup' => sub {
    template 'signup';
};

post '/member/signup' => sub {
    template 'signup_complete';
};

true;
