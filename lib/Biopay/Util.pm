package Biopay::Util;
use Dancer ':syntax';
use Dancer::Plugin::Email;
use Exporter;

our @EXPORT_OK = qw/email_admin/;

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

1;
