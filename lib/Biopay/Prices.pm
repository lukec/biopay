package Biopay::Prices;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use Dancer ':syntax';

method fuel_price {
    my $cb = shift;
    if ($cb) {
        return $self->doc( sub {
                my $doc = shift;
                $cb->($doc->{price_per_litre});
            }
        );
    }
    return $self->doc->{price_per_litre} || die "No price per litre found!";
}

method set_fuel_price {
    my $doc = $self->doc;
    $doc->{price_per_litre} = shift;
    couchdb->save_doc($doc);
}

method doc {
    my $cb = shift;

    my $cv = couchdb->open_doc("prices");
    if ($cb) {
        return $cv->cb(
            sub {
                my $cv2 = shift;
                my $doc = $cv2->recv;
                $cb->($doc);
            }
        );
    }

    my $doc = eval { $cv->recv };
    if ($@) {
	if ($@ =~ m/^404/) {
	    die "Could not load the 'prices' doc! Make sure it exists.";
	}
	else { die "Failed to load 'prices' doc: $@" };
    }
    return $doc;
}
