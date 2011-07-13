package Biopay::Resource;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use Dancer ':syntax';

has '_id' => (isa => 'Str', is => 'ro', required => 1);
has '_rev' => (isa => 'Str', is => 'ro', required => 1);

sub By_id {
    my $class = shift;
    my $id    = shift;
    debug "Looking up " . $class->view_base . "/by_id with key=$id";
    my $results = couchdb->view($class->view_base . '/by_id', {
            key => "$id",
        }
    )->recv;
    return $class->new_from_couch($results->{rows}[0]{value});
}

sub All { shift->All_for_view('/by_id', @_) }

sub All_for_view {
    my $class = shift;
    my $view = shift;

    my $results = couchdb->view($class->view_base . $view, @_)->recv;
    return [ map { $class->new_from_couch( $_->{value} ) } @{ $results->{rows} } ];
}

sub new_from_couch {
    my $class = shift;
    my $hash = shift;
    return $class->new($hash);
}

method save {
    couchdb->save_doc($self->as_hash)->recv;
}

