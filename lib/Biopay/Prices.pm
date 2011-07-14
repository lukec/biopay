package Biopay::Prices;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use Dancer ':syntax';

has 'doc' => (is => 'ro', isa => 'HashRef',     lazy_build => 1);

method fuel_price {
    return $self->doc->{price_per_litre} || die "No price per litre found!";
}

method _build_doc {
    my $doc = eval { couchdb->open_doc("prices")->recv };
    if ($@) {
	if ($@ =~ m/^404/) {
	    die "Could not load the 'prices' doc! Make sure it exists.";
	}
	else { die "Failed to load 'prices' doc: $@" };
    }
    return $doc;
}
