package Biopay::Resource;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;

sub By_id {
    my $class = shift;
    my $id    = shift;
    my $results = couchdb->view($class->view_base . '/by_id', {
            key => "$id",
        }
    )->recv;
    return $class->new_from_couch($results);
}

sub All { shift->All_for_view('/by_id', @_) }

sub All_for_view {
    my $class = shift;
    my $view = shift;

    my $results = couchdb->view($class->view_base . $view, @_)->recv;
    return [ map { $class->new( $_->{value} ) } @{ $results->{rows} } ];
}

sub new_from_couch { $_[0]->new( $_[1]->{rows}[0]{value} ) }
