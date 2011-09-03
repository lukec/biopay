package Biopay::Stats;
use Dancer ':syntax';
use Moose;
use Dancer::Plugin::CouchDB;
use methods;

has 'fuel_sold_alltime' => (is => 'ro', isa => 'Num', lazy_build => 1);
has 'active_members'    => (is => 'ro', isa => 'Num', lazy_build => 1);

method _build_active_members    { view('members/active_count', @_) }
method _build_fuel_sold_alltime { view('txns/litres_by_member' ) }

method fuel_sales      { view('txns/fuel_sales', @_) }
method co2_reduction   { int($self->fuel_sold_alltime * 1.94) }
method fuel_for_member { view('txns/litres_by_member', @_) }
method taxes_paid      {
    sprintf '%.02f', 
        $self->fuel_sold_alltime * 0.24     # Motor Fuels Tax
        + $self->fuel_sold_alltime * 0.0639 # Carbon Tax
        + $self->fuel_sales * 0.12          # HST
}



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
