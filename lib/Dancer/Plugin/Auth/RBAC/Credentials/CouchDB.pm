# ABSTRACT: Dancer::Plugin::Auth::RBAC authentication via CouchDB!

package Dancer::Plugin::Auth::RBAC::Credentials::CouchDB;
BEGIN {
  $Dancer::Plugin::Auth::RBAC::Credentials::CouchDB = '1.0';
}

use strict;
use warnings;
use base qw/Dancer::Plugin::Auth::RBAC::Credentials/;
use Dancer::Plugin::CouchDB;
use Dancer::Plugin::Bcrypt;

sub authorize {
    my ($self, $options, @arguments) = @_;
    my ($login, $password) = @arguments;
    
    my $settings = $Dancer::Plugin::Auth::RBAC::settings;
    if ($login) {
        # authorize a new account using supplied credentials
        unless ($password) {
            $self->errors('login and password are required');
            return 0;
        }
        
        my $db = couchdb();
        my $users = $db->view('auth/by_username', { key => "$login" })->recv;
        my $doc = $users->{rows}[0];
        my $user = defined $doc ? $doc->{value} : undef;
        unless ($user) {
            $self->errors("Sorry, I couldn't find that account.");
            return 0;
        }
        unless ($user->{password}) {
            $self->errors("No password has been set for this user.");
            return 0;
        }
        if (bcrypt_validate_password($password, $user->{password})) {
            my @roles = ( map { $_ =~ s/^\s+|\s+$//; $_  }
                            split /\,/, $user->{roles} || '' );
            my %roles = map { $_ => 1 } @roles;
            my $session_data = {
                id    => $user->{id},
                username  => $user->{username},
                roles => \@roles,
                admin => $roles{admin},
                error => []
            };
            return $self->credentials($session_data);
        }
        else {
            $self->errors('login and/or password is invalid');
            return 0;
        }

    }
    else {
        # check if current user session is authorized
        my $user = $self->credentials;
        if (($user->{id} || $user->{login}) && !@{$user->{error}}) {
            return $user;
        }
        else {
            $self->errors('you are not authorized', 'your session may have ended');
            return 0;
        }
    }
    return 0;
}

1;

__END__
=pod

=head1 NAME

Dancer::Plugin::Auth::RBAC::Credentials::CouchDB - Dancer::Plugin::Auth::RBAC authentication via CouchDB!

=head1 VERSION

version 1.0

=head1 SYNOPSIS

    # in your app code
    my $auth = auth($login, $password);
    if ($auth) {
        # login successful
    }
    
    # use your own encryption (if the user account password is encrypted)
    my $auth = auth($login, encrypt($password));
    if ($auth) {
        # login successful
    }

=head1 DESCRIPTION

Dancer::Plugin::Auth::RBAC::Credentials::CouchDB uses your CouchDB database connection 
as the application's user management system.

=head1 METHODS

=head2 authorize

The authorize method (found in every authentication class) validates a user against
the defined datastore using the supplied arguments and configuration file options.

=head1 CONFIGURATION

    plugins:
      CouchDB:
        uri: http://yourcompany.com/couch
      Auth::RBAC:
        credentials:
          class: CouchDB

Please see L<Dancer::Plugin::CouchDB> for a list of all available connection
options and arguments.

=head1 COUCHDB SETUP

    # A user document is expected to have a "Type" field set to the string "user".
    # It also must have "username", "password", and "roles" text fields.
    
    {
       "_id": "754827e65e0eaa8805f8460ac50012d1",
       "_rev": "2-0b43079a339a00c74e14ec3712299614",
       "username": "lukec",
       "password": "test",
       "roles": "admin",
       "type": "user"
    }
    
    # A view must also be created to query by username.  It should be called
    # _design/auth/by_username and the key should be the username.  Example:

    {
       "_id": "_design/auth",
       "_rev": "10-82561bb3620058b0be9a2caaa1109ea7",
       "language": "javascript",
       "views": {
           "by_username": {
               "map": "function(doc) { if (doc.Type == 'user')  emit(doc.username, doc) }"
           }
       }
    }

    # Note! this module is not responsible for creating user accounts, it simply
    # provides a consistant authentication framework

=head1 AUTHOR

  Luke Closs <cpan@5thplane.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Luke Closs.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

