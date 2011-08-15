package Biopay::Resource;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use Dancer ':syntax';
use Carp qw/croak/;
use Try::Tiny;

has '_id' => (isa => 'Str', is => 'ro', required => 1);
has '_rev' => (isa => 'Str', is => 'ro', required => 1);
has 'Type' => (isa => 'Str', is => 'ro', required => 1);

sub By_id { shift->By_view('by_id', @_) }
sub By_view {
    my $class = shift;
    my $view  = shift;
    my $id    = shift or croak "You must specify an ID to look up!";
    my $cb    = shift;
    my $cv = couchdb->view($class->view_base . '/' . $view, { key => "$id" });
    if ($cb) {
        $cv->cb(
            sub {
                my $cv2 = shift;
                my $results = $cv2->recv;
                my $val = $results->{rows}[0]{value};
                my $obj = $val ? $class->new_from_hash($val) : undef;
                return $cb->($obj);
            }
        );
    }
    else {
        my $results = $cv->recv;
        my $hash = $results->{rows}[0]{value};
        return undef unless $hash;
        return $class->new_from_hash($hash);
    }
}

sub All { shift->All_for_view('/by_id', @_) }

sub All_for_view {
    my $class = shift;
    my $view = shift;
    my $cb;
    $cb = shift if ref($_[0]) eq 'CODE';

    my $result_mapper = sub {
        my $result = shift;
        return [ map { $class->new_from_hash($_->{value}) }
                @{ $result->{rows} } ];
    };
    my $cv = couchdb->view($class->view_base . $view, @_);
    if ($cb) {
        $cv->cb(
            sub {
                my $cv2 = shift;
                $cb->( $result_mapper->( $cv2->recv ) );
            }
        );
    }
    else {
        return $result_mapper->($cv->recv);
    }
}

sub new_from_hash {
    my $class = shift;
    my $hash = shift;
    return $class->new($hash);
}

method save {
    my %p = @_;
    my $cv = couchdb->save_doc($self->as_hash);
    if ($p{success_cb} or $p{error_cb}) {
        $cv->cb(
            sub {
                my $cv2 = shift;
                try {
                    my $res = $cv2->recv;
                    $self->{_rev} = $res->{rev};
                    $p{success_cb}->($res) if $p{success_cb};
                }
                catch {
                    $p{error_cb}->($_);
                };
            }
        );
    }
    else {
        return $cv->recv;
    }
}

