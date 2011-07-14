package Biopay::Command;
use Moose;
use methods;
use Dancer::Plugin::CouchDB;
use Dancer ':syntax';

extends 'Biopay::Resource';

has 'command' => (is => 'ro', isa => 'Str',       required => 1);
has 'args'    => (is => 'ro', isa => 'HashRef[]', required => 1);

