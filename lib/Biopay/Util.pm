package Biopay::Util;
use Dancer ':syntax';
use Dancer::Plugin::Email;
use DateTime;
use Digest::SHA1 qw/sha1_hex/;
use base 'Exporter';

our @EXPORT_OK = qw/email_admin email_board random_pin now_dt host
                    beanstream_url beanstream_response_is_valid queue_email/;

sub email_admin {
    my ($subj, $body) = @_;
    debug "$0 error: $subj";
    queue_email({
        to => config->{sysadmin_email},
        subject => "Cardlock error: $subj",
        message => $body || 'Sorry!',
    });
};

sub email_board {
    my ($subj, $body) = @_;
    my $to = config->{board_email} || die "No board_email configured!";
    queue_email({
        to => config->{board_email},
        subject => "Biopay: $subj",
        message => $body,
    });
};

sub queue_email {
    my $msg = shift;

    if (request() and request()->path_info) {
        debug "Just queued $msg->{subject} email to $msg->{to}";
        Biopay::Command->Create(
            command => 'send-email',
            msg => $msg,
        );
    }
    else {
        print " (Sending '$msg->{subject}' email to $msg->{to}) ";
        email {
            from => config->{email_from},
            %$msg,
        };
    }
}

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
    return 'https://vancouverbiodiesel.org';
}

sub beanstream_url {
    my $query_str = shift;
    my $base = "https://www.beanstream.com/scripts/PaymentProfile/webform.asp?";

    if (config->{merchant_hash_key}) {
        my $hash_value = sha1_hex($query_str . config->{merchant_hash_key});
        $query_str .= "&hashValue=$hash_value";
    }

    unless (beanstream_response_is_valid($query_str)) {
        die "Could not decode our own hash! - $query_str";
    }
    return $base . $query_str;
}

sub beanstream_response_is_valid {
    my $uri = shift || request->request_uri;
    $uri =~ s/.+?\?//;
    (my $query_str = $uri) =~ s#(.+?)&hashValue=([0-9a-fA-F]+).*$#$1#;
    my $hv = $2;
    debug "Checking beanstream response";
    unless ($query_str and $hv) {
        debug "Couldn't extract the hashValue from the query_string in $uri";
        return 0;
    }

    debug "Request uri  = $uri";
    debug "Query string = $query_str";
    debug "Merchant Key = @{[config->{merchant_hash_key}]}";
    my $q_hash = sha1_hex($query_str . config->{merchant_hash_key});
    if ($q_hash eq $hv) {
        return 1;
    }

    debug "Computed hash '$q_hash' does not match hashValue '$hv'";
    return 0;
}

1;
