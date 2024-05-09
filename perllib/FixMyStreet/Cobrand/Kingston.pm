package FixMyStreet::Cobrand::Kingston;
use parent 'FixMyStreet::Cobrand::UKCouncils';

use utf8;
use Moo;
with 'FixMyStreet::Roles::Cobrand::KingstonSutton';
with 'FixMyStreet::Roles::SCP';

use Lingua::EN::Inflect qw( NUMWORDS );

sub council_area_id { return 2480; }
sub council_area { return 'Kingston'; }
sub council_name { return 'Kingston upon Thames Council'; }
sub council_url { return 'kingston'; }
sub admin_user_domain { 'kingston.gov.uk' }

use constant CONTAINER_REFUSE_180 => 35;
use constant CONTAINER_REFUSE_240 => 2;
use constant CONTAINER_REFUSE_360 => 3;
use constant CONTAINER_RECYCLING_BIN => 12;
use constant CONTAINER_RECYCLING_BOX => 16;
use constant CONTAINER_FOOD_OUTDOOR => 24;

=head2 waste_on_the_day_criteria

Treat an Outstanding/Allocated task as if it's the next collection and in
progress, and do not allow missed collection reporting if the task is not
completed.

=cut

sub waste_on_the_day_criteria {
    my ($self, $completed, $state, $now, $row) = @_;

    if ($state eq 'Outstanding' || $state eq 'Allocated') {
        $row->{next} = $row->{last};
        $row->{next}{state} = 'In progress';
        delete $row->{last};
    }
    if (!$completed) {
        $row->{report_allowed} = 0;
    }
}

sub waste_check_staff_payment_permissions {
    my $self = shift;
    my $c = $self->{c};

    return unless $c->stash->{is_staff};

    $c->stash->{staff_payments_allowed} = 'cnp';
}

has lpi_value => ( is => 'ro', default => 'KINGSTON UPON THAMES' );

sub waste_payment_ref_council_code { "RBK" }

sub garden_collection_time { '6:30am' }

sub image_for_unit {
    my ($self, $unit) = @_;
    my $base = '/i/waste-containers';
    if (my $container = $unit->{garden_container}) {
        return "$base/bin-grey-green-lid-recycling" if $container == 26 || $container == 27;
        return "";
    }

    if ($unit->{service_id} eq 'bulky') {
        return "$base/bulky-black";
    }

    # Base mixed recycling (2241) on the container itself
    my %containers = map { $_ => 1 } @{$unit->{request_containers}};
    return "$base/bin-green" if $containers{+CONTAINER_RECYCLING_BIN};
    return "$base/box-green-mix" if $containers{+CONTAINER_RECYCLING_BOX};

    my $service_id = $unit->{service_id};
    my $images = {
        2238 => "$base/bin-black", # refuse
        2239 => "$base/caddy-brown-large", # food
        2240 => "$base/bin-grey-blue-lid-recycling", # paper and card
        2241 => "$base/bin-green", # dry mixed
        2242 => "$base/sack-clear-red", # domestic refuse bag
        2243 => "$base/large-communal-grey-black-lid", # Communal refuse
        2246 => "$base/sack-clear-blue", # domestic recycling bag
        2248 => "$base/bin-brown", # Communal food
        2249 => "$base/large-communal-grey-blue-lid", # Communal paper
        2250 => "$base/large-communal-green", # Communal recycling
        2632 => "$base/sack-clear", # domestic paper bag
    };
    return $images->{$service_id};
}

=head2 garden_waste_renewal_cost_pa

The price change for a renewal is based upon the end
date of the subscription, not the current date.

=cut

sub garden_waste_renewal_cost_pa {
     my ($self, $end_date, $bin_count) = @_;
     $bin_count ||= 1;
     my $per_bin_cost = $self->_get_cost('ggw_cost_renewal', $end_date);
     my $cost = $per_bin_cost * $bin_count;
     return $cost;
}

sub garden_waste_renewal_sacks_cost_pa {
     my ($self, $end_date) = @_;
     return $self->_get_cost('ggw_sacks_cost_renewal', $end_date);
}

sub waste_request_single_radio_list { 0 }

=head2 bin_request_form_extra_fields

We want an extra message on the outdoor food container option.

=cut

sub bin_request_form_extra_fields {
    my ($self, $service, $id, $field_list) = @_;

    return unless $id == CONTAINER_FOOD_OUTDOOR;
    my %fields = @$field_list;
    $fields{"container-$id"}{option_hint} = 'Only three are allowed per property. Any more than this will not be collected.';
}

=head2 waste_munge_request_form_fields

If we're looking to change capacity, list the possibilities here.

=cut

sub waste_munge_request_form_fields {
    my ($self, $field_list) = @_;
    my $c = $self->{c};

    return unless $c->get_param('exchange');

    my @radio_options;
    for (my $i=0; $i<@$field_list; $i+=2) {
        my ($key, $value) = ($field_list->[$i], $field_list->[$i+1]);
        next unless $key =~ /^container-(\d+)/;
        my $id = $1;

        if (my $os = $c->get_param('override_size')) {
            $id = 35 if $os == '180';
            $id = 2 if $os == '240';
            $id = 3 if $os == '360';
        }

        if ($id == CONTAINER_REFUSE_180) {
            $c->stash->{current_refuse_bin} = 180;
        } elsif ($id == CONTAINER_REFUSE_240) {
            $c->stash->{current_refuse_bin} = 240;
            @radio_options = ( {
                value => CONTAINER_REFUSE_180,
                label => 'Smaller black rubbish bin',
                disabled => $value->{disabled},
                hint => 'You can decrease the size of your bin to 180L.',
            }, {
                value => CONTAINER_REFUSE_360,
                label => 'Larger black rubbish bin',
                disabled => $value->{disabled},
                hint => 'You already have the biggest sized bin allowed. If you have an exceptionally large household or your household has medical needs that create more waste than normal, you can apply for more capacity, but this will be assessed by our officers.',
            },
            );
        } elsif ($id == CONTAINER_REFUSE_360) {
            $c->stash->{current_refuse_bin} = 360;
            @radio_options = ( {
                value => CONTAINER_REFUSE_180,
                label => '180L black rubbish bin ‘standard’',
                disabled => $value->{disabled},
            }, {
                value => CONTAINER_REFUSE_240,
                label => '240L black rubbish bin ‘larger’',
                disabled => $value->{disabled},
            },
            );
        }
    }

    @$field_list = (
        "container-capacity-change" => {
            type => 'Select',
            widget => 'RadioGroup',
            label => 'Which container do you need?',
            options => \@radio_options,
            required => 1,
        }
    );
}

=head2 waste_request_form_first_next

After picking a container, we ask what bins needs removing.

=cut

sub waste_request_form_first_title {
    my $self = shift;
    my $c = $self->{c};
    return 'Black bin size change request' if $c->get_param('exchange');
}

sub waste_request_form_first_next {
    my $self = shift;
    my $c = $self->{c};
    if ($c->get_param('exchange')) {
        my $uprn = $c->stash->{property}{uprn};
        return sub {
            my $data = shift;
            my $choice = $data->{"container-capacity-change"};
            if ($choice == CONTAINER_REFUSE_360) {
                $c->res->redirect($c->stash->{waste_features}{large_refuse_application_form} . '?uprn=' . $uprn);
                $c->detach;
            } else {
                $data->{"container-$choice"} = 1;
                $data->{"quantity-$choice"} = 1;
                $data->{"removal-$choice"} = 1;
            }
            return 'about_you';
        };
    }
    return 'removals';
}

=head2 waste_munge_request_form_pages

We have a separate removal page, asking which bins need to be removed.

=cut

sub waste_munge_request_form_pages {
    my ($self, $page_list, $field_list) = @_;
    my $c = $self->{c};

    if (($c->stash->{current_refuse_bin} || 0) == 180) {
        $c->stash->{first_page} = 'how_many_exchange';
    }

    my %maxes;
    foreach (@{$c->stash->{service_data}}) {
        next unless $_->{next} || $_->{request_only};
        my $containers = $_->{request_containers};
        my $maximum = $_->{request_max};
        foreach my $id (@$containers) {
            $maxes{$id} = ref $maximum ? $maximum->{$id} : $maximum;
        }
    }

    sub n { my $n = shift; my $w = ucfirst NUMWORDS($n); $w =~ s/Zero/None/; "$w ($n)"; }

    my @removal_options;
    for (my $i=0; $i<@$field_list; $i+=2) {
        my ($key, $value) = ($field_list->[$i], $field_list->[$i+1]);
        next unless $key =~ /^container-(\d+)/;
        my $id = $1;
        my $name = $c->stash->{containers}{$id};
        push @$field_list, "removal-$id" => {
            required => 1,
            type => 'Select',
            widget => 'RadioGroup',
            label => "$name: How many do you wish removing from your property?",
            tags => { small => 1 },
            options => [
                map { { value => $_, label => n($_) } } (0..$maxes{$id})
            ],
        };
        push @removal_options, "removal-$id";
    }

    push @$page_list, removals => {
        fields => [ @removal_options, 'submit' ],
        update_field_list => sub {
            my $form = shift;
            my $data = $form->saved_data;
            my $fields = {};
            foreach (@removal_options) {
                my ($id) = /removal-(.*)/;
                if ($data->{"container-$id"}) {
                    my $quantity = $data->{"quantity-$id"};
                    my $max = $quantity || $maxes{$id};
                    $fields->{$_}{options} = [
                        map { { value => $_, label => n($_) } } (0..$max)
                    ];
                } else {
                    $fields->{$_}{widget} = 'Hidden';
                    $fields->{$_}{required} = 0;
                }
            }
            # Both types of recycling container always
            if ($data->{'container-' . CONTAINER_RECYCLING_BIN}) {
                delete $fields->{"removal-" . CONTAINER_RECYCLING_BOX}{widget};
                delete $fields->{"removal-" . CONTAINER_RECYCLING_BOX}{required};
            }
            if ($data->{'container-' . CONTAINER_RECYCLING_BOX}) {
                delete $fields->{"removal-" . CONTAINER_RECYCLING_BIN}{widget};
                delete $fields->{"removal-" . CONTAINER_RECYCLING_BIN}{required};
            }
            return $fields;
        },
        title => 'How many containers need removing?',
        next => sub {
            # If it is a refuse bin, and they haven't asked for one to be
            # removed, we need to ask how many people live at the property
            for (CONTAINER_REFUSE_180, CONTAINER_REFUSE_240, CONTAINER_REFUSE_360) {
                return 'how_many' if $_[0]->{"container-$_"} && !$_[0]->{"removal-$_"};
            }
            return 'about_you';
        },
    };
}

# Expand out everything to one entry per container
sub waste_munge_request_form_data {
    my ($self, $data) = @_;

    my $new_data;
    my @services = grep { /^container-/ } sort keys %$data;
    foreach (@services) {
        my ($id) = /container-(.*)/;
        my $quantity = $data->{"quantity-$id"} || 0;
        my $to_remove = $data->{"removal-$id"} || 0;
        next unless $data->{$_} || ($id == CONTAINER_RECYCLING_BIN || $id == CONTAINER_RECYCLING_BOX);

        if ($quantity - $to_remove > 0) {
            $new_data->{"container-$id-deliver-$_"} = 1
                for 1..($quantity-$to_remove);
            $new_data->{"container-$id-replace-$_"} = 1
                for 1..$to_remove;
        } elsif ($to_remove - $quantity > 0) {
            $new_data->{"container-$id-collect-$_"} = 1
                for 1..($to_remove-$quantity);
            $new_data->{"container-$id-replace-$_"} = 1
                for 1..$quantity;
        } else { # Equal
            $new_data->{"container-$id-replace-$_"} = 1
                for 1..$quantity;
        }
    }
    %$data = map { $_ => $data->{$_} } grep { !/^(container|quantity|removal)-/ } keys %$data;
    %$data = (%$data, %$new_data);
}

sub waste_munge_request_data {
    my ($self, $id, $data, $form) = @_;

    my $c = $self->{c};
    my $address = $c->stash->{property}->{address};

    my ($container_id, $action, $n) = split /-/, $id;
    my $container = $c->stash->{containers}{$container_id};

    my ($action_id, $reason_id);
    if ($action eq 'deliver') {
        $action_id = 1; # Deliver
        $reason_id = 1; # Missing (or 4 New)
    } elsif ($action eq 'collect') {
        $action_id = 2; # Collect
        $reason_id = 3; # Change capacity
    } elsif ($action eq 'replace') {
        $action_id = 3; # Replace
        $reason_id = $c->get_param('exchange') ? 3 : 2; # Change capacity : Damaged
    }

    if ($action eq 'deliver') {
        $data->{title} = "Request $container delivery";
    } elsif ($action eq 'replace') {
        $data->{title} = "Request $container replacement";
    } else {
        $data->{title} = "Request $container collection";
    }
    $data->{detail} = $address;

    $c->set_param('Action', $action_id);
    $c->set_param('Reason', $reason_id);

    if ($data->{how_many} && $container =~ /rubbish bin/) { # Must be a refuse bin
        if ($data->{how_many} eq '5more') {
            $c->set_param('Container_Type', CONTAINER_REFUSE_240);
        } else {
            $c->set_param('Container_Type', CONTAINER_REFUSE_180);
        }
    } else {
        $c->set_param('Container_Type', $container_id);
    }

    if ($data->{payment}) {
        my ($cost) = $self->request_cost($container_id); # Will be full price, or nothing if free
        if ($cost) {
            if ($data->{first_bin_done}) {
                $cost = $self->_get_cost('request_replace_cost_more') || $cost/2;
            } else {
                $data->{first_bin_done} = 1;
            }
        }
        $c->set_param('payment', $cost);
    }
}

=head2 request_cost

Calculate how much, if anything, a request for a container should be.

=cut

sub request_cost {
    my ($self, $id, $quantity, $containers) = @_;
    $quantity //= 1;
    if (my $cost = $self->_get_cost('request_replace_cost')) {
        my $cost_more = $self->_get_cost('request_replace_cost_more') || $cost/2;
        if ($quantity > 1) {
            $cost += $cost_more * ($quantity-1);
        }
        my $names = $self->{c}->stash->{containers};
        if ($names->{$id} !~ /bag|sack|food/i) {
            my $hint = "";
            return ($cost, $hint);
        }
    }
}

=head2 Bulky waste collection

Kingston starts collections at 6:30am, and lets you cancel up until then.

=cut

sub bulky_collection_time { { hours => 6, minutes => 30 } }
sub bulky_cancellation_cutoff_time { { hours => 6, minutes => 30, days_before => 0 } }

1;
