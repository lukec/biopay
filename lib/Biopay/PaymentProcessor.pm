package Biopay::PaymentProcessor;
use Moose;
use methods;
use Dancer::Plugin::Email;
use Dancer ':syntax';
use LWP::UserAgent;
use URI::Query;

has 'ua' => (is => 'ro', isa => 'LWP::UserAgent', lazy_build => 1);
has 'payment_args' => (is => 'ro', isa => 'HashRef', lazy_build => 1);

method process {
    my %p = @_;

    debug "Sending payment request $p{order_num} for \$$p{amount} for "
        . "hash $p{hash}";
    if (config->{merchant_test}) {
        debug "Merchant test in effect, no transaction sent to Beanstream!";
        return;
    }

    my $resp = $self->ua->post(
        'https://www.beanstream.com/scripts/process_transaction.asp',
        [
            %{ $self->payment_args },
            trnOrderNumber => $p{order_num},
            trnAmount => $p{amount},
            customerCode => $p{hash},
        ],
    );
    if ($resp->code == 200) {
        my $qs = URI::Query->new($resp->content);
        my %result = $qs->hash;
        (my $msg = $result{messageText}||'') =~ s/\+/ /g;
        return "Transaction $p{order_num} is approved." if $result{trnApproved};

        if ($msg =~ m/Duplicate Transaction/) {
            # This dup is an error, but we'll return success. This only 
            # should happen in testing.
            return "Transaction $p{order_num} was a dup.";
        }
        die "Payment of \$$p{amount} failed ($p{order_num}). Error: $msg\n";
    }
    else {
        die "Payment of \$$p{amount} failed ($p{order_num}). Error: "
            . $resp->status_line . "\n";
    }
}

method _build_ua { LWP::UserAgent->new }

method _build_payment_args {
    return {
        merchant_id => config->{merchant_id},
        username => config->{merchant_username},
        password => config->{merchant_password},
        requestType => 'BACKEND',
    }
}

