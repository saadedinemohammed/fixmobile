package FixMyStreet::Roles::Bottomline;

use Moo::Role;
use strict;
use warnings;
use Integrations::Bottomline;
with 'FixMyStreet::Roles::DDProcessor';

has paymentDateField => (
    is => 'ro',
    default => 'paymentDate',
);

has paymentTypeField => (
    is => 'ro',
    default => 'transactionCode',
);

has oneOffReferenceField => (
    is => 'ro',
    default => 'altReference',
);

has referenceField => (
    is => 'ro',
    default => 'reference',
);

has statusField => (
    is => 'ro',
    default => 'status',
);

has paymentTakenCode => (
    is => 'ro',
    default => 'SUCCESS',
);

# XXX
has cancelledDateField => (
    is => 'ro',
    default => 'lastUpdated',
);

has cancelReferenceField => (
    is => 'ro',
    default => 'reference',
);

sub get_config {
    return shift->feature('bottomline');
}

sub get_integration {
    my $self = shift;
    my $config = $self->feature('bottomline');
    my $i = Integrations::Bottomline->new({
        config => $config
    });

    return $i;
}

sub waste_payment_type {
    my ($self, $type, $ref) = @_;

    my ($sub_type, $category);
    if ( $type eq 2 ) {
        $category = 'Garden Subscription';
        $sub_type = $self->waste_subscription_types->{New};
    } elsif ( $type eq 1 ) {
        $category = 'Garden Subscription';
        # XXX
        if ( $ref ) {
            $sub_type = $self->waste_subscription_types->{Amend};
        } else {
            $sub_type = $self->waste_subscription_types->{Renew};
        }
    }

    return ($category, $sub_type);
}

1;
