package Biopay::Cardlock;
use Moose;
use methods;
use Control::CLI;
use Math::Round qw/round/;
use DateTime;

has 'cli' => (is => 'ro', isa => 'Control::CLI', lazy_build => 1);
has 'fetch_price_cb' => (is => 'ro', isa => 'CodeRef', required => 1);

method _build_cli {
    my $cli = new Control::CLI('/dev/ttyS0');
    $cli->connect(
        BaudRate  => 9600,
        Parity    => 'none',
        DataBits  => 8,
        StopBits  => 1,
        Handshake => 'none',
    );
    return $cli;
}

method BUILD {
    $self->cli->put("\cC");
    if ($self->clean_read('?') =~ m/last mag card read/) {
        print "Already logged in ...\n";
    }
    else {
        $self->clean_read('P');
        $self->clean_read("MASTER\r");
        my $output = $self->clean_read('?');
        unless ($output =~ m/last mag card/) {
            die "Could not log in - received '$output'";
        }
    }
}

method clean_read {
    my $text = shift;
    $self->cli->put($text);
    my $output = $self->cli->readwait(
	Blocking => 1,
	Read_attempts => 10,
    );
    # warn "Received: '$output'\n";
    return $output;
}


method recent_transactions {
    my $lines = $self->clean_read('B');
    my @records;
    my $price;
    for my $line (split "\r\n", $lines) {
	chomp $line;
	next unless $line =~ m/^\d+,/;
	my @fields = split ",", $line;

#  0    1    2        3     4 5 6 7      8       9
# 01,0118,0204,07/08/11,10:50,1,1,1,XXXXXX,0029.98,XXXXXX,XXXXXX,XXXXXX
	my $dt = to_datetime($fields[3], $fields[4]);
        # Lazy load the latest fuel price
        $price ||= $self->fetch_price_cb->();
	my $txn = {
	    Type => 'txn',
	    txn_id => to_num($fields[1]),
	    member_id => to_num($fields[2]),
	    epoch_time => $dt->epoch,
	    _id => "txn:$fields[1]-" . $dt->ymd . '-' . $fields[4],
	    litres => to_num($fields[9]),
	    pump => "RA",
	    date => "$dt",
	    paid => 0,
	    price_per_litre => $price,
	};
	unless ($txn->{member_id}) {
	    warn "No member_id on txn_id:$txn->{txn_id} - skipping.";
	    next;
	}
	$txn->{price} = sprintf "%01.2f", 
                        round($txn->{litres} * $price * 100) / 100;
	$txn->{paid} = 1 if $txn->{price} eq "0.00";
	$txn->{as_string} = "txn:$txn->{txn_id} "
	    . "member:$txn->{member_id} litres:$txn->{litres} $dt";
	push @records, $txn;
    }
    return \@records;
}

sub to_num {
    my $val = shift;
    $val =~ s/^0+//;
    $val = "0" . $val if $val =~ m/^\./;
    return $val;
}

sub to_datetime {
    my ($date, $time) = @_;
    my ($m, $d, $y) = split '/', $date;
    my ($h, $min) = split ':', $time;
    $y += 2000;
    my $dt = DateTime->new(
	    year => $y, month => $m, day => $d,
	    hour => $h, minute => $min,
	    );
    $dt->set_time_zone('America/Vancouver');
    return $dt;
}

