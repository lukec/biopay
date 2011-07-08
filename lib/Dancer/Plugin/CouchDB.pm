package Dancer::Plugin::CouchDB;
use Dancer ':syntax';
use Dancer::Plugin;
use AnyEvent::CouchDB ();

register couchdb => sub {
    my $conf = plugin_setting;
    return AnyEvent::CouchDB::couchdb($conf->{uri});
};

register_plugin;
1;
