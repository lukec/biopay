package Biopay::Resource;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use Dancer ':syntax';

has '_id' => (isa => 'Str', is => 'ro', required => 1);
has '_rev' => (isa => 'Str', is => 'ro', required => 1);
has 'Type' => (isa => 'Str', is => 'ro', required => 1);

sub By_id {
    my $class = shift;
    my $id    = shift;
    my $cb    = shift;
    my $cv = couchdb->view($class->view_base . '/by_id', {
            key => "$id",
        }
    );
    if ($cb) {
        $cv->cb(
            sub {
                my $cv2 = shift;
                my $results = $cv2->recv;
                my $obj = $class->new_from_couch($results->{rows}[0]{value});
                return $cb->($obj);
            }
        );
    }
    else {
        my $results = $cv->recv;
        my $hash = $results->{rows}[0]{value};
        return undef unless $hash;
        return $class->new_from_couch($hash);
    }
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
    my $cb = shift;
    my $cv = couchdb->save_doc($self->as_hash);
    if ($cb) {
        $cv->cb(
            sub {
                my $cv2 = shift;
                my $res = $cv2->recv;
                $cb->($res);
            }
        );
    }
    else {
        return $cv->recv;
    }
}

