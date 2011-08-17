package Biopay::Util;
use Dancer ':syntax';
use Dancer::Plugin::Email;
use DateTime;
use base 'Exporter';

our @EXPORT_OK = qw/email_admin email_board random_pin now_dt host/;

sub email_admin {
    my ($subj, $body) = @_;
    debug "Cardlock error: $subj";
    email {
        to => config->{sysadmin_email},
        from => config->{email_from},
        subject => "Cardlock error: $subj",
        message => $body || 'Sorry!',
    };
};

sub email_board {
    my ($subj, $body) = @_;
    debug "Emailing board: $subj";
    email {
        to => 'vancouver-biodiesel-board@googlegroups.com',
        from => config->{email_from},
        subject => "Biopay: $subj",
        message => $body,
    };
};

my %bad_pins = map { $_ => 1 }
    qw/0000 1111 2222 3333 4444 5555 6666 7777 8888 9999
       1234 2580 5683 0852 1212/;
sub pin_is_ok {
    my $pin = shift;
    return $bad_pins{$pin} ? 0 : 1;
}

sub random_pin {
    while(1) {
        my $pin = sprintf "%04d", int(rand()*10000);
        return $pin if pin_is_ok($pin);
    }
}

sub now_dt {
    my $dt = DateTime->now;
    $dt->set_time_zone('America/Vancouver');
    return $dt;
}

sub host {
    return 'http://' . request->host
        if request && request->host =~ m/localhost/;
    # Otherwise use the bona fide dotcloud SSL cert
    return 'https://biopay.ssl.dotcloud.com';
}

1;
