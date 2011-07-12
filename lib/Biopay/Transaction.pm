package Biopay::Transaction;
use Moose;
use methods;

has '_id' => (isa => 'Str', is => 'ro', required => 1);
has 'epoch_time' => (isa => 'Num', is => 'ro', required => 1);
has 'date' => (isa => 'Str', is => 'ro', required => 1);
has 'price_per_litre' => (isa => 'Num', is => 'ro', required => 1);
has 'txn_id' => (isa => 'Num', is => 'ro', required => 1);
has 'paid' => (isa => 'Bool', is => 'ro', required => 1);
has 'Type' => (isa => 'Str', is => 'ro', required => 1);
has 'litres' => (isa => 'Num', is => 'ro', required => 1);
has 'member_id' => (isa => 'Num', is => 'ro', required => 1);
has 'price' => (isa => 'Num', is => 'ro', required => 1);
has 'pump' => (isa => 'Str', is => 'ro', required => 1);

