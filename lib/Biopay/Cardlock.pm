package Biopay::Cardlock;
use Dancer qw/:syntax/;
use Biopay::Util qw/email_admin/;
use Moose;
use methods;
use Control::CLI;
use Math::Round qw/round/;
use DateTime;
use Try::Tiny;

has 'cli' => (is => 'ro', isa => 'Control::CLI', lazy_build => 1);
has 'fetch_price_cb' => (is => 'ro', isa => 'CodeRef', required => 1);
has 'device' => (is => 'ro', isa => 'Str', default => '/dev/ttyS0');

method exists { -r $self->device }

method _build_cli {
    my $cli = Control::CLI->new(
        Use => $self->device,
        # Dump_log => 'cardlock.log',
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
    my $try_again = shift // 1;
    try {
        $self->cli->put("\cc");    # Break any current input
        my $output = $self->clean_read("?\r");
        if ($output =~ m/Password: /) {
            $self->clean_read("MASTER\r");
        }
        elsif ($output =~ m/last mag card/) {
            return;
        }
        else {
            $self->cli->put("P");
            $output = $self->clean_read("MASTER\r");
            if ($output =~ m/\*+\?/) {
                debug "Looks like the cardlock is locked up. Resetting.";
                $self->cli->put("\cc");    # Break out of password mode
                if ($self->clean_read("R") =~ m/Reset CardMaster/) {
                    $output = $self->clean_read("Y");
                    die "Couldn't reset cardlock!"
                        unless $output =~ m/Power up/;
                }
                else {
                    die "Couldn't issue reset command!";
                }
            }
        }

        # Verify we are logged in:
        $output = $self->clean_read("?\r");
        unless ($output =~ m/last mag card/) {
            die "Not at the menu after we logged in!";
        }
    }
    catch {
        email_admin("Cardlock error: $_",
            "I had a problem during login, sorry.");
    };
}

method fetch_PIN {
    my $card = shift;
    unless ($self->exists) {
        debug "No cardlock, but I would have fetch_PIN($card)";
        return "1234";
    }
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
    unless ($self->exists) {
        debug "No cardlock, but I would have set_PIN($card, $new_pin)";
        return;
    }
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

my $last_mark;
method recent_transactions {
    $self->login;
    my $lines = $self->clean_read('B');
    return [] if $lines =~ m/ - empty/;
    my @records;
    my $next_mark = 0;
    for my $line (split "\n", $lines) {
        # debug "Received from cardlock: '$line'";
        my $txn = $self->parse_line($line);
        next unless $txn;
        $next_mark = $txn->{cardlock_txn_id}+1;
	push @records, $txn;
    }

    if ($next_mark and $next_mark != ($last_mark||0)) {
        $self->set_mark($next_mark);
        $last_mark = $next_mark;
    }
    return \@records;
}

method set_mark {
    my $mark = shift;
    print "X${mark}";
    $self->clean_read("X$mark\n\r");
}

method parse_line {
    my $line = shift;
    chomp $line;
    return unless $line =~ m/^\d+,/;
    my @fields = split ",", $line;

#  0    1    2        3     4 5 6 7      8       9
# 01,0118,0204,07/08/11,10:50,1,1,1,xxxxxx,0029.98,xxxxxx,xxxxxx,xxxxxx
    
    # Do not process transactions which are In Progress
    # Field 5 Values:
    # 0  In Progress – sale not complete 
    # 1 Normal Transaction – sale completed normally 
    # 2 time out - user 
    # 3 time out – no pulses received 
    # 4 time out – no pump handle  
    # 5 sale terminated – by quantity limit 
    # 6 invalid memory – product code, etc 
    # 7 Invalid card, card expired, bad card read, invalid PIN 
    # 8 Invalid hose or product (wrong selection, or invalid read of product) 
    # 9 Tally full (no room for more transactions, exceed memory 
    # limit, or “x” command is marked incorrectly) 
    # A Power Fail, lost AC connection 
    # B Power Fail while dispensing is in progress 
    # C Entering manual mode 
    # D Leaving manual Mode
    return unless $fields[5] > 0;

    my $dt = to_datetime($fields[3], $fields[4]);
    # Lazy load the latest fuel price
    my $price = $self->fetch_price_cb->();
    my $id = $dt->ymd('-') . '-' . to_num($fields[1]);
    my $txn = {
        Type => 'txn',
        _id => "txn:$id",
        txn_id => $id,
        cardlock_txn_id => $fields[1],
        member_id => to_num($fields[2]),
        epoch_time => $dt->epoch,
        age_in_sec => time() - $dt->epoch,
        litres => to_num($fields[9]),
        pump => "RA",
        date => "$dt",
        paid => 0,
        price_per_litre => $price,
        ($fields[5] > 1 ? (error_code => $fields[5]) : ()),
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

