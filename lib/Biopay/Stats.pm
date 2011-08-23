package Biopay::Stats;
use Moose;
use Dancer ':syntax';
use Dancer::Plugin::CouchDB;
use methods;

has 'fuel_sold_alltime' => (is => 'ro', isa => 'Num', lazy_build => 1);
has 'fuel_sales'        => (is => 'ro', isa => 'Num', lazy_build => 1);
has 'active_members'    => (is => 'ro', isa => 'Num', lazy_build => 1);

method _build_fuel_sold_alltime { view('txns/litres_by_member', @_) }
method _build_active_members    { view('members/active_count', @_) }
method _build_fuel_sales        { view('txns/fuel_sales', @_) }

method taxes_paid { sprintf '%.02f', $self->fuel_sold_alltime * 0.29 }
method co2_reduction { int( $self->fuel_sold_alltime * 1.94 ) }

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
