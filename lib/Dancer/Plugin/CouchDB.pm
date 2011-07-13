package Dancer::Plugin::CouchDB;
use Dancer ':syntax';
use Dancer::Plugin;
use AnyEvent::CouchDB ();

sub couch_uri {
    my $conf = plugin_setting;
    return $conf->{uri}
}

register couch_uri => \&couch_uri;

register couchdb => sub {
    return AnyEvent::CouchDB::couchdb(couch_uri());
};

register_plugin;
1;
