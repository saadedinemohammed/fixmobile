package FixMyStreet::Cobrand::Merton;
use parent 'FixMyStreet::Cobrand::Whitelabel';

use strict;
use warnings;
use Moo;
with 'FixMyStreet::Roles::CobrandOpenUSRN';
with 'FixMyStreet::Cobrand::Merton::Waste';
with 'FixMyStreet::Roles::Open311Multi';

sub council_area_id { 2500 }
sub council_area { 'Merton' }
sub council_name { 'Merton Council' }
sub council_url { 'merton' }
sub send_questionnaires { 0 }

sub disambiguate_location {
    my $self    = shift;
    my $string  = shift;

    my $town = "Merton";

    return {
        %{ $self->SUPER::disambiguate_location() },
        town => $town,
        centre => '51.4099496632915,-0.197255310605401',
        span   => '0.0612811278185319,0.130096741684365',
        bounds => [ 51.3801834993027, -0.254262247988426, 51.4414646271213, -0.124165506304061 ],
    };
}

sub report_validation {
    my ($self, $report, $errors) = @_;

    my @extra_fields = @{ $report->get_extra_fields() };

    my %max = (
        vehicle_registration_number => 15,
        vehicle_make_model => 50,
        vehicle_colour => 50,
    );

    foreach my $extra ( @extra_fields ) {
        my $max = $max{$extra->{name}} || 100;
        if ( length($extra->{value}) > $max ) {
            $errors->{'x' . $extra->{name}} = qq+Your answer to the question: "$extra->{description}" is too long. Please use a maximum of $max characters.+;
        }
    }

    return $errors;
}

sub enter_postcode_text { 'Enter a postcode, street name and area, or check an existing report number' }

sub get_geocoder { 'OSM' }

sub admin_user_domain { 'merton.gov.uk' }

# Merton requested something other than @merton.gov.uk due to their CRM misattributing reports to staff.
sub anonymous_domain { 'anonymous-fms.merton.gov.uk' }

sub open311_config {
    my ($self, $row, $h, $params, $contact) = @_;

    $params->{multi_photos} = 1;
    $params->{upload_files} = 1;
}

sub reopening_disallowed {
    my ($self, $problem) = @_;
    # allow admins to restrict staff from reopening categories using category control
    return 1 if $self->next::method($problem);
    # only Merton staff may reopen reports
    my $c = $self->{c};
    my $user = $c->user;
    return 0 if ($c->user_exists && $user->from_body && $user->from_body->cobrand_name eq 'Merton Council');
    return 1;
}

sub open311_update_missing_data {
    my ($self, $row, $h, $contact) = @_;

    # Reports made via FMS.com or the app probably won't have a USRN
    # value because we don't access the USRN layer on those
    # frontends. Instead we'll look up the closest asset from the WFS
    # service at the point we're sending the report over Open311.
    if (!$row->get_extra_field_value('usrn')) {
        if (my $usrn = $self->lookup_site_code($row, 'usrn')) {
            $row->update_extra_field({ name => 'usrn', value => $usrn });
        }
    }

    return [];
}

sub open311_extra_data_include {
    my ($self, $row, $h) = @_;

    my $open311_only = [];

    my $contributed_by = $row->get_extra_metadata('contributed_by');
    my $contributing_user = FixMyStreet::DB->resultset('User')->find({ id => $contributed_by });
    if ($contributing_user) {
        push @$open311_only, {
            name => 'contributed_by',
            value => $contributing_user->email,
        };
    }

    return $open311_only;
};

sub open311_munge_update_params {
}

sub report_new_munge_before_insert {
    my ($self, $report) = @_;

    return unless $report->to_body_named('Merton');

    # Workaround for anonymous reports not having a service associated with them.
    if (!$report->service) {
        $report->service('unknown');
    }

    # Save the service attribute into extra data as well as in the
    # problem to avoid having the field appear as blank and required
    # in the inspector toolbar for users with 'inspect' permissions.
    if (!$report->get_extra_field_value('service')) {
        $report->update_extra_field({ name => 'service', value => $report->service });
    }
}

sub cut_off_date { '2021-12-13' } # Merton cobrand go-live

sub report_age { '3 months' }

sub abuse_reports_only { 1 }

=head2 categories_restriction

Hide TfL's River Piers categories on the Merton cobrand.

=cut

sub categories_restriction {
    my ($self, $rs) = @_;

    return $rs->search( { 'me.category' => { -not_like => 'River Piers%' } } );
}

sub open311_pre_send {
    my ($self, $row, $open311) = @_;

    # if this report has already been sent to Echo and we're re-sending to Dynamics,
    # need to keep the original external_id so we can restore it afterwards.
    $self->{original_external_id} = $row->external_id;
}

sub open311_post_send {
    my ($self, $row, $h, $sender) = @_;

    # restore original external_id for this report, and store new Dynamics ID
    if ( $self->{original_external_id} ) {
        $row->set_extra_metadata( crimson_external_id => $row->external_id );
        $row->external_id($self->{original_external_id});
        $row->update;
        delete $self->{original_external_id};
    }
}
1;
