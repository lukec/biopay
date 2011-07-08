package Dancer::Plugin::CouchDB;
use Dancer ':syntax';
use Dancer::Plugin;
use AnyEvent::CouchDB ();

register couch => sub {
    my $conf = plugin_setting;
    return AnyEvent::CouchDB::couch($conf->{uri});
};

register_plugin;
1;
