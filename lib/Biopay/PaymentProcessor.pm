package Biopay::PaymentProcessor;
use Dancer::Plugin::Email;
use Dancer ':syntax';
use Moose;
use LWP::UserAgent;
use URI::Query;
use methods;

has 'ua' => (is => 'ro', isa => 'LWP::UserAgent', lazy_build => 1);
has 'payment_args' => (is => 'ro', isa => 'HashRef', lazy_build => 1);

method process {
    my %p = @_;

    my $msg = "Payment: $p{order_num} for \$$p{amount}";
    $msg .= " TEST" if config->{merchant_test};
    print " ($msg) ";
    return (1, undef) if config->{merchant_test};

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
        return (1, "Transaction $p{order_num} is approved.") if $result{trnApproved};

        if ($msg =~ m/Duplicate Transaction/) {
            # This dup is an error, but we'll return success. This only 
            # should happen in testing.
            return (1, "Transaction $p{order_num} was a dup.");
        }
        return (0, "Payment of \$$p{amount} failed. Reason: $msg");
    }
    else {
        return (0, "Payment of \$$p{amount} failed. Reason: " . $resp->status_line);
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

