use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Biopay',
    AUTHOR              => q{Luke Closs <cpan@5thplane.com>},
    VERSION_FROM        => 'lib/Biopay.pm',
    ABSTRACT            => 'Biodiesel Co-op Payment System',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
        'YAML'       => 0,
        'Dancer'     => 1.3051,
	'Dancer::Session::Cookie' => 0,
        'Dancer::Plugin::Auth::RBAC'     => 0,
        'Dancer::Plugin::Bcrypt'     => 0,
        'Dancer::Plugin::Email'     => 0,
        'Data::UUID' => 0,
        'DateTime'   => 0,
        'Email::Date::Format' => 0,
        'URI::Query' => 0,
        'Plack'      => 0,
        'Template'   => 0,
        'AnyEvent::CouchDB' => 0,
        'Try::Tiny' => 0,
        'Moose' => 0,
        'methods' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => '[bB]iopay-*' },
);
