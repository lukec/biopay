package Biopay::Stats;
use Moose;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use methods;

method fuel_sold_alltime { view('txns/litres_by_member', @_) }
method active_members    { view('members/active_count', @_) }
method fuel_sales        { view('txns/fuel_sales', @_) }

sub view {
    my ($view, @args) = @_;
    if (exists $args[0] and not ref($args[0])) {
        # Assume it's a key
        @args = ( { key => "$args[0]" } );
    }

    my $result = couchdb->view($view, @args)->recv;
    return int $result->{rows}[0]{value};
}

method as_hash {
    return { map { $_ => $self->$_ } qw/fuel_sold_alltime active_members/ };
}
