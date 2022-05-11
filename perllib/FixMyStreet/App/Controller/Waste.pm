package FixMyStreet::App::Controller::Waste;
use Moose;
use namespace::autoclean;

BEGIN { extends 'FixMyStreet::App::Controller::Form' }

use utf8;
use Lingua::EN::Inflect qw( NUMWORDS );
use List::Util qw(any);
use FixMyStreet::App::Form::Waste::UPRN;
use FixMyStreet::App::Form::Waste::AboutYou;
use FixMyStreet::App::Form::Waste::Request;
use FixMyStreet::App::Form::Waste::Request::Peterborough;
use FixMyStreet::App::Form::Waste::Report;
use FixMyStreet::App::Form::Waste::Problem;
use FixMyStreet::App::Form::Waste::Enquiry;
use FixMyStreet::App::Form::Waste::Garden;
use FixMyStreet::App::Form::Waste::Garden::Modify;
use FixMyStreet::App::Form::Waste::Garden::Cancel;
use FixMyStreet::App::Form::Waste::Garden::Renew;
use FixMyStreet::App::Form::Waste::Garden::Sacks::Purchase;
use FixMyStreet::App::Form::Waste::Garden::Kingston::Subscribe;
use FixMyStreet::App::Form::Waste::Garden::Kingston::Renew;
use Open311::GetServiceRequestUpdates;
use Integrations::SCP;
use Digest::MD5 qw(md5_hex);
use Memcached;

has feature => (
    is => 'ro',
    default => 'waste',
);

has index_template => (
    is => 'ro',
    default => 'waste/index.html'
);

sub auto : Private {
    my ( $self, $c ) = @_;

    $self->SUPER::auto($c);

    $c->stash->{is_staff} = $c->user && $c->cobrand->admin_allow_user($c->user);

    my $features = $c->cobrand->feature('waste_features') || {};
    # Copy so cobrands can switch things off depending on situation
    $c->stash->{waste_features} = $features = { %$features };
    if ($features->{garden_waste_staff_only} && !$c->stash->{is_staff}) {
        $features->{garden_disabled} = 1;
    }

    if ( my $site_name = Utils::trim_text($c->render_fragment('waste/site-name.html')) ) {
        $c->stash->{site_name} = $site_name;
    }

    $c->stash->{staff_payments_allowed} = '';
    $c->cobrand->call_hook( 'waste_check_staff_payment_permissions' );

    return 1;
}

sub pre_form : Private {
    my ($self, $c) = @_;

    # Special button to go back to existing (as form wraps whole page)
    if ($c->get_param('goto-existing')) {
        $c->set_param('goto', 'existing');
        $c->set_param('process', '');
    }
}

sub index : Path : Args(0) {
    my ( $self, $c ) = @_;

    if (my $id = $c->get_param('address')) {
        $c->cobrand->call_hook( clear_cached_lookups_property => $id );
        $c->detach('redirect_to_id', [ $id ]);
    }

    $c->cobrand->call_hook( clear_cached_lookups_postcode => $c->get_param('postcode') )
        if $c->get_param('postcode');

    $c->stash->{title} = 'What is your address?';
    my $form = FixMyStreet::App::Form::Waste::UPRN->new( cobrand => $c->cobrand );
    $form->process( params => $c->req->body_params );
    if ($form->validated) {
        my $addresses = $form->value->{postcode};
        $form = address_list_form($addresses);
    }
    $c->stash->{form} = $form;
}

sub address_list_form {
    my $addresses = shift;
    HTML::FormHandler->new(
        field_list => [
            address => {
                required => 1,
                type => 'Select',
                widget => 'RadioGroup',
                label => 'Select an address',
                tags => { last_differs => 1, small => 1 },
                options => $addresses,
            },
            go => {
                type => 'Submit',
                value => 'Continue',
                element_attr => { class => 'govuk-button' },
            },
        ],
    );
}

sub redirect_to_id : Private {
    my ($self, $c, $id) = @_;
    my $uri = '/waste/' . $id;
    my $type = $c->get_param('type') || '';
    $uri .= '/request' if $type eq 'request';
    $uri .= '/report' if $type eq 'report';
    $uri .= '/garden_check' if $type eq 'garden';
    $c->res->redirect($uri);
    $c->detach;
}

sub check_payment_redirect_id : Private {
    my ( $self, $c, $id, $token ) = @_;

    $c->detach( '/page_error_404_not_found' ) unless $id =~ /^\d+$/;

    my $p = $c->model('DB::Problem')->find({
        id => $id,
    });

    $c->detach( '/page_error_404_not_found' )
        unless $p && $p->get_extra_metadata('redirect_id') eq $token;

    if ( $p->state ne 'unconfirmed' ) {
        $c->stash->{error} = 'Already confirmed';
        $c->stash->{template} = 'waste/pay.html';
        $c->detach;
    }

    $c->stash->{report} = $p;
}

sub get_pending_subscription : Private {
    my ($self, $c) = @_;

    my $uprn = $c->stash->{property}{uprn};
    my $len = length $uprn;
    my $subs = $c->model('DB::Problem')->search({
        state => 'unconfirmed',
        created => { '>=' => \"current_timestamp-'20 days'::interval" },
        category => { -in => ['Garden Subscription', 'Cancel Garden Subscription'] },
        -or => [
                title => 'Garden Subscription - Renew',
                title => 'Garden Subscription - New',
                title => 'Garden Subscription - Cancel',
        ],
        extra => { like => '%uprn,T5:value,I' . $len . ':'. $c->stash->{property}{uprn} . '%' }
    })->to_body($c->cobrand->body);

    my ($new, $cancel);
    while (my $sub = $subs->next) {
        if ( $sub->get_extra_field_value('payment_method') eq 'direct_debit' ) {
            if ( $sub->title eq 'Garden Subscription - New' ||
                 $sub->title eq 'Garden Subscription - Renew' ) {
                $new = $sub;
            } elsif ( $sub->title eq 'Garden Subscription - Cancel' ) {
                $cancel = $sub;
            }
        }

    }
    $c->stash->{pending_subscription} ||= $new;
    $c->stash->{pending_cancellation} = $cancel;
}

sub pay_retry : Path('pay_retry') : Args(0) {
    my ($self, $c) = @_;

    my $id = $c->get_param('id');
    my $token = $c->get_param('token');
    $c->forward('check_payment_redirect_id', [ $id, $token ]);

    my $p = $c->stash->{report};
    $c->stash->{property} = $c->cobrand->call_hook(look_up_property => $p->get_extra_field_value('property_id'));
    $c->forward('pay', [ 'bin_days' ]);
}

sub pay : Path('pay') : Args(0) {
    my ($self, $c, $back) = @_;

    my $backUrl = $c->uri_for_action("/waste/$back", [ $c->stash->{property}{id} ]) . '';

    my $payment = Integrations::SCP->new({
        config => $c->cobrand->feature('payment_gateway')
    });

    my $p = $c->stash->{report};
    my $uprn = $p->get_extra_field_value('uprn');

    my $amount = $p->get_extra_field_value( 'pro_rata' );
    unless ($amount) {
        $amount = $p->get_extra_field_value( 'payment' );
    }
    my $admin_fee = $p->get_extra_field_value('admin_fee');

    my $redirect_id = mySociety::AuthToken::random_token();
    $p->set_extra_metadata('redirect_id', $redirect_id);
    $p->update;

    my $address = $c->stash->{property}{address};
    my @parts = split ',', $address;

    my @items = ({
        amount => $amount,
        reference => $payment->config->{customer_ref},
        description => $p->title,
        lineId => $c->cobrand->call_hook(waste_cc_payment_line_item_ref => $p) || "GGW$uprn",
    });
    if ($admin_fee) {
        push @items, {
            amount => $admin_fee,
            reference => $payment->config->{customer_ref_admin_fee},
            description => 'Admin fee',
            lineId => $c->cobrand->call_hook(waste_cc_payment_admin_fee_line_item_ref => $p) || "GGW$uprn",
        };
    }
    my $result = $payment->pay({
        returnUrl => $c->uri_for('pay_complete', $p->id, $redirect_id ) . '',
        backUrl => $backUrl,
        ref => 'GGW' . $uprn,
        request_id => $p->id,
        description => $p->title,
        name => $p->name,
        email => $p->user->email,
        uprn => $uprn,
        address1 => shift @parts,
        address2 => shift @parts,
        country => 'UK',
        postcode => pop @parts,
        items => \@items,
        staff => $c->stash->{staff_payments_allowed} eq 'cnp',
    });

    if ( $result ) {
        $c->stash->{xml} = $result;

        # GET back
        # requestId - should match above
        # scpReference - transaction Ref, used later for query
        # transactionState - in progress/complete
        # invokeResult/status - SUCCESS/INVALID_REQUEST/ERROR
        # invokeResult/redirectURL - what is says
        # invokeResult/errorDetails - what it says
        #
        if ( $result->{transactionState} eq 'IN_PROGRESS' &&
             $result->{invokeResult}->{status} eq 'SUCCESS' ) {

             $p->set_extra_metadata('scpReference', $result->{scpReference});
             $p->update;

             # need to save scpReference against request here
             my $redirect = $result->{invokeResult}->{redirectUrl};
             $c->res->redirect( $redirect );
             $c->detach;
         } else {
             # XXX - should this do more?
            (my $error = $result->{invokeResult}->{status}) =~ s/_/ /g;
            $c->stash->{error} = $error;
            $c->stash->{template} = 'waste/pay.html';
            $c->detach;
         }
     } else {
        $c->stash->{error} = 'Unknown error';
        $c->stash->{template} = 'waste/pay.html';
        $c->detach;
    }
}

# redirect from cc processing
sub pay_complete : Path('pay_complete') : Args(2) {
    my ($self, $c, $id, $token) = @_;

    $c->forward('check_payment_redirect_id', [ $id, $token ]);
    my $p = $c->stash->{report};

    # need to get some ID Things which I guess we stored in pay
    my $scpReference = $p->get_extra_metadata('scpReference');
    $c->detach( '/page_error_404_not_found' ) unless $scpReference;

    my $payment = Integrations::SCP->new(
        config => $c->cobrand->feature('payment_gateway')
    );

    my $resp = $payment->query({
        scpReference => $scpReference,
    });

    if ($resp->{transactionState} eq 'COMPLETE') {
        if ($resp->{paymentResult}->{status} eq 'SUCCESS') {
            # create sub in echo
            my $ref = $resp->{paymentResult}->{paymentDetails}->{paymentHeader}->{uniqueTranId};
            $c->stash->{title} = 'Payment successful';
            $c->stash->{reference} = $ref;
            $c->stash->{action} = $p->title eq 'Garden Subscription - Amend' ? 'add_containers' : 'new_subscription';
            $c->forward( 'confirm_subscription', [ $ref ] );
        # It is not clear to me that it's possible to get to this with a redirect
        } else {
            $c->stash->{template} = 'waste/pay.html';
            $c->stash->{error} = $resp->{paymentResult}->{status};
            $c->detach;
        }
    } else {
        # again, I am not sure it's possible for this to ever happen
        $c->stash->{template} = 'waste/pay.html';
        $c->stash->{error} = $resp->{transactionState};
        $c->detach;
    }
}

sub confirm_subscription : Private {
    my ($self, $c, $reference) = @_;

    my $p = $c->stash->{report};
    $p->update_extra_field( {
            name => 'LastPayMethod',
            description => 'LastPayMethod',
            value => $c->cobrand->bin_payment_types->{$p->get_extra_field_value('payment_method')}
        },
    );
    $p->update_extra_field( {
            name => 'PaymentCode',
            description => 'PaymentCode',
            value => $reference
        }
    );
    $c->stash->{no_reporter_alert} = 1 if
        $p->get_extra_metadata('contributed_as') &&
        $p->get_extra_metadata('contributed_as') eq 'anonymous_user';

    $p->set_extra_metadata('payment_reference', $reference) if $reference;
    $p->confirm;
    $c->forward( '/report/new/create_related_things', [ $p ] );
    $c->stash->{property_id} = $p->get_extra_field_value('property_id');
    $p->update;
    $c->stash->{template} = 'waste/garden/subscribe_confirm.html';
    # Set an override template, so that the form processing can finish (to e.g.
    # clear the session unique ID) and have the form code load this template
    # rather than the default 'done' form one
    $c->stash->{override_template} = $c->stash->{template};
}

sub cancel_subscription : Private {
    my ($self, $c, $reference) = @_;

    $c->stash->{template} = 'waste/garden/cancel_confirmation.html';
    $c->detach;
}

sub populate_dd_details : Private {
    my ($self, $c) = @_;

    my $p = $c->stash->{report};
    my $reference = mySociety::AuthToken::random_token();
    $p->set_extra_metadata('redirect_id', $reference);
    $p->update;

    my $address = $c->stash->{property}{address};

    my @parts = split ',', $address;

    my $name = $c->stash->{report}->name;
    my ($first, $last) = split /\s/, $name, 2;

    $c->stash->{account_holder} = $name;
    $c->stash->{first_name} = $first;
    $c->stash->{last_name} = $last;
    $c->stash->{address1} = shift @parts;
    $c->stash->{address2} = shift @parts;
    $c->stash->{postcode} = pop @parts;
    $c->stash->{town} = pop @parts;
    $c->stash->{address3} = join ', ', @parts;

    my $dt = $c->cobrand->waste_get_next_dd_day;

    my $payment = $p->get_extra_field_value('payment');
    my $admin_fee = $p->get_extra_field_value('admin_fee');
    if ( $admin_fee ) {
        my $first_payment = $admin_fee + $payment;
        $c->stash->{firstamount} = sprintf( '%.2f', $first_payment / 100 );
    }

    my $payment_details = $c->cobrand->feature('payment_gateway');
    $c->stash->{payment_details} = $payment_details;
    $c->stash->{amount} = sprintf( '%.2f', $payment / 100 );
    $c->stash->{reference} = $c->cobrand->call_hook( 'waste_dd_payment_ref' => $p ) || 'GGW' . $c->stash->{property}{uprn};
    $c->stash->{lookup} = $reference;
    $c->stash->{payment_date} = $dt;
    $c->stash->{start_date} = $dt->ymd;
    $c->stash->{day} = $dt->day;
    $c->stash->{month} = $dt->month;
    $c->stash->{month_name} = $dt->month_name;
    $c->stash->{year} = $dt->year;

    $c->stash->{redirect} = $c->cobrand->call_hook( 'garden_waste_dd_redirect_url' => $p ) || '';
}

sub direct_debit : Path('dd') : Args(0) {
    my ($self, $c) = @_;

    $c->forward('populate_dd_details');
    $c->stash->{template} = 'waste/dd.html';
    $c->detach;
}

# we process direct debit payments when they happen so this page
# is only for setting expectations.
sub direct_debit_complete : Path('dd_complete') : Args(0) {
    my ($self, $c) = @_;

    my ($token, $id) = $c->cobrand->call_hook( 'garden_waste_dd_get_redirect_params' => $c );
    $c->forward('check_payment_redirect_id', [ $id, $token]);

    $c->stash->{title} = "Direct Debit mandate";

    $c->send_email('waste/direct_debit_in_progress.txt', {
        to => [ [ $c->stash->{report}->user->email, $c->stash->{report}->name ] ],
    } );

    $c->stash->{template} = 'waste/dd_complete.html';
}

sub direct_debit_cancelled : Path('dd_cancelled') : Args(0) {
    my ($self, $c) = @_;

    my $token = $c->get_param('reference');
    my $id = $c->get_param('report_id');
    if ( $id && $token ) {
        $c->forward('check_payment_redirect_id', [ $id, $token ]);
        $c->forward('populate_dd_details');
    }

    $c->stash->{template} = 'waste/dd_cancelled.html';
}

sub direct_debit_modify : Path('dd_amend') : Args(0) {
    my ($self, $c) = @_;

    my $p = $c->stash->{report};

    my $pro_rata = $p->get_extra_field_value('pro_rata');
    my $admin_fee = $p->get_extra_field_value('admin_fee') || 0;
    my $total = $p->get_extra_field_value('payment');

    my $ad_hoc = $pro_rata + $admin_fee;

    my $i = $c->cobrand->get_dd_integration;

    # if reducing bin count then there won't be an ad-hoc payment
    if ( $ad_hoc ) {
        my $one_off_ref = $i->one_off_payment( {
                # this will be set when the initial payment is confirmed
                payer_reference => $c->stash->{orig_sub}->get_extra_metadata('payerReference'),
                amount => sprintf('%.2f', $ad_hoc / 100),
                reference => $p->id,
                comments => '',
                date => $c->cobrand->waste_get_next_dd_day('ad-hoc'),
                orig_sub => $c->stash->{orig_sub},
        } );
    }

    my $update_ref = $i->amend_plan( {
        payer_reference => $c->stash->{orig_sub}->get_extra_metadata('payerReference'),
        amount => sprintf('%.2f', $total / 100),
    } );
}

sub direct_debit_cancel_sub : Path('dd_cancel_sub') : Args(0) {
    my ($self, $c) = @_;

    my $p = $c->stash->{report};

    my $i = $c->cobrand->get_dd_integration;

    $c->stash->{payment_method} = 'direct_debit';
    my $update_ref = $i->cancel_plan( {
        payer_reference => $c->stash->{orig_sub}->get_extra_metadata('payerReference'),
    } );
}

sub csc_code : Private {
    my ($self, $c) = @_;

    unless ( $c->stash->{staff_payments_allowed} eq 'paye' ) {
        $c->detach( '/page_error_404_not_found', [] );
    }

    $c->forward('/auth/get_csrf_token');
    $c->stash->{template} = 'waste/garden/csc_code.html';
    $c->detach;
}

sub csc_payment : Path('csc_payment') : Args(0) {
    my ($self, $c) = @_;

    unless ( $c->stash->{staff_payments_allowed} eq 'paye' ) {
        $c->detach( '/page_error_404_not_found', [] );
    }

    $c->forward('/auth/check_csrf_token');
    my $code = $c->get_param('payenet_code');
    my $id = $c->get_param('report_id');

    my $report = $c->model('DB::Problem')->find({ id => $id});
    $report->update_extra_field({ name => 'payment_method', value => 'csc' });
    $report->update;
    $c->stash->{report} = $report;
    $c->forward('confirm_subscription', [ $code ]);
}

sub csc_payment_failed : Path('csc_payment_failed') : Args(0) {
    my ($self, $c) = @_;

    unless ( $c->stash->{staff_payments_allowed} eq 'paye' ) {
        $c->detach( '/page_error_404_not_found', [] );
    }

    $c->forward('/auth/check_csrf_token');
    my $code = $c->get_param('payenet_code');
    my $id = $c->get_param('report_id');

    my $report = $c->model('DB::Problem')->find({ id => $id});
    $c->stash->{report} = $report;
    $c->stash->{property_id} = $report->get_extra_field_value('property_id');

    if ( $report->get_extra_metadata('contributed_as') ne 'anonymous_user' ) {
        $c->stash->{sent_email} = 1;
        $c->send_email('waste/csc_payment_failed.txt', {
            to => [ [ $report->user->email, $report->name ] ],
        } );
    }

    $report->update_extra_field({ name => 'payment_method', value => 'csc' });
    $report->update_extra_field({ name => 'payment_reference', value => 'FAILED' });
    $report->update;

    $c->stash->{template} = 'waste/garden/csc_payment_failed.html';
    $c->detach;
}

sub property : Chained('/') : PathPart('waste') : CaptureArgs(1) {
    my ($self, $c, $id) = @_;

    if ($id eq 'missing') {
        $c->stash->{template} = 'waste/missing.html';
        $c->detach;
    }

    $c->forward('/auth/get_csrf_token');

    # clear this every time they visit this page to stop stale content.
    if ( $c->req->path =~ m#^waste/\d+$# ) {
        $c->cobrand->call_hook( clear_cached_lookups_property => $id );
    }

    my $property = $c->stash->{property} = $c->cobrand->call_hook(look_up_property => $id);
    $c->detach( '/page_error_404_not_found', [] ) unless $property && $property->{id};

    $c->stash->{latitude} = Utils::truncate_coordinate( $property->{latitude} );
    $c->stash->{longitude} = Utils::truncate_coordinate( $property->{longitude} );

    $c->stash->{service_data} = $c->cobrand->call_hook(bin_services_for_address => $property) || [];
    $c->stash->{services} = { map { $_->{service_id} => $_ } @{$c->stash->{service_data}} };
    $c->stash->{services_available} = $c->cobrand->call_hook(available_bin_services_for_address => $property) || {};

    $c->forward('get_pending_subscription');
}

sub bin_days : Chained('property') : PathPart('') : Args(0) {
    my ($self, $c) = @_;

    # To try and work out whether to show a renewal path or not
    $c->forward('get_original_sub', ['any']);
    $c->stash->{current_payment_method} = $c->forward('get_current_payment_method');

    my $staff = $c->user_exists && ($c->user->is_superuser || $c->user->from_body);

    my $cfg = $c->cobrand->feature('waste_features');

    return if $staff || (!$cfg->{max_requests_per_day} && !$cfg->{max_properties_per_day});

    # Allow lookups of max_per_day different properties per day
    my $today = DateTime->today->set_time_zone(FixMyStreet->local_time_zone)->ymd;
    my $ip = $c->req->address;

    if ($cfg->{max_requests_per_day}) {
        my $key = FixMyStreet->test_mode ? "waste-req-test" : "waste-req-$ip-$today";
        my $count = Memcached::increment($key, 86400) || 0;
        $c->detach('bin_day_deny') if $count > $cfg->{max_requests_per_day};
    }

    # Allow lookups of max_per_day different properties per day
    if ($cfg->{max_properties_per_day}) {
        my $key = FixMyStreet->test_mode ? "waste-prop-test" : "waste-prop-$ip-$today";
        my $list = Memcached::get($key) || [];

        my $id = $c->stash->{property}->{id};
        return if any { $_ eq $id } @$list; # Already visited today

        $c->detach('bin_day_deny') if @$list >= $cfg->{max_properties_per_day};

        push @$list, $id;
        Memcached::set($key, $list, 86400);
    }
}

sub bin_day_deny : Private {
    my ($self, $c) = @_;
    my $council = $c->cobrand->council_area;
    my $msg = "Please note that for security and privacy reasons $council have limited the number of different properties you can look up on the waste collection schedule in a 24-hour period.  You should be able to continue looking up against properties you have already viewed.  For other locations please try again after 24 hours.  If you are still seeing this message after that time please try refreshing the page.";
    $c->detach('/page_error_403_access_denied', [ $msg ]);
}

sub calendar : Chained('property') : PathPart('calendar.ics') : Args(0) {
    my ($self, $c) = @_;
    $c->res->header(Content_Type => 'text/calendar');
    require Data::ICal::RFC7986;
    require Data::ICal::Entry::Event;
    my $calendar = Data::ICal::RFC7986->new(
        calname => 'Bin calendar',
        rfc_strict => 1,
        auto_uid => 1,
    );
    $calendar->add_properties(
        prodid => '//FixMyStreet//Bin Collection Calendars//EN',
        method => 'PUBLISH',
        'refresh-interval' => [ 'P1D', { value => 'DURATION' } ],
        'x-published-ttl' => 'P1D',
        calscale => 'GREGORIAN',
        'x-wr-timezone' => 'Europe/London',
        source => [ $c->uri_for_action($c->action, [ $c->stash->{property}{id} ]), { value => 'URI' } ],
        url => $c->uri_for_action('waste/bin_days', [ $c->stash->{property}{id} ]),
    );

    my $events = $c->cobrand->bin_future_collections;
    my $stamp = DateTime->now->strftime('%Y%m%dT%H%M%SZ');
    foreach (@$events) {
        my $event = Data::ICal::Entry::Event->new;
        $event->add_properties(
            summary => $_->{summary},
            description => $_->{desc},
            dtstamp => $stamp,
            dtstart => [ $_->{date}->ymd(''), { value => 'DATE' } ],
            dtend => [ $_->{date}->add(days=>1)->ymd(''), { value => 'DATE' } ],
        );
        $calendar->add_entry($event);
    }

    $c->res->body($calendar->as_string);
}

sub construct_bin_request_form {
    my $c = shift;

    my $field_list = [];

    foreach (@{$c->stash->{service_data}}) {
        next unless ( $_->{next} && !$_->{request_open} ) || $_->{request_only};
        my $service = $_;
        my $name = $_->{service_name};
        my $containers = $_->{request_containers};
        my $max = $_->{request_max};
        foreach my $id (@$containers) {
            push @$field_list, "container-$id" => {
                type => 'Checkbox',
                apply => [
                    {
                        when => { "quantity-$id" => sub { $max > 1 && $_[0] > 0 } },
                        check => qr/^1$/,
                        message => 'Please tick the box',
                    },
                ],
                label => $name,
                option_label => $c->stash->{containers}->{$id},
                tags => { toggle => "form-quantity-$id-row" },
            };
            $name = ''; # Only on first container
            if ($max == 1) {
                push @$field_list, "quantity-$id" => {
                    type => 'Hidden',
                    default => '1',
                    apply => [ { check => qr/^1$/ } ],
                };
            } else {
                push @$field_list, "quantity-$id" => {
                    type => 'Select',
                    label => 'Quantity',
                    tags => {
                        hint => "You can request a maximum of " . NUMWORDS($max) . " containers",
                        initial_hidden => 1,
                    },
                    options => [
                        { value => "", label => '-' },
                        map { { value => $_, label => $_ } } (1..$max),
                    ],
                    required_when => { "container-$id" => 1 },
                };
            }
            $c->cobrand->call_hook("bin_request_form_extra_fields", $service, $id, $field_list);
        }
    }

    $c->cobrand->call_hook("waste_munge_request_form_fields", $field_list);


    return $field_list;
}

sub request : Chained('property') : Args(0) {
    my ($self, $c) = @_;

    my $field_list = construct_bin_request_form($c);

    $c->stash->{first_page} = 'request';
    $c->stash->{form_class} ||= 'FixMyStreet::App::Form::Waste::Request';
    $c->stash->{page_list} = [
        request => {
            fields => [ grep { ! ref $_ } @$field_list, 'submit' ],
            title => $c->stash->{form_title} || 'Which containers do you need?',
            check_unique_id => 0,
            next => sub {
                my $data = shift;
                return 'replacement' if $data->{"container-44"}; # XXX
                return 'about_you';
            }
        },
    ];
    $c->stash->{field_list} = $field_list;
    $c->forward('form');
}

sub process_request_data : Private {
    my ($self, $c, $form) = @_;
    my $data = $form->saved_data;
    $c->cobrand->call_hook("waste_munge_request_form_data", $data);
    my @services = grep { /^container-/ && $data->{$_} } sort keys %$data;
    my @reports;
    foreach (@services) {
        my ($id) = /container-(.*)/;
        $c->cobrand->call_hook("waste_munge_request_data", $id, $data);
        $c->forward('add_report', [ $data ]) or return;
        push @reports, $c->stash->{report};
    }
    group_reports($c, @reports);
    return 1;
}

sub group_reports {
    my ($c, @reports) = @_;
    my $report = shift @reports;
    if (@reports) {
        $report->set_extra_metadata(grouped_ids => [ map { $_->id } @reports ]);
        $report->update;
    }
    $c->stash->{report} = $report;
}

sub construct_bin_problem_form {
    my $c = shift;

    my $field_list = [];

    foreach (@{$c->stash->{service_data}}) {
        # next unless ( $_->{last} && $_->{report_allowed} && !$_->{report_open}) || $_->{report_only};
        my $id = $_->{service_id};
        my $name = $_->{service_name};
        push @$field_list, "service-$id" => {
            type => 'Checkbox',
            label => $name,
            option_label => $name,
        };
    }

    $c->cobrand->call_hook("waste_munge_problem_form_fields", $field_list);

    return $field_list;
}

sub problem : Chained('property') : Args(0) {
    my ($self, $c) = @_;

    my $field_list = construct_bin_problem_form($c);

    $c->stash->{first_page} = 'problem';
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Problem';
    $c->stash->{page_list} = [
        problem => {
            fields => [ grep { ! ref $_ } @$field_list, 'submit' ],
            title => 'Report a problem with a bin',
            next => 'about_you',
        },
    ];
    $c->stash->{field_list} = $field_list;
    $c->forward('form');
}

sub process_problem_data : Private {
    my ($self, $c, $form) = @_;
    my $data = $form->saved_data;
    $c->cobrand->call_hook("waste_munge_problem_form_data", $data);
    my @services = grep { /^service-/ && $data->{$_} } sort keys %$data;
    my @reports;
    foreach (@services) {
        my ($id) = /service-(.*)/;
        return unless $c->cobrand->can("waste_munge_problem_data");
        $c->cobrand->call_hook("waste_munge_problem_data", $id, $data);
        $c->forward('add_report', [ $data ]) or return;
        push @reports, $c->stash->{report};
    }
    group_reports($c, @reports);
    return 1;
}

sub construct_bin_report_form {
    my $c = shift;

    my $field_list = [];

    foreach (@{$c->stash->{service_data}}) {
        next unless ( $_->{last} && $_->{report_allowed} && !$_->{report_open}) || $_->{report_only};
        my $id = $_->{service_id};
        my $name = $_->{service_name};
        push @$field_list, "service-$id" => {
            type => 'Checkbox',
            label => $name,
            option_label => $name,
        };
    }

    $c->cobrand->call_hook("waste_munge_report_form_fields", $field_list);

    return $field_list;
}

sub report : Chained('property') : Args(0) {
    my ($self, $c) = @_;

    my $field_list = construct_bin_report_form($c);

    $c->stash->{first_page} = 'report';
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Report';
    $c->stash->{page_list} = [
        report => {
            fields => [ grep { ! ref $_ } @$field_list, 'submit' ],
            title => 'Select your missed collection',
            next => 'about_you',
        },
    ];
    $c->stash->{field_list} = $field_list;
    $c->forward('form');
}

sub process_report_data : Private {
    my ($self, $c, $form) = @_;
    my $data = $form->saved_data;
    $c->cobrand->call_hook("waste_munge_report_form_data", $data);
    my @services = grep { /^service-/ && $data->{$_} } sort keys %$data;
    my @reports;
    foreach (@services) {
        my ($id) = /service-(.*)/;
        $c->cobrand->call_hook("waste_munge_report_data", $id, $data);
        $c->forward('add_report', [ $data ]) or return;
        push @reports, $c->stash->{report};
    }
    group_reports($c, @reports);
    return 1;
}

sub enquiry : Chained('property') : Args(0) {
    my ($self, $c) = @_;

    if (my $template = $c->get_param('template')) {
        $c->stash->{template} = "waste/enquiry-$template.html";
        $c->detach;
    }

    $c->forward('setup_categories_and_bodies');

    my $category = $c->get_param('category');
    my $service = $c->get_param('service_id');
    if (!$category || !$service || !$c->stash->{services}{$service}) {
        $c->res->redirect('/waste/' . $c->stash->{property}{id});
        $c->detach;
    }
    my ($contact) = grep { $_->category eq $category } @{$c->stash->{contacts}};
    if (!$contact) {
        $c->res->redirect('/waste/' . $c->stash->{property}{id});
        $c->detach;
    }

    my $field_list = [];
    foreach (@{$contact->get_metadata_for_input}) {
        next if $_->{code} eq 'service_id' || $_->{code} eq 'uprn' || $_->{code} eq 'property_id';
        next if ($_->{automated} || '') eq 'hidden_field';
        my $type = 'Text';
        $type = 'TextArea' if 'text' eq ($_->{datatype} || '');
        my $required = $_->{required} eq 'true' ? 1 : 0;
        push @$field_list, "extra_$_->{code}" => {
            type => $type, label => $_->{description}, required => $required
        };
    }

    # If the contact has no extra fields (e.g. Peterborough) then skip to the
    # "about you" page instead of showing an empty first page.
    # NB this will mean you need to set $data->{category} in the cobrand's
    # waste_munge_enquiry_data.
    $c->stash->{first_page} = @$field_list ? 'enquiry' : 'about_you';

    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Enquiry';
    $c->stash->{page_list} = [
        enquiry => {
            fields => [ 'category', 'service_id', grep { ! ref $_ } @$field_list, 'continue' ],
            title => $category,
            next => 'about_you',
            update_field_list => sub {
                my $form = shift;
                my $c = $form->c;
                return {
                    category => { default => $c->get_param('category') },
                    service_id => { default => $c->get_param('service_id') },
                }
            }
        },
    ];
    $c->cobrand->call_hook("waste_munge_enquiry_form_fields", $field_list);
    $c->stash->{field_list} = $field_list;
    $c->forward('form');
}

sub process_enquiry_data : Private {
    my ($self, $c, $form) = @_;
    my $data = $form->saved_data;

    $c->cobrand->call_hook("waste_munge_enquiry_data", $data);

    # Read extra details in loop
    foreach (grep { /^extra_/ } keys %$data) {
        my ($id) = /^extra_(.*)/;
        $c->set_param($id, $data->{$_});
    }
    $c->set_param('service_id', $data->{service_id});
    $c->forward('add_report', [ $data ]) or return;
    return 1;
}

# staff should not be able to make payments for direct debit payments
sub check_if_staff_can_pay : Private {
    my ($self, $c, $payment_type) = @_;

    if ( $c->stash->{staff_payments_allowed} ) {
        if ( $payment_type && $payment_type eq 'direct_debit' ) {
            $c->stash->{template} = 'waste/garden/staff_no_dd.html';
            $c->detach;
        }
    }

    return 1;
}

sub garden_setup : Chained('property') : PathPart('') : CaptureArgs(0) {
    my ($self, $c) = @_;

    if ($c->stash->{waste_features}->{garden_disabled}) {
        $c->res->redirect('/waste/' . $c->stash->{property}{id});
        $c->detach;
    }

    $c->stash->{per_bin_cost} = $c->cobrand->feature('payment_gateway')->{ggw_cost};
    $c->stash->{per_new_bin_cost} = $c->cobrand->feature('payment_gateway')->{ggw_new_bin_cost};
    $c->stash->{per_new_bin_first_cost} = $c->cobrand->feature('payment_gateway')->{ggw_new_bin_first_cost} || $c->stash->{per_new_bin_cost};
}

sub garden_check : Chained('garden_setup') : Args(0) {
    my ($self, $c) = @_;

    my $id = $c->stash->{property}->{id};
    my $uri = '/waste/' . $id;

    my $service = $c->cobrand->garden_current_subscription;
    if (!$service) {
        # If no subscription, go straight to /garden
        $uri .= '/garden';
    }
    $c->res->redirect($uri);
    $c->detach;
}

sub garden : Chained('garden_setup') : Args(0) {
    my ($self, $c) = @_;

    if ($c->cobrand->garden_current_subscription) {
        $c->res->redirect('/waste/' . $c->stash->{property}{id});
        $c->detach;
    }

    $c->stash->{first_page} = 'intro';
    my $service = $c->cobrand->garden_service_id;
    $c->stash->{garden_form_data} = {
        max_bins => $c->stash->{quantity_max}->{$service}
    };
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden';
    if ($c->cobrand->moniker eq 'kingston') {
        $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Kingston::Subscribe';
    }
    $c->forward('form');
}

sub garden_modify : Chained('garden_setup') : Args(0) {
    my ($self, $c) = @_;

    my $service = $c->cobrand->garden_current_subscription;
    if (!$service || $service->{garden_due}) {
        $c->res->redirect('/waste/' . $c->stash->{property}{id});
        $c->detach;
    }

    unless ( $c->user_exists ) {
        $c->detach( '/auth/redirect' );
    }

    if ($c->stash->{garden_sacks} && $service->{garden_container} == 28) { # XXX Kingston sack
        my $payment_method = 'credit_card';
        $c->forward('check_if_staff_can_pay', [ $payment_method ]); # Should always be okay here
        $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Sacks::Purchase';
    } else {
        my $pick = $c->get_param('task') || '';
        if ($pick eq 'cancel') {
            $c->res->redirect('/waste/' . $c->stash->{property}{id} . '/garden_cancel');
            $c->detach;
        }

        $c->forward('get_original_sub', ['user']);

        my $service_id = $c->cobrand->garden_service_id;
        my $max_bins = $c->stash->{quantity_max}->{$service_id};

        my $payment_method = 'credit_card';
        if ( $c->stash->{orig_sub} ) {
            my $orig_sub = $c->stash->{orig_sub};
            my $orig_payment_method = $orig_sub->get_extra_field_value('payment_method');
            $payment_method = $orig_payment_method if $orig_payment_method && $orig_payment_method ne 'csc';
        }

        $c->forward('check_if_staff_can_pay', [ $payment_method ]);

        $c->stash->{display_end_date} = DateTime::Format::W3CDTF->parse_datetime($service->{end_date});
        $c->stash->{garden_form_data} = {
            pro_rata_bin_cost =>  $c->cobrand->waste_get_pro_rata_cost(1, $service->{end_date}),
            max_bins => $max_bins,
            bins => $service->{garden_bins},
            end_date => $service->{end_date},
            payment_method => $payment_method,
        };

        $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Modify';
    }

    $c->stash->{first_page} = 'intro';
    $c->forward('form');
}

sub garden_cancel : Chained('garden_setup') : Args(0) {
    my ($self, $c) = @_;

    if (!$c->cobrand->garden_current_subscription) {
        $c->res->redirect('/waste/' . $c->stash->{property}{id});
        $c->detach;
    }

    unless ( $c->user_exists ) {
        $c->detach( '/auth/redirect' );
    }

    $c->forward('get_original_sub', ['user']);

    my $payment_method = $c->forward('get_current_payment_method');
    $c->forward('check_if_staff_can_pay', [ $payment_method ]);

    $c->stash->{first_page} = 'intro';
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Cancel';
    $c->forward('form');
}

sub garden_renew : Chained('garden_setup') : Args(0) {
    my ($self, $c) = @_;

    $c->forward('get_original_sub', ['any']);

    # direct debit renewal is automatic so you should not
    # be doing this
    my $payment_method = $c->forward('get_current_payment_method');
    if ( $payment_method eq 'direct_debit' ) {
        $c->stash->{template} = 'waste/garden/dd_renewal_error.html';
        $c->detach;
    }

    $c->stash->{first_page} = 'intro';
    my $service = $c->cobrand->garden_service_id;
    my $max_bins = $c->stash->{quantity_max}->{$service};
    $service = $c->stash->{services}{$service};
    $c->stash->{garden_form_data} = {
        max_bins => $max_bins,
        bins => $service->{garden_bins},
    };
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Renew';
    if ($c->cobrand->moniker eq 'kingston' && $c->stash->{garden_sacks}) {
        $c->stash->{first_page} = 'sacks_choice';
        $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Kingston::Renew';
    }
    $c->forward('form');
}

sub process_garden_cancellation : Private {
    my ($self, $c, $form) = @_;

    my $payment_method = $c->forward('get_current_payment_method');
    my $data = $form->saved_data;

    unless ( $c->stash->{is_staff} ) {
        $data->{name} = $c->user->name;
        $data->{email} = $c->user->email;
        $data->{phone} = $c->user->phone;
    }
    $data->{category} = 'Cancel Garden Subscription';
    $data->{title} = 'Garden Subscription - Cancel';
    $data->{payment_method} = $payment_method;

    my $now = DateTime->now->set_time_zone(FixMyStreet->local_time_zone);
    $c->set_param('Subscription_End_Date', $now->ymd);

    my $service = $c->cobrand->garden_current_subscription;
    if (!$c->stash->{garden_sacks} || $service->{garden_container} == 26) {
        my $bin_count = $c->cobrand->get_current_garden_bins;
        $data->{new_bins} = $bin_count * -1;
    } else {
        $data->{garden_sacks} = 1;
    }
    $c->forward('setup_garden_sub_params', [ $data, undef ]);

    $c->forward('add_report', [ $data, 1 ]) or return;

    if ( FixMyStreet->staging_flag('skip_waste_payment') ) {
        $c->stash->{report}->confirm;
        $c->stash->{report}->update;
    } else {
        if ( $payment_method eq 'direct_debit' ) {
            my $report = $c->stash->{report};
            $report->set_extra_metadata('payerReference', $c->stash->{orig_sub}->get_extra_metadata('payerReference'));
            $report->update;
            $c->forward('direct_debit_cancel_sub');
        } else {
            $c->stash->{report}->confirm;
            $c->stash->{report}->update;
        }
    }
    return 1;
}

# We assume orig_sub has already tried to be fetched by this point
sub get_current_payment_method : Private {
    my ($self, $c) = @_;

    my $payment_method;

    if ($c->stash->{orig_sub}) {
        $payment_method = $c->stash->{orig_sub}->get_extra_field_value('payment_method');
    }

    return $payment_method || 'credit_card';

}

sub get_original_sub : Private {
    my ($self, $c, $type) = @_;

    my $p = $c->model('DB::Problem')->search({
        category => 'Garden Subscription',
        title => ['Garden Subscription - New', 'Garden Subscription - Renew'],
        extra => { like => '%property_id,T5:value,I_:'. $c->stash->{property}{id} . '%' },
        state => { '!=' => 'hidden' },
    },
    {
        order_by => { -desc => 'id' }
    })->to_body($c->cobrand->body);

    if ($type eq 'user' && !$c->stash->{is_staff}) {
        $p = $p->search({
            user_id => $c->user->id,
        });
    }

    $c->stash->{orig_sub} = $p->first;
}

sub setup_garden_sub_params : Private {
    my ($self, $c, $data, $type) = @_;

    my $address = $c->stash->{property}->{address};

    $data->{detail} = "$data->{category}\n\n$address";

    my $service_id;
    if (my $service = $c->cobrand->garden_current_subscription) {
        $service_id = $service->{service_id};
    } else {
        $service_id = $c->cobrand->garden_service_id;
    }
    $c->set_param('service_id', $service_id);
    $c->set_param('client_reference', 'GGW' . $c->stash->{property}->{uprn});
    $c->set_param('current_containers', $data->{current_bins});
    $c->set_param('new_containers', $data->{new_bins});
    # Either the user picked in the form, or it was staff and so will be credit card (or overridden to csc if that used)
    $c->set_param('payment_method', $data->{payment_method} || 'credit_card');
    $c->cobrand->call_hook(waste_garden_sub_params => $data, $type);
}

sub process_garden_modification : Private {
    my ($self, $c, $form) = @_;
    my $data = $form->saved_data;

    $data->{category} = 'Garden Subscription';
    $data->{title} = 'Garden Subscription - Amend';

    my $payment;
    my $pro_rata;
    my $payment_method;
    # Needs to check current subscription too
    my $service = $c->cobrand->garden_current_subscription;
    if ($c->stash->{garden_sacks} && $service->{garden_container} == 28) { # XXX Kingston sack
        $data->{garden_sacks} = 1;
        $data->{bin_count} = 1;
        $data->{new_bins} = 1;
        $payment = $c->cobrand->garden_waste_sacks_cost_pa();
        $payment_method = 'credit_card';
        $pro_rata = $payment; # Set so goes through flow below
    } else {
        my $bin_count = $data->{bins_wanted};
        $data->{bin_count} = $bin_count;
        my $new_bins = $bin_count - $data->{current_bins};
        $data->{new_bins} = $new_bins;

        my $cost_pa = $c->cobrand->garden_waste_cost_pa($bin_count);

        # One-off ad-hoc payment to be made now
        if ( $new_bins > 0 ) {
            my $cost_now_admin = $c->cobrand->garden_waste_new_bin_admin_fee($new_bins);
            $pro_rata = $c->cobrand->waste_get_pro_rata_cost( $new_bins, $c->stash->{garden_form_data}->{end_date});
            $c->set_param('pro_rata', $pro_rata);
            $c->set_param('admin_fee', $cost_now_admin);
        }

        $payment_method = $c->stash->{garden_form_data}->{payment_method};
        $payment = $cost_pa;
        $payment = 0 if $payment_method ne 'direct_debit' && $new_bins < 0;

    }
    $c->set_param('payment', $payment);

    $c->forward('setup_garden_sub_params', [ $data, $c->stash->{garden_subs}->{Amend} ]);
    $c->forward('add_report', [ $data, 1 ]) or return;

    if ( FixMyStreet->staging_flag('skip_waste_payment') ) {
        $c->stash->{message} = 'Payment skipped on staging';
        $c->stash->{reference} = $c->stash->{report}->id;
        $c->forward('confirm_subscription', [ $c->stash->{reference} ] );
    } else {
        if ( $pro_rata && $c->stash->{staff_payments_allowed} eq 'paye' ) {
            $c->forward('csc_code');
        } elsif ( $payment_method eq 'direct_debit' ) {
            my $report = $c->stash->{report};
            $report->set_extra_metadata('payerReference', $c->stash->{orig_sub}->get_extra_metadata('payerReference'));
            $report->update;
            $c->forward('direct_debit_modify');
        } elsif ( $pro_rata ) {
            $c->forward('pay', [ 'garden_modify' ]);
        } else {
            if ( $c->stash->{staff_payments_allowed} ) {
                my $report = $c->stash->{report};
                $report->update_extra_field({ name => 'payment_method', value => 'csc' });
                $report->update;
            }
            $c->forward('confirm_subscription', [ undef ]);
        }
    }
    return 1;
}

sub process_garden_renew : Private {
    my ($self, $c, $form) = @_;

    my $data = $form->saved_data;

    my $service = $c->cobrand->garden_current_subscription;
    my $type;
    if ( !$service || $c->cobrand->waste_sub_overdue( $service->{end_date} ) ) {
        $data->{category} = 'Garden Subscription';
        $data->{title} = 'Garden Subscription - New';
        $type = $c->stash->{garden_subs}->{New};
    } else {
        $data->{category} = 'Garden Subscription';
        $data->{title} = 'Garden Subscription - Renew';
        $type = $c->stash->{garden_subs}->{Renew};
    }

    if ($c->stash->{garden_sacks} && !$data->{bins_wanted}) {
        $data->{garden_sacks} = 1;
        $data->{bin_count} = 1;
        $data->{new_bins} = 1;
        my $cost_pa = $c->cobrand->garden_waste_sacks_cost_pa();
        $c->set_param('payment', $cost_pa);
    } else {
        my $total_bins = $data->{bins_wanted};
        my $current_bins = $data->{current_bins};
        $data->{bin_count} = $total_bins;
        $data->{new_bins} = $total_bins - $current_bins;

        my $cost_pa = $c->cobrand->garden_waste_cost_pa($total_bins);
        my $cost_now_admin = $c->cobrand->garden_waste_new_bin_admin_fee($data->{new_bins});

        $c->set_param('payment', $cost_pa);
        $c->set_param('admin_fee', $cost_now_admin);
    }

    $c->forward('setup_garden_sub_params', [ $data, $type ]);
    $c->forward('add_report', [ $data, 1 ]) or return;

    # it should not be possible to get to here if it's direct debit but
    # grab this so we can check and redirect to an information page if
    # they manage to get here
    my $payment_method = $data->{payment_method}
        || $c->forward('get_current_payment_method');

    if ( FixMyStreet->staging_flag('skip_waste_payment') ) {
        $c->stash->{message} = 'Payment skipped on staging';
        $c->stash->{reference} = $c->stash->{report}->id;
        $c->forward('confirm_subscription', [ $c->stash->{reference} ] );
    } else {
        if ( $c->stash->{staff_payments_allowed} eq 'paye' ) {
            $c->forward('csc_code');
        } elsif ( $payment_method eq 'direct_debit' ) {
            $c->forward('direct_debit');
        } else {
            $c->forward('pay', [ 'garden_renew' ]);
        }
    }

    return 1;
}

sub process_garden_data : Private {
    my ($self, $c, $form) = @_;
    my $data = $form->saved_data;

    $data->{category} = 'Garden Subscription';
    $data->{title} = 'Garden Subscription - New';

    if ($c->stash->{garden_sacks} && !$data->{bins_wanted}) {
        $data->{garden_sacks} = 1;
        $data->{bin_count} = 1;
        $data->{new_bins} = 1;
        my $cost_pa = $c->cobrand->garden_waste_sacks_cost_pa();
        $c->set_param('payment', $cost_pa);
    } else {
        my $bin_count = $data->{bins_wanted};
        $data->{bin_count} = $bin_count;
        $data->{new_bins} = $data->{bins_wanted} - $data->{current_bins};

        my $cost_pa = $c->cobrand->garden_waste_cost_pa($bin_count);
        my $cost_now_admin = $c->cobrand->garden_waste_new_bin_admin_fee($data->{new_bins});

        $c->set_param('payment', $cost_pa);
        $c->set_param('admin_fee', $cost_now_admin);
    }

    $c->forward('setup_garden_sub_params', [ $data, $c->stash->{garden_subs}->{New} ]);
    $c->forward('add_report', [ $data, 1 ]) or return;

    if ( FixMyStreet->staging_flag('skip_waste_payment') ) {
        $c->stash->{message} = 'Payment skipped on staging';
        $c->stash->{reference} = $c->stash->{report}->id;
        $c->forward('confirm_subscription', [ $c->stash->{reference} ] );
    } else {
        if ( $c->stash->{staff_payments_allowed} eq 'paye' ) {
            $c->forward('csc_code');
        } elsif ( $data->{payment_method} eq 'direct_debit' ) {
            $c->forward('direct_debit');
        } else {
            $c->forward('pay', [ 'garden' ]);
        }
    }
    return 1;
}

sub add_report : Private {
    my ( $self, $c, $data, $no_confirm ) = @_;

    $c->stash->{cobrand_data} = 'waste';
    $c->stash->{override_confirmation_template} = 'waste/confirmation.html';

    # Store the name of the first page of the wizard on the token
    # so Peterborough can show the appropriate confirmation page when the
    # confirmation link is followed.
    $c->stash->{token_extra_data} = {
        first_page => $c->stash->{first_page},
    };

    # Don’t let staff inadvertently change their name when making reports
    my $original_name = $c->user->name if $c->user_exists && $c->user->from_body && $c->user->email eq ($data->{email} || '');

    # We want to take what has been entered in the form, even if someone is logged in
    $c->stash->{ignore_logged_in_user} = 1;

    if ($c->user_exists) {
        if ($c->user->from_body && !$data->{email} && !$data->{phone}) {
            $c->set_param('form_as', 'anonymous_user');
        } elsif ($c->user->from_body && $c->user->email ne $data->{email}) {
            $c->set_param('form_as', 'another_user');
        }
        $c->set_param('username', $data->{email} || $data->{phone});
    } else {
        $c->set_param('username_register', $data->{email} || $data->{phone});
    }

    # Set the data as if a new report form has been submitted

    $c->set_param('submit_problem', 1);
    $c->set_param('pc', '');
    $c->set_param('non_public', 1);

    $c->set_param('name', $data->{name});
    $c->set_param('phone', $data->{phone});

    $c->set_param('category', $data->{category});
    $c->set_param('title', $data->{title});
    $c->set_param('detail', $data->{detail});
    $c->set_param('uprn', $c->stash->{property}{uprn});
    $c->set_param('property_id', $c->stash->{property}{id});

    $c->forward('setup_categories_and_bodies') unless $c->stash->{contacts};
    $c->forward('/report/new/non_map_creation', [['/waste/remove_name_errors']]) or return;
    # we don't want to confirm reports that are for things that require a payment because
    # we need to get the payment to confirm them.
    if ( $no_confirm ) {
        my $report = $c->stash->{report};
        $report->state('unconfirmed');
        $report->confirmed(undef);
        $report->update;
    } else {
        $c->forward('/report/new/redirect_or_confirm_creation');
    }

    $c->user->update({ name => $original_name }) if $original_name;

    $c->cobrand->call_hook( clear_cached_lookups_property => $c->stash->{property}{id} );

    return 1;
}

sub remove_name_errors : Private {
    my ($self, $c) = @_;
    # We do not mind about missing title/split name here
    my $field_errors = $c->stash->{field_errors};
    delete $field_errors->{fms_extra_title};
    delete $field_errors->{first_name};
    delete $field_errors->{last_name};
}

sub setup_categories_and_bodies : Private {
    my ($self, $c) = @_;

    $c->stash->{fetch_all_areas} = 1;
    $c->stash->{area_check_action} = 'submit_problem';
    $c->forward('/council/load_and_check_areas', []);
    $c->forward('/report/new/setup_categories_and_bodies');
}

sub receive_echo_event_notification : Path('/waste/echo') : Args(0) {
    my ($self, $c) = @_;
    $c->stash->{format} = 'xml';
    $c->response->header(Content_Type => 'application/soap+xml');

    require SOAP::Lite;

    $c->detach('soap_error', [ 'Invalid method', 405 ]) unless $c->req->method eq 'POST';

    my $echo = $c->cobrand->feature('echo');
    $c->detach('soap_error', [ 'Missing config', 500 ]) unless $echo;

    # Make sure we log entire request for debugging
    $c->detach('soap_error', [ 'Missing body' ]) unless $c->req->body;
    my $soap = join('', $c->req->body->getlines);
    $c->log->debug($soap);

    my $body = $c->cobrand->body;
    $c->detach('soap_error', [ 'Bad jurisdiction' ]) unless $body;

    my $env = SOAP::Deserializer->deserialize($soap);

    my $header = $env->header;
    $c->detach('soap_error', [ 'Missing SOAP header' ]) unless $header;
    my $action = $header->{Action};
    $c->detach('soap_error', [ 'Incorrect Action' ]) unless $action && $action eq $echo->{receive_action};
    $header = $header->{Security};
    $c->detach('soap_error', [ 'Missing Security header' ]) unless $header;
    my $token = $header->{UsernameToken};
    $c->detach('soap_error', [ 'Authentication failed' ])
        unless $token && $token->{Username} eq $echo->{receive_username} && $token->{Password} eq $echo->{receive_password};

    my $event = $env->result;

    my $cfg = { echo => Integrations::Echo->new(%$echo) };
    my $request = $c->cobrand->construct_waste_open311_update($cfg, $event);
    $c->detach('soap_ok') if !$request->{status} || $request->{status} eq 'confirmed'; # Ignore new events

    $request->{updated_datetime} = DateTime::Format::W3CDTF->format_datetime(DateTime->now);
    $request->{service_request_id} = $event->{Guid};

    my $updates = Open311::GetServiceRequestUpdates->new(
        system_user => $body->comment_user,
        current_body => $body,
    );

    my $p = $updates->find_problem($request);
    if ($p) {
        $c->forward('check_existing_update', [ $p, $request, $updates ]);
        my $comment = $updates->process_update($request, $p);
    }
    # Still want to say it is okay, even if we did nothing with it
    $c->forward('soap_ok');
}

sub soap_error : Private {
    my ($self, $c, $comment, $code) = @_;
    $code ||= 400;
    $c->response->status($code);
    my $type = $code == 500 ? 'Server' : 'Client';
    $c->response->body(SOAP::Serializer->fault($type, "Bad request: $comment", soap_header()));
}

sub soap_ok : Private {
    my ($self, $c) = @_;
    $c->response->status(200);
    my $method = SOAP::Data->name("NotifyEventUpdatedResponse")->attr({
        xmlns => "http://www.twistedfish.com/xmlns/echo/api/v1"
    });
    $c->response->body(SOAP::Serializer->envelope(method => $method, soap_header()));
}

sub soap_header {
    my $attr = "http://www.twistedfish.com/xmlns/echo/api/v1";
    my $action = "NotifyEventUpdatedResponse";
    my $header = SOAP::Header->name("Action")->attr({
        xmlns => 'http://www.w3.org/2005/08/addressing',
        'soap:mustUnderstand' => 1,
    })->value("$attr/ReceiverService/$action");

    my $dt = DateTime->now();
    my $dt2 = $dt->clone->add(minutes => 5);
    my $w3c = DateTime::Format::W3CDTF->new;
    my $header2 = SOAP::Header->name("Security")->attr({
        'soap:mustUnderstand' => 'true',
        'xmlns' => 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd'
    })->value(
        \SOAP::Header->name(
            "Timestamp" => \SOAP::Header->value(
                SOAP::Header->name('Created', $w3c->format_datetime($dt)),
                SOAP::Header->name('Expires', $w3c->format_datetime($dt2)),
            )
        )->attr({
            xmlns => "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd",
        })
    );
    return ($header, $header2);
}

sub check_existing_update : Private {
    my ($self, $c, $p, $request, $updates) = @_;

    my $cfg = { updates => $updates };
    $c->detach('soap_ok')
        unless $c->cobrand->waste_check_last_update(
            $cfg, $p, $request->{status}, $request->{external_status_code});
}

sub uprn_redirect : Path('/property') : Args(1) {
    my ($self, $c, $uprn) = @_;

    my $cfg = $c->cobrand->feature('echo');
    my $echo = Integrations::Echo->new(%$cfg);
    my $result = $echo->GetPointAddress($uprn, 'Uprn');
    $c->detach( '/page_error_404_not_found', [] ) unless $result;
    $c->res->redirect('/waste/' . $result->{Id});
}

__PACKAGE__->meta->make_immutable;

1;
