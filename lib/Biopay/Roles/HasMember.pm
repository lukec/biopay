package Biopay::Roles::HasMember;
use Moose::Role;
use methods;
use Dancer::Plugin::CouchDB;
use Biopay::Member;

requires 'member_id';
has 'member'    => (is => 'ro', isa => 'Object',  lazy_build => 1);

method _build_member { Biopay::Member->By_id($self->member_id) }
