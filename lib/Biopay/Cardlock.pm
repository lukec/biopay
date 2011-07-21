package Biopay::Cardlock;
use Dancer qw/:syntax/;
use Moose;
use methods;
use Control::CLI;
use Math::Round qw/round/;
use DateTime;

has 'cli' => (is => 'ro', isa => 'Control::CLI', lazy_build => 1);
has 'fetch_price_cb' => (is => 'ro', isa => 'CodeRef', required => 1);

method _build_cli {
    my $cli = Control::CLI->new(
        Use => '/dev/ttyS0',
        Dump_log => 'cardlock.log',
    );
    $cli->connect(
        BaudRate  => 9600,
        Parity    => 'none',
        DataBits  => 8,
        StopBits  => 1,
        Handshake => 'none',
    );
    return $cli;
}

method login {
    $self->cli->put("\cC"); # Break any current input
    $self->clean_read("^");   # Logout, or no-op
    $self->clean_read('P');
    $self->clean_read("MASTER\r");
    my $output = $self->clean_read('?');
    unless ($output =~ m/last mag card/) {
        die "Could not log in - received '$output'";
    }
}

method fetch_PIN {
    my $card = shift;
    $self->login;
    $self->clean_read("E");
    my $output = $self->clean_read("$card\n\r");
    $self->clean_read("\n\r");
    if ($output =~ m/PIN # \(\s*(\d+)\)/) {
        return $1;
    }
    return 0;
}

method set_PIN {
    my $card = shift;
    my $new_pin = shift;
    $self->login;
    $self->clean_read("E");
    $self->clean_read("$card\n\r");
    $self->clean_read("$new_pin\n\r");
    $self->clean_read("\n\r");
}

method clean_read {
    my $text = shift;
    $self->cli->put($text);
    my $output = $self->cli->readwait(
	Blocking => 1,
	Read_attempts => 15,
    );
    $output =~ s/\r/\n/g;
    $output =~ s/\n\n/\n/g;
    # warn "CLI: put '$text', GOT: '$output'\n";
    return $output;
}

method recent_transactions {
    $self->login;
    my $lines = $self->clean_read('B');
    return [] if $lines =~ m/ - empty/;
    my @records;
    my $last_txn_seen = 0;
    for my $line (split "\n", $lines) {
        debug "Received from cardlock: '$line'";
        my $txn = $self->parse_line($line);
        next unless $txn;
        $last_txn_seen = $txn->{txn_id};
	push @records, $txn;
    }

    if ($last_txn_seen) {
        my $next_txn = $last_txn_seen + 1;
        debug "Marking $next_txn as the next transaction on the cardlock\n";
        warn $self->clean_read("X$next_txn\n\r");
    }
    return \@records;
}

method parse_line {
    my $line = shift;
    chomp $line;
    return unless $line =~ m/^\d+,/;
    my @fields = split ",", $line;

#  0    1    2        3     4 5 6 7      8       9
# 01,0118,0204,07/08/11,10:50,1,1,1,XXXXXX,0029.98,XXXXXX,XXXXXX,XXXXXX
    my $dt = to_datetime($fields[3], $fields[4]);
    # Lazy load the latest fuel price
    my $price = $self->fetch_price_cb->();
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
    unless ($txn->{member_id} and $txn->{member_id} =~ m/^\d+$/) {
        debug "No member_id on txn_id:$txn->{txn_id} - skipping.";
        return;
    }
    $txn->{price} = sprintf "%01.2f", 
                    round($txn->{litres} * $price * 100) / 100;
    $txn->{paid} = 1 if $txn->{price} eq "0.00";
    $txn->{as_string} = "txn:$txn->{txn_id} "
        . "member:$txn->{member_id} litres:$txn->{litres} $dt";
    return $txn;
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

