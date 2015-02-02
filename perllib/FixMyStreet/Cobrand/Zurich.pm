package FixMyStreet::Cobrand::Zurich;
use base 'FixMyStreet::Cobrand::Default';

use DateTime;
use POSIX qw(strcoll);
use RABX;
use Scalar::Util 'blessed';
use DateTime::Format::Pg;

use strict;
use warnings;
use utf8;

=head1 NAME

Zurich FixMyStreet cobrand

=head1 DESCRIPTION

This module provides the specific functionality for the Zurich FMS cobrand.

=head1 DEVELOPMENT NOTES

The admin for Zurich is different to the other cobrands. To access it you need
to be logged in as a user associated with an appropriate body.

You can create the bodies needed to develop by running the 't/cobrand/zurich.t'
test script with the three C<$mech->delete...> lines at the end commented out.
This should leave you with the bodies and users correctly set up.

The entries will be something like this (but with different ids).

    Bodies:
         id |     name      | parent |         endpoint
        ----+---------------+--------+---------------------------
          1 | Zurich        |        |
          2 | Division 1    |      1 | division@example.org
          3 | Subdivision A |      2 | subdivision@example.org
          4 | External Body |        | external_body@example.org

    Users:
         id |      email       | from_body
        ----+------------------+-----------
          1 | super@example.org|         1
          2 | dm1@example.org  |         2
          3 | sdm1@example.org |         3

The passwords for the users is 'secret'.

Note: the password hashes are salted with the user's id so cannot be easily
changed. High ids have been used so that it should not conflict with anything
you already have, and the countres set so that they shouldn't in future.

=cut

sub shorten_recency_if_new_greater_than_fixed {
    return 0;
}

sub pin_colour {
    my ( $self, $p, $context ) = @_;
    return 'green' if $p->is_fixed || $p->is_closed;
    return 'red' if $p->state eq 'unconfirmed' || $p->state eq 'confirmed';
    return 'yellow';
}

# This isn't used
sub find_closest {
    my ( $self, $latitude, $longitude, $problem ) = @_;
    return '';
}

sub enter_postcode_text {
    my ( $self ) = @_;
    return _('Enter a Z&uuml;rich street name');
}

sub example_places {
    return [ 'Langstrasse', 'Basteiplatz' ];
}

sub languages { [ 'de-ch,Deutsch,de_CH' ] }
sub language_override { 'de-ch' }

# If lat/lon are in the URI, we must have zoom as well, otherwise OpenLayers defaults to 0.
sub uri {
    my ( $self, $uri ) = @_;

    $uri->query_param( zoom => 6 )
      if $uri->query_param('lat') && !$uri->query_param('zoom');
    return $uri;
}

sub prettify_dt {
    my $self = shift;
    my $dt = shift;

    return Utils::prettify_dt( $dt, 'zurich' );
}

# problem already has a concept of is_fixed/is_closed, but Zurich has different
# workflow for this here.
# 
# TODO: look at more elegant way of doing this, for example having ::DB::Problem
# consider cobrand specific state config?

sub zurich_closed_states {
    my $states = {
        'fixed - council' => 1,
        'closed'          => 1,
        'hidden'          => 1,
    };

    return wantarray ? keys %{ $states } : $states;
}

sub problem_is_closed {
    my ($self, $problem) = @_;
    return exists $self->zurich_closed_states->{ $problem->state } ? 1 : 0;
}

sub problem_as_hashref {
    my $self = shift;
    my $problem = shift;
    my $ctx = shift;

    my $hashref = $problem->as_hashref( $ctx );

    if ( $problem->state eq 'unconfirmed' ) {
        for my $var ( qw( photo detail state state_t is_fixed meta ) ) {
            delete $hashref->{ $var };
        }
        $hashref->{detail} = _('This report is awaiting moderation.');
        $hashref->{title} = _('This report is awaiting moderation.');
        $hashref->{state} = 'submitted';
        $hashref->{state_t} = _('Submitted');
        $hashref->{banner_id} = 'closed';
    } else {
        if ( $problem->state eq 'confirmed' ) {
            $hashref->{state} = 'open';
            $hashref->{state_t} = _('Open');
            $hashref->{banner_id} = 'closed';
        } elsif ( $problem->state eq 'closed' ) {
            $hashref->{state} = 'extern'; # is this correct?
            $hashref->{banner_id} = 'closed';
            $hashref->{state_t} = _('Extern');
        } elsif ( $problem->state eq 'unable to fix' ) {
            $hashref->{state} = 'jurisdiction unknown'; # is this correct?
            $hashref->{state_t} = _('Jurisdiction Unknown');
            $hashref->{banner_id} = 'fixed'; # green
        } elsif ( $problem->state eq 'partial' ) {
            $hashref->{state} = 'not contactable'; # is this correct?
            $hashref->{state_t} = _('Not contactable');
            # no banner_id as hidden
        } elsif ( $problem->state eq 'investigating' ) {
            $hashref->{state} = 'wish'; # is this correct?
            $hashref->{state_t} = _('Wish');
        } elsif ( $problem->is_fixed ) {
            $hashref->{state} = 'closed';
            $hashref->{banner_id} = 'fixed';
            $hashref->{state_t} = _('Closed');
        } elsif ( $problem->state eq 'in progress' || $problem->state eq 'planned' ) {
            $hashref->{state} = 'in progress';
            $hashref->{state_t} = _('In progress');
            $hashref->{banner_id} = 'progress';
        }
    }

    return $hashref;
}

sub updates_as_hashref {
    my $self = shift;
    my $problem = shift;
    my $ctx = shift;

    my $hashref = {};

    if ( $problem->state eq 'fixed - council' || $problem->state eq 'closed' ) {
        $hashref->{update_pp} = $self->prettify_dt( $problem->lastupdate );

        if ( $problem->state eq 'fixed - council' ) {
            $hashref->{details} = FixMyStreet::App::View::Web->add_links(
                $ctx, $problem->get_extra_metadata('public_response') || '' );
        } elsif ( $problem->state eq 'closed' ) {
            $hashref->{details} = sprintf( _('Assigned to %s'), $problem->body($ctx)->name );
        }
    }

    return $hashref;
}

sub allow_photo_display {
    my ( $self, $r ) = @_;
    if (blessed $r) {
        return $r->get_extra_metadata( 'publish_photo' );
    }

    # additional munging in case $r isn't an object, TODO see if we can remove this
    my $extra = $r->{extra};
    utf8::encode($extra) if utf8::is_utf8($extra);
    my $h = new IO::String($extra);
    $extra = RABX::wire_rd($h);
    return unless ref $extra eq 'HASH';
    return $extra->{publish_photo};
}

sub show_unconfirmed_reports {
    1;
}

sub get_body_sender {
    my ( $self, $body, $category ) = @_;
    return { method => 'Zurich' };
}

# Report overdue functions

my %public_holidays = map { $_ => 1 } (
    '2013-01-01', '2013-01-02', '2013-03-29', '2013-04-01',
    '2013-04-15', '2013-05-01', '2013-05-09', '2013-05-20',
    '2013-08-01', '2013-09-09', '2013-12-25', '2013-12-26',
    '2014-01-01', '2014-01-02', '2014-04-18', '2014-04-21',
    '2014-04-28', '2014-05-01', '2014-05-29', '2014-06-09',
    '2014-08-01', '2014-09-15', '2014-12-25', '2014-12-26',
);

sub is_public_holiday {
    my $dt = shift;
    return $public_holidays{$dt->ymd};
}

sub is_weekend {
    my $dt = shift;
    return $dt->dow > 5;
}

sub add_days {
    my ( $dt, $days ) = @_;
    $dt = $dt->clone;
    while ( $days > 0 ) {
        $dt->add ( days => 1 );
        next if is_public_holiday($dt) or is_weekend($dt);
        $days--;
    }
    return $dt;
}

sub sub_days {
    my ( $dt, $days ) = @_;
    $dt = $dt->clone;
    while ( $days > 0 ) {
        $dt->subtract ( days => 1 );
        next if is_public_holiday($dt) or is_weekend($dt);
        $days--;
    }
    return $dt;
}

sub overdue {
    my ( $self, $problem ) = @_;

    my $w = $problem->created;
    return 0 unless $w;

    # call with previous state
    if ( $problem->state eq 'unconfirmed' ) {
        # One working day
        $w = add_days( $w, 1 );
        return $w < DateTime->now() ? 1 : 0;
    } elsif ( $problem->state eq 'confirmed' || $problem->state eq 'in progress' || $problem->state eq 'planned' ) {
        # States which affect the subdiv_overdue statistic.  TODO: this may no longer be required
        # Six working days from creation
        $w = add_days( $w, 6 );
        return $w < DateTime->now() ? 1 : 0;

    # call with new state
    } elsif ( $self->problem_is_closed($problem) ) {
        # States which affect the closed_overdue statistic
        # Five working days from moderation (so 6 from creation)

        $w = add_days( $w, 6 );
        return $w < DateTime->now() ? 1 : 0;
    } else {
        return 0;
    }
}

sub get_or_check_overdue {
    my ($self, $problem) = @_;

    # use the cached version is it exists (e.g. when called from template)
    my $overdue = $problem->get_extra_metadata('closed_overdue');
    return $overdue if defined $overdue;

    return $self->overdue($problem);
}

=head1 C<set_problem_state>

If the state has changed, sets the state and calls C::Admin's C<log_edit> action.
If the state hasn't changed, defers to update_admin_log (to update time_spent if any).

Returns either undef or the AdminLog entry created.

=cut

sub set_problem_state {
    my ($self, $c, $problem, $new_state) = @_;
    return $self->update_admin_log($c, $problem) if $new_state eq $problem->state;
    $problem->state( $new_state );
    $c->forward( 'log_edit', [ $problem->id, 'problem', "state change to $new_state" ] );
}

=head1 C<update_admin_log>

Calls C::Admin's C<log_edit> if either a) text is provided, or b) there has
been time_spent on the task.  As set_problem_state will already call log_edit
if required, don't call this as well.

Returns either undef or the AdminLog entry created.

=cut

sub update_admin_log {
    my ($self, $c, $problem, $text) = @_;

    my $time_spent = ( ($c->req->param('time_spent') // 0) + 0 );
    $c->req->param('time_spent' => 0); # explicitly zero this to avoid duplicates

    if (!$text) {
        return unless $time_spent;
        $text = "Logging time_spent";
    }

    $c->forward( 'log_edit', [ $problem->id, 'problem', $text, $time_spent ] );
}

# Specific administrative displays

sub admin_pages {
    my $self = shift;
    my $c = $self->{c};

    my $type = $c->stash->{admin_type};
    my $pages = {
        'summary' => [_('Summary'), 0],
        'reports' => [_('Reports'), 2],
        'report_edit' => [undef, undef],
        'update_edit' => [undef, undef],
    };
    return $pages if $type eq 'sdm';

    $pages = { %$pages,
        'bodies' => [_('Bodies'), 1],
        'body' => [undef, undef],
        'templates' => [_('Templates'), 2],
    };
    return $pages if $type eq 'dm';

    $pages = { %$pages,
        'users' => [_('Users'), 3],
        'stats' => [_('Stats'), 4],
        'user_edit' => [undef, undef],
    };
    return $pages if $type eq 'super';
}

sub admin_type {
    my $self = shift;
    my $c = $self->{c};
    my $body = $c->user->from_body;
    $c->stash->{body} = $body;

    my $type;
    my $parent = $body->parent;
    if (!$parent) {
        $type = 'super';
    } else {
        my $grandparent = $parent->parent;
        $type = $grandparent ? 'sdm' : 'dm';
    }

    $c->stash->{admin_type} = $type;
    return $type;
}

sub admin {
    my $self = shift;
    my $c = $self->{c};
    my $type = $c->stash->{admin_type};

    if ($type eq 'dm') {
        $c->stash->{template} = 'admin/index-dm.html';

        my $body = $c->stash->{body};
        my @children = map { $_->id } $body->bodies->all;
        my @all = (@children, $body->id);

        my $order = $c->req->params->{o} || 'created';
        my $dir = defined $c->req->params->{d} ? $c->req->params->{d} : 1;
        $c->stash->{order} = $order;
        $c->stash->{dir} = $dir;
        $order .= ' desc' if $dir;

        # XXX No multiples or missing bodies
        $c->stash->{unconfirmed} = $c->cobrand->problems->search({
            state => [ 'unconfirmed', 'confirmed' ],
            bodies_str => $c->stash->{body}->id,
        }, {
            order_by => $order,
        });
        $c->stash->{approval} = $c->cobrand->problems->search({
            state => 'planned',
            bodies_str => $c->stash->{body}->id,
        }, {
            order_by => $order,
        });

        my $page = $c->req->params->{p} || 1;
        $c->stash->{other} = $c->cobrand->problems->search({
            state => { -not_in => [ 'unconfirmed', 'confirmed', 'planned' ] },
            bodies_str => \@all,
        }, {
            order_by => $order,
        })->page( $page );
        $c->stash->{pager} = $c->stash->{other}->pager;

    } elsif ($type eq 'sdm') {
        $c->stash->{template} = 'admin/index-sdm.html';

        my $body = $c->stash->{body};

        my $order = $c->req->params->{o} || 'created';
        my $dir = defined $c->req->params->{d} ? $c->req->params->{d} : 1;
        $c->stash->{order} = $order;
        $c->stash->{dir} = $dir;
        $order .= ' desc' if $dir;

        # XXX No multiples or missing bodies
        $c->stash->{reports_new} = $c->cobrand->problems->search( {
            state => 'in progress',
            bodies_str => $body->id,
        }, {
            order_by => $order
        } );
        $c->stash->{reports_unpublished} = $c->cobrand->problems->search( {
            state => 'planned',
            bodies_str => $body->parent->id,
        }, {
            order_by => $order
        } );

        my $page = $c->req->params->{p} || 1;
        $c->stash->{reports_published} = $c->cobrand->problems->search( {
            state => 'fixed - council',
            bodies_str => $body->parent->id,
        }, {
            order_by => $order
        } )->page( $page );
        $c->stash->{pager} = $c->stash->{reports_published}->pager;
    }
}

sub admin_report_edit {
    my $self = shift;
    my $c = $self->{c};
    my $type = $c->stash->{admin_type};

    my $problem = $c->stash->{problem};
    my $body = $c->stash->{body};

    if ($type ne 'super') {
        my %allowed_bodies = map { $_->id => 1 } ( $body->bodies->all, $body );
        $c->detach( '/page_error_404_not_found' )
          unless $allowed_bodies{$problem->bodies_str};
    }

    if ($type eq 'super') {

        my @bodies = $c->model('DB::Body')->all();
        @bodies = sort { strcoll($a->name, $b->name) } @bodies;
        $c->stash->{bodies} = \@bodies;

        # Can change category to any other
        my @categories = $c->model('DB::Contact')->not_deleted->all;
        $c->stash->{categories} = [ map { $_->category } @categories ];

    } elsif ($type eq 'dm') {

        # Can assign to:
        my @bodies = $c->model('DB::Body')->search( [
            { 'me.parent' => $body->parent->id }, # Other DMs on the same level
            { 'me.parent' => $body->id }, # Their subdivisions
            { 'me.parent' => undef, 'bodies.id' => undef }, # External bodies
        ], { join => 'bodies', distinct => 1 } );
        @bodies = sort { strcoll($a->name, $b->name) } @bodies;
        $c->stash->{bodies} = \@bodies;

        # Can change category to any other
        my @categories = $c->model('DB::Contact')->not_deleted->all;
        $c->stash->{categories} = [ map { $_->category } @categories ];

    }

    # If super or dm check that the token is correct before proceeding
    if ( ($type eq 'super' || $type eq 'dm') && $c->req->param('submit') ) {
        $c->forward('check_token');
    }

    # All types of users can add internal notes
    if ( ($type eq 'super' || $type eq 'dm' || $type eq 'sdm') && $c->req->param('submit') ) {
        # If there is a new note add it as a comment to the problem (with is_internal_note set true in extra).
        if ( my $new_internal_note = $c->req->params->{new_internal_note} ) {
            $problem->add_to_comments( {
                text => $new_internal_note,
                user => $c->user->obj,
                state => 'hidden', # seems best fit, should not be shown publicly
                mark_fixed => 0,
                anonymous => 1,
                extra => { is_internal_note => 1 },
            } );
        }
    }

    # Problem updates upon submission
    if ( ($type eq 'super' || $type eq 'dm') && $c->req->param('submit') ) {
        $problem->set_extra_metadata('publish_photo' => $c->req->params->{publish_photo} || 0 );
        $problem->set_extra_metadata('third_personal' => $c->req->params->{third_personal} || 0 );

        # Make sure we have a copy of the original detail field
        if (my $new_detail = $c->req->params->{detail}) {
            my $old_detail = $problem->detail;
            if (! $problem->get_extra_metadata('original_detail')
                && ($old_detail ne $new_detail))
            {
                $problem->set_extra_metadata( original_detail => $old_detail );
            }
        }

        # Some changes will be accompanied by an internal note, which if needed
        # should be stored in this variable.
        my $internal_note_text = "";

        # Workflow things
        #
        #   Note that 2 types of email may be sent
        #    1) _admin_send_email()  sends an email to the *user*, if their email is confirmed
        #    2) setting $problem->whensent(undef) may make it eligible for generating an email
        #   to the body (internal or external).  See DBRS::Problem->send_reports for Zurich-
        #   specific categories which are eligible for this.

        my $redirect = 0;
        my $new_cat = $c->req->params->{category} || '';
        my $state = $c->req->params->{state} || '';

        if (
            ($state eq 'confirmed') 
            && $new_cat
            && $new_cat ne $problem->category
        ) {
            my $cat = $c->model('DB::Contact')->search({ category => $c->req->params->{category} } )->first;
            my $old_cat = $problem->category;
            $problem->category( $new_cat );
            $problem->external_body( undef );
            $problem->bodies_str( $cat->body_id );
            $problem->whensent( undef );
            $problem->set_extra_metadata(changed_category => 1);
            $internal_note_text = "Weitergeleitet von $old_cat an $new_cat";
            $self->update_admin_log($c, $problem, "Changed category from $old_cat to $new_cat");
            $redirect = 1 if $cat->body_id ne $body->id;
        } elsif ( my $subdiv = $c->req->params->{body_subdivision} ) {
            $problem->set_extra_metadata_if_undefined( moderated_overdue => $self->overdue( $problem ) );
            $self->set_problem_state($c, $problem, 'in progress');
            $problem->external_body( undef );
            $problem->bodies_str( $subdiv );
            $problem->whensent( undef );
            $redirect = 1;
        } elsif ( my $external = $c->req->params->{body_external} and $state =~/^(closed|investigating)$/) {
            # Extern | Wish
            my $external_body = $c->model('DB::Body')->find($external)
                or die "Body $external not found";
            $problem->set_extra_metadata_if_undefined( moderated_overdue => $self->overdue( $problem ) );
            $problem->set_extra_metadata_if_undefined( closed_overdue => $self->overdue( $problem ) );
            $problem->external_body( $external );
            $problem->whensent( undef );
            $self->set_problem_state($c, $problem, $state);
            if ( my $external_message = $c->req->params->{external_message} ) {
                $problem->add_to_comments( {
                    text => (
                        sprintf '(%s %s) %s',
                        $state eq 'closed' ?
                            _('Forwarded to external body') :
                            _('Forwarded wish to external body'),
                        $external_body->name,
                        $external_message,
                    ),
                    user => $c->user->obj,
                    state => 'hidden', # seems best fit, should not be shown publicly
                    mark_fixed => 0,
                    anonymous => 1,
                    extra => { is_internal_note => 1, is_external_message => 1 },
                } );
                # set the external_message in extra, so that it will be picked up
                # later by send-reports
                $problem->set_extra_metadata( external_message => $external_message );
            }
            my $template = ($state eq 'investigating') ? 'problem-wish.txt' : 'problem-external.txt';
            _admin_send_email( $c, $template, $problem );
            $redirect = 1;
        } else {
            if ($state) {

                if ($problem->state eq 'unconfirmed' and $state ne 'unconfirmed') {
                    # only set this for the first state change
                    $problem->set_extra_metadata_if_undefined( moderated_overdue => $self->overdue( $problem ) );
                }

                $self->set_problem_state($c, $problem, $state);

                if ($self->problem_is_closed($problem)) {
                    $problem->set_extra_metadata_if_undefined( closed_overdue => $self->overdue( $problem ) );
                }
                if ( $state eq 'hidden' && $c->req->params->{send_rejected_email} ) {
                    _admin_send_email( $c, 'problem-rejected.txt', $problem );
                }
            }
        }

        $problem->title( $c->req->param('title') );
        $problem->detail( $c->req->param('detail') );
        $problem->latitude( $c->req->param('latitude') );
        $problem->longitude( $c->req->param('longitude') );

        # Final, public, Update from DM
        if (my $update = $c->req->param('status_update')) {
            $problem->set_extra_metadata(public_response => $update);
            if ($c->req->params->{publish_response}) {
                $self->set_problem_state($c, $problem, 'fixed - council');
                $problem->set_extra_metadata_if_undefined( closed_overdue => $self->overdue( $problem ) );
                _admin_send_email( $c, 'problem-closed.txt', $problem );
            }
        }
        $c->stash->{default_public_response} = "\nFreundliche Grüsse\n\nIhre Stadt Zürich\n";

        $problem->lastupdate( \'ms_current_timestamp()' );
        $problem->update;

        $c->stash->{status_message} =
          '<p><em>' . _('Updated!') . '</em></p>';

        # do this here otherwise lastupdate and confirmed times
        # do not display correctly (reloads problem from database, including
        # fields modified by the database when saving)
        $problem->discard_changes;

        # Create an internal note if required
        if ($internal_note_text) {
            $problem->add_to_comments( {
                text => $internal_note_text,
                user => $c->user->obj,
                state => 'hidden', # seems best fit, should not be shown publicly
                mark_fixed => 0,
                anonymous => 1,
                extra => { is_internal_note => 1 },
            } );
        }

        # Just update if time_spent still hasn't been logged
        # (this will only happen if no other update_admin_log has already been called)
        $self->update_admin_log($c, $problem);

        if ( $redirect ) {
            $c->detach('index');
        }

        $c->stash->{updates} = [ $c->model('DB::Comment')
          ->search( { problem_id => $problem->id }, { order_by => 'created' } )
          ->all ];

        $self->stash_states($problem);
        return 1;
    }

    if ($type eq 'sdm') {

        # Has cut-down edit template for adding update and sending back up only
        $c->stash->{template} = 'admin/report_edit-sdm.html';

        if ($c->req->param('send_back') or $c->req->param('not_contactable')) {
            # SDM can send back a report either to be assigned to a different
            # subdivision, or because the customer was not contactable.
            # We handle these in the same way but with different statuses.

            $c->forward('check_token');

            my $not_contactable = $c->req->param('not_contactable');

            $problem->bodies_str( $body->parent->id );
            my $new_state = $not_contactable ? 'partial' : 'confirmed';
            $self->set_problem_state($c, $problem, $new_state);
            $problem->update;
            $c->forward( 'log_edit', [ $problem->id, 'problem', 
                $not_contactable ?
                    _('Customer not contactable')
                    : _('Sent report back') ] );
            $c->res->redirect( '/admin/summary' );
        } elsif ($c->req->param('submit')) {
            $c->forward('check_token');

            my $db_update = 0;
            if ( $c->req->param('latitude') != $problem->latitude || $c->req->param('longitude') != $problem->longitude ) {
                $problem->latitude( $c->req->param('latitude') );
                $problem->longitude( $c->req->param('longitude') );
                $db_update = 1;
            }

            $problem->update if $db_update;

            # Add new update from status_update
            if (my $update = $c->req->param('status_update')) {
                FixMyStreet::App->model('DB::Comment')->create( {
                    text => $update,
                    user => $c->user->obj,
                    state => 'unconfirmed',
                    problem => $problem,
                    mark_fixed => 0,
                    problem_state => 'fixed - council',
                    anonymous => 1,
                } );
            }

            $c->stash->{status_message} = '<p><em>' . _('Updated!') . '</em></p>';

            # If they clicked the no more updates button, we're done.
            if ($c->req->param('no_more_updates')) {
                $problem->set_extra_metadata_if_undefined( subdiv_overdue => $self->overdue( $problem ) );
                $problem->bodies_str( $body->parent->id );
                $problem->whensent( undef );
                $self->set_problem_state($c, $problem, 'planned');
                $problem->update;
                $c->res->redirect( '/admin/summary' );
            }
        }

        $c->stash->{updates} = [ $c->model('DB::Comment')
            ->search( { problem_id => $problem->id }, { order_by => 'created' } )
            ->all ];

        $self->stash_states($problem);
        return 1;

    }

    $self->stash_states($problem);
    return 0;

}

sub stash_states {
    my ($self, $problem) = @_;
    my $c = $self->{c};

    # current problem state affects which states are visible in dropdowns
    my @states = (
        {
            # Erfasst
            state => 'unconfirmed',
            trans => _('Submitted'),
            unconfirmed => 1,
            hidden => 1,
        },
        {
            # Aufgenommen
            state => 'confirmed',
            trans => _('Open'),
            unconfirmed => 1,
        },
        {
            # Rueckmeldung ausstehend
            state => 'planned',
            trans => _('Planned'),
        },
        {
            # Unsichtbar (hidden)
            state => 'hidden',
            trans => _('Hidden'),
            unconfirmed => 1,
            hidden => 1,
        },
        {
            # Extern
            state => 'closed',
            trans => _('Extern'),
        },
        {
            # Zustaendigkeit unbekannt
            state => 'unable to fix',
            trans => _('Jurisdiction unknown'),
        },
        {
            # Wunsch (hidden)
            state => 'investigating',
            trans => _('Wish'),
        },
        {
            # Nicht kontaktierbar (hidden)
            state => 'partial',
            trans => _('Not contactable'),
        },
    );
    my $state = $problem->state;
    if ($state eq 'in progress') {
        push @states, {
            state => 'in progress',
            trans => _('In progress'),
        };
    }
    elsif ($state eq 'fixed - council') {
        push @states, {
            state => 'fixed - council',
            trans => _('Closed'),
        };
    }
    elsif ($state =~/^(hidden|unconfirmed)$/) {
        @states = grep { $_->{$state} } @states;
    }
    $c->stash->{states} = \@states;
    $c->stash->{states_debug} = Dumper($state, \@states); use Data::Dumper;
}

=head2 _admin_send_email

Send an email to the B<user> who logged the problem, if their email address is confirmed.

=cut

sub _admin_send_email {
    my ( $c, $template, $problem ) = @_;

    return unless $problem->get_extra_metadata('email_confirmed');

    my $to = $problem->name
        ? [ $problem->user->email, $problem->name ]
        : $problem->user->email;

    # Similar to what SendReport::Zurich does to find address to send to
    my $body = ( values %{$problem->bodies} )[0];
    my $sender = $body->endpoint || $c->cobrand->contact_email;
    my $sender_name = $c->cobrand->contact_name; # $body->name?

    $c->send_email( $template, {
        to => [ $to ],
        url => $c->uri_for_email( $problem->url ),
        from => [ $sender, $sender_name ],
    } );
}

sub admin_fetch_all_bodies {
    my ( $self, @bodies ) = @_;

    sub tree_sort {
        my ( $level, $id, $sorted, $out ) = @_;

        my @sorted;
        my $array = $sorted->{$id};
        if ( $level == 0 ) {
            @sorted = sort {
                # Want Zurich itself at the top.
                return -1 if $sorted->{$a->id};
                return 1 if $sorted->{$b->id};
                # Otherwise, by name
                strcoll($a->name, $b->name)
            } @$array;
        } else {
            @sorted = sort { strcoll($a->name, $b->name) } @$array;
        }
        foreach ( @sorted ) {
            $_->api_key( $level ); # Misuse
            push @$out, $_;
            if ($sorted->{$_->id}) {
                tree_sort( $level+1, $_->id, $sorted, $out );
            }
        }
    }

    my %sorted;
    foreach (@bodies) {
        my $p = $_->parent ? $_->parent->id : 0;
        push @{$sorted{$p}}, $_;
    }

    my @out;
    tree_sort( 0, 0, \%sorted, \@out );
    return @out;
}

sub admin_stats {
    my $self = shift;
    my $c = $self->{c};

    my %date_params;
    my $ym = $c->req->params->{ym};
    my ($m, $y) = $ym ? ($ym =~ /^(\d+)\.(\d+)$/) : ();
    $c->stash->{ym} = $ym;
    if ($y && $m) {
        $c->stash->{start_date} = DateTime->new( year => $y, month => $m, day => 1 );
        $c->stash->{end_date} = $c->stash->{start_date} + DateTime::Duration->new( months => 1 );
        $date_params{created} = {
            '>=', DateTime::Format::Pg->format_datetime($c->stash->{start_date}), 
            '<',  DateTime::Format::Pg->format_datetime($c->stash->{end_date}),
        };
    }

    my %params = (
        %date_params,
        state => [ FixMyStreet::DB::Result::Problem->visible_states() ],
    );

    if ( $c->req->params->{export} ) {
        my $problems = $c->model('DB::Problem')->search(
            {%date_params},
            {
                join => 'admin_log_entries',
                distinct => 1,
                columns => [
                    'id',       'created',
                    'latitude', 'longitude',
                    'cobrand',  'category',
                    'state',    'user_id',
                    'external_body',
                    { sum_time_spent => { sum => 'admin_log_entries.time_spent' } },
                ]
            }
        );
        my $body = "ID,Created,E,N,Category,Status,UserID,External Body\n";
        while ( my $report = $problems->next ) {
            my $external_body;
            my $body_name = "";
            if ( $external_body = $report->body($c) ) {
                $body_name = $external_body->name;
            }
            $body .= join( ',',
                $report->id,           $report->created,
                $report->local_coords, $report->category,
                $report->state,        $report->user_id,
                "\"$body_name\"",
                $report->get_column('sum_time_spent') || 0,
            ) . "\n";
        }
        $c->res->content_type('text/csv; charset=utf-8');
        $c->res->body($body);
    }

    # Total reports (non-hidden)
    my $total = $c->model('DB::Problem')->search( \%params )->count;
    # Device for apps (iOS/Android)
    my $per_service = $c->model('DB::Problem')->search( \%params, {
        select   => [ 'service', { count => 'id' } ],
        as       => [ 'service', 'c' ],
        group_by => [ 'service' ],
    });
    # Reports solved
    my $solved = $c->model('DB::Problem')->search( { state => 'fixed - council', %date_params } )->count;
    # Reports marked as spam
    my $hidden = $c->model('DB::Problem')->search( { state => 'hidden', %date_params } )->count;
    # Reports assigned to third party
    my $closed = $c->model('DB::Problem')->search( { state => 'closed', %date_params } )->count;
    # Reports moderated within 1 day
    my $moderated = $c->model('DB::Problem')->search( { extra => { like => '%moderated_overdue,I1:0%' }, %date_params } )->count;
    # Reports solved within 5 days (sent back from subdiv)
    my $subdiv_dealtwith = $c->model('DB::Problem')->search( { extra => { like => '%subdiv_overdue,I1:0%' }, %params } )->count;
    # Reports solved within 5 days (marked as 'fixed - council', 'closed', or 'hidden'
    my $fixed_in_time = $c->model('DB::Problem')->search( { extra => { like => '%closed_overdue,I1:0%' }, %date_params } )->count;
    # Reports per category
    my $per_category = $c->model('DB::Problem')->search( \%params, {
        select   => [ 'category', { count => 'id' } ],
        as       => [ 'category', 'c' ],
        group_by => [ 'category' ],
    });
    # How many reports have had their category changed by a DM (wrong category chosen by user)
    my $changed = $c->model('DB::Problem')->search( { extra => { like => '%changed_category,I1:1%' }, %params } )->count;
    # pictures taken
    my $pictures_taken = $c->model('DB::Problem')->search( { photo => { '!=', undef }, %params } )->count;
    # pictures published
    my $pictures_published = $c->model('DB::Problem')->search( { extra => { like => '%publish_photo,I1:1%' }, %params } )->count;
    # how many times was a telephone number provided
    # XXX => How many users have a telephone number stored
    # my $phone = $c->model('DB::User')->search( { phone => { '!=', undef } } )->count;
    # how many times was the email address confirmed
    my $email_confirmed = $c->model('DB::Problem')->search( { extra => { like => '%email_confirmed%' }, %params } )->count;
    # how many times was the name provided
    my $name = $c->model('DB::Problem')->search( { name => { '!=', '' }, %params } )->count;
    # how many times was the geolocation used vs. addresssearch
    # ?

    $c->stash(
        per_service => $per_service,
        per_category => $per_category,
        reports_total => $total,
        reports_solved => $solved,
        reports_spam => $hidden,
        reports_assigned => $closed,
        reports_moderated => $moderated,
        reports_dealtwith => $fixed_in_time,
        reports_category_changed => $changed,
        pictures_taken => $pictures_taken,
        pictures_published => $pictures_published,
        #users_phone => $phone,
        email_confirmed => $email_confirmed,
        name_provided => $name,
        # GEO
    );

    return 1;
}

1;
