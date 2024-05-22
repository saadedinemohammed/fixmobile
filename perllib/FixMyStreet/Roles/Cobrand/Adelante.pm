package FixMyStreet::Roles::Cobrand::Adelante;

use Moo::Role;
use Try::Tiny;
use URI::Escape;
use Integrations::Adelante;

requires 'waste_cc_payment_reference';

sub waste_cc_has_redirect { 1 }

sub waste_cc_get_redirect_url {
    my ($self, $c, $type) = @_;

    my $payment = Integrations::Adelante->new({
        config => $self->feature('payment_gateway')->{adelante}
    });

    my $p = $c->stash->{report};
    #my $uprn = $p->get_extra_field_value('uprn');

    my $amount = $p->get_extra_field_value( 'pro_rata' );
    unless ($amount) {
        $amount = $p->get_extra_field_value( 'payment' );
    }
    my $admin_fee = $p->get_extra_field_value('admin_fee');

    my $redirect_id = mySociety::AuthToken::random_token();
    $p->update_extra_metadata(redirect_id => $redirect_id);

    my $fund_code = $payment->config->{fund_code};
    my $cost_code = $payment->config->{cost_code};

    if ($type eq 'bulky') {
        $fund_code = $payment->config->{bulky_fund_code} || $fund_code;
        $cost_code = $payment->config->{bulky_cost_code} || $cost_code;
    } elsif ($type eq 'request') {
        $cost_code = $payment->config->{request_cost_code} || $cost_code;
    }

    my $address = $c->stash->{property}{address};
    my $ref = $self->waste_cc_payment_reference($p);

    my @items = ({
        amount => $amount,
        cost_code => $cost_code,
        reference => $ref,
    });
    if ($admin_fee) {
        push @items, {
            amount => $admin_fee,
            cost_code => $payment->config->{cost_code_admin_fee},
            reference => '?',
        };
    }
    my $result = try {
        $payment->pay({
            returnUrl => $c->uri_for_action('/waste/pay_complete', [ $p->id, $redirect_id ] ) . '',
            reference => $ref . '-' . time(), # Has to be unique
            name => $p->name,
            email => $p->user->email,
            phone => $p->user->phone,
            #uprn => $uprn,
            address => $address,
            items => \@items,
            staff => $c->stash->{staff_payments_allowed} eq 'cnp',
            fund_code => $fund_code,
        });
    } catch {
        $c->stash->{error} = $_;
        return undef;
    };
    return unless $result;

    $p->update_extra_metadata(scpReference => $result->{UID});
    return $result->{Link};
}

sub cc_check_payment_status {
    my ($self, $reference) = @_;

    my $payment = Integrations::Adelante->new(
        config => $self->feature('payment_gateway')->{adelante}
    );

    my ($data, $error);

    my $resp = try {
        $payment->query({
            reference => $reference,
        });
    } catch {
        $error = $_;
    };
    return ($error, undef) if $error;

    if ($resp->{Status} eq 'Authorised') {
        $data = $resp;
    } else {
        $error = $resp->{Status};
    }

    return ($error, $data);
}

sub garden_cc_check_payment_status {
    my ($self, $c, $p) = @_;

    # need to get some ID Things which I guess we stored in pay
    my $reference = $p->get_extra_metadata('scpReference');
    $c->detach( '/page_error_404_not_found' ) unless $reference;

    my ($error, $data) = $self->cc_check_payment_status($reference);
    if ($error) {
        $c->stash->{error} = $error;
        return undef;
    }

    for (qw(MPOSID AuthCode)) {
        $p->update_extra_field({ name => $_, value => $data->{$_} }) if $data->{$_};
    }
    $p->update;

    # create sub in echo
    return $data->{PaymentID};
}

1;
