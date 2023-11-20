use FixMyStreet::TestMech;
use FixMyStreet::Script::CSVExport;
use FixMyStreet::Script::Reports;
use File::Temp 'tempdir';
use Test::MockModule;
use CGI::Simple;
use Test::LongString;
use Open311::PostServiceRequestUpdates;
use t::Mock::Nominatim;

my $mock = Test::MockModule->new('FixMyStreet::Cobrand::Peterborough');
$mock->mock('_fetch_features', sub {
    my ($self, $args, $x, $y) = @_;
    if ( $args->{type} && $args->{type} eq 'arcgis' ) {
        # council land
        if ( $x == 552617 && $args->{url} =~ m{4/query} ) {
            return [ { geometry => { type => 'Point' } } ];
        # leased out council land
        } elsif ( $x == 552651 && $args->{url} =~ m{3/query} ) {
            return [ { geometry => { type => 'Point' } } ];
        # adopted roads
        } elsif ( $x == 552721 && $args->{url} =~ m{7/query} ) {
            return [ { geometry => { type => 'Point' } } ];
        }
        return [];
    }
    return [];
});

my $mech = FixMyStreet::TestMech->new;

my $params = {
    send_method => 'Open311',
    send_comments => 1,
    api_key => 'KEY',
    endpoint => 'endpoint',
    jurisdiction => 'home',
    can_be_devolved => 1,
};
my $peterborough = $mech->create_body_ok(2566, 'Peterborough City Council', $params, { cobrand => 'peterborough' });
my $contact = $mech->create_contact_ok(email => 'FLY', body_id => $peterborough->id, category => 'General fly tipping');
my $hazardous_flytipping_contact = $mech->create_contact_ok(email => 'HAZ', body_id => $peterborough->id, category => 'Hazardous fly tipping');
my $offensive_graffiti_contact = $mech->create_contact_ok(
    body_id  => $peterborough->id,
    category => 'Offensive graffiti',
    email    => 'OFF',
);
my $non_offensive_graffiti_contact = $mech->create_contact_ok(
    body_id  => $peterborough->id,
    category => 'Non offensive graffiti',
    email    => 'NON',
);
my $user = $mech->create_user_ok('peterborough@example.org', name => 'Council User', from_body => $peterborough);
$peterborough->update( { comment_user_id => $user->id } );

my $staffuser = $mech->create_user_ok('counciluser@example.com', name => 'Council User', from_body => $peterborough);

subtest 'open311 request handling', sub {
    FixMyStreet::override_config {
        STAGING_FLAGS => { send_reports => 1 },
        ALLOWED_COBRANDS => ['peterborough' ],
        MAPIT_URL => 'http://mapit.uk/',
    }, sub {
        my $contact = $mech->create_contact_ok(body_id => $peterborough->id, category => 'Trees', email => 'TREES',
            extra => { _fields => [
                { description => 'emergency', code => 'emergency', required => 'true', variable => 'true' },
                { description => 'private land', code => 'private_land', required => 'true', variable => 'true' },
                { description => 'Light', code => 'PCC-light', required => 'true', automated => 'hidden_field' },
                { description => 'CSC Ref', code => 'PCC-skanska-csc-ref', required => 'false', variable => 'true', },
                { description => 'Tree code', code => 'colour', required => 'True', automated => 'hidden_field' },
            ] },
        );
        my ($p) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', { category => 'Trees', latitude => 52.5608, longitude => 0.2405, cobrand => 'peterborough' });
        $p->push_extra_fields({ name => 'emergency', value => 'no'});
        $p->push_extra_fields({ name => 'private_land', value => 'no'});
        $p->push_extra_fields({ name => 'PCC-light', value => 'whatever'});
        $p->push_extra_fields({ name => 'PCC-skanska-csc-ref', value => '1234'});
        $p->push_extra_fields({ name => 'tree_code', value => 'tree-42'});
        $p->update;

        FixMyStreet::Script::Reports::send();

        $p->discard_changes;
        is $p->send_state, 'sent', 'Report marked as sent';
        is $p->send_method_used, 'Open311', 'Report sent via Open311';
        is $p->external_id, 248, 'Report has correct external ID';
        is $p->get_extra_field_value('emergency'), 'no';

        my $req = Open311->test_req_used;
        my $c = CGI::Simple->new($req->content);
        is $c->param('attribute[description]'), "Title Test 1 for " . $peterborough->id . " Detail\r\n\r\nSkanska CSC ref: 1234", 'Ref added to description';
        is $c->param('attribute[emergency]'), undef, 'no emergency param sent';
        is $c->param('attribute[private_land]'), undef, 'no private_land param sent';
        is $c->param('attribute[PCC-light]'), undef, 'no pcc- param sent';
        is $c->param('attribute[tree_code]'), 'tree-42', 'tree_code param sent';
    };
};

subtest "extra update params are sent to open311" => sub {
    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
    }, sub {
        my $contact = $mech->create_contact_ok(body_id => $peterborough->id, category => 'Trees', email => 'TREES');
        Open311->_inject_response('servicerequestupdates.xml', '<?xml version="1.0" encoding="utf-8"?><service_request_updates><request_update><update_id>ezytreev-248</update_id></request_update></service_request_updates>');

        my $o = Open311->new(
            fixmystreet_body => $peterborough,
        );

        my ($p) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', {
            external_id => 1, category => 'Trees', send_state => 'sent',
            send_method_used => "Open311", cobrand => 'peterborough' });

        my $c = FixMyStreet::DB->resultset('Comment')->create({
            problem => $p, user => $p->user, anonymous => 't', text => 'Update text',
            problem_state => 'fixed - council', state => 'confirmed', mark_fixed => 0,
            confirmed => DateTime->now(),
        });

        my $id = $o->post_service_request_update($c);
        is $id, "ezytreev-248", 'correct update ID returned';
        my $cgi = CGI::Simple->new($o->test_req_used->content);
        is $cgi->param('description'), '[Customer FMS update] Update text', 'FMS update prefix included';
        is $cgi->param('service_request_id_ext'), $p->id, 'Service request ID included';
        is $cgi->param('service_code'), $contact->email, 'Service code included';

        $mech->get_ok('/report/' . $p->id);
        $mech->content_lacks('Please note that updates are not sent to the council.');
    };
};

my $problem;
subtest "bartec report with no geocode handled correctly" => sub {
    FixMyStreet::override_config {
        STAGING_FLAGS => { send_reports => 1 },
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
    }, sub {
        my $contact = $mech->create_contact_ok(body_id => $peterborough->id, category => 'Bins', email => 'Bartec-Bins');
        ($problem) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', { category => 'Bins', latitude => 52.5607, longitude => 0.2405, cobrand => 'peterborough', areas => ',2566,' });

        FixMyStreet::Script::Reports::send();

        $problem->discard_changes;
        is $problem->send_state, 'sent', 'Report marked as sent';

        my $req = Open311->test_req_used;
        my $cgi = CGI::Simple->new($req->content);
        is $cgi->param('attribute[postcode]'), undef, 'postcode param not set';
        is $cgi->param('attribute[house_no]'), undef, 'house_no param not set';
        is $cgi->param('attribute[street]'), undef, 'street param not set';
    };
};

subtest "no update sent to Bartec" => sub {
    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
    }, sub {
        $mech->get_ok('/report/' . $problem->id);
        $mech->content_contains('Please note that updates are not sent to the council.');
        my $o = Open311::PostServiceRequestUpdates->new;
        my $c = FixMyStreet::DB->resultset('Comment')->create({
            problem => $problem, user => $problem->user, anonymous => 't', text => 'Update text',
            problem_state => 'fixed - council', state => 'confirmed', mark_fixed => 0,
            confirmed => DateTime->now(),
        });
        $c->discard_changes; # to get defaults
        $o->process_update($peterborough, $c);
        $c->discard_changes;
        is $c->send_state, 'skipped';
    };
};

my $report;
subtest "extra bartec params are sent to open311" => sub {
    FixMyStreet::override_config {
        STAGING_FLAGS => { send_reports => 1 },
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
    }, sub {
        ($report) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', {
            category => 'Bins',
            latitude => 52.5608,
            longitude => 0.2405,
            cobrand => 'peterborough',
            geocode => {
                display_name => '12 A Street, XX1 1SZ',
                address => {
                    house_number => '12',
                    road => 'A Street',
                    postcode => 'XX1 1SZ'
                }
            },
            extra => {
                contributed_by => $staffuser->id,
                external_status_code => 'EXT',
                _fields => [
                    { name => 'site_code', value => '12345', },
                    { name => 'PCC-light', value => 'light-ref', },
                ],
            },
        } );

        FixMyStreet::Script::Reports::send();

        $report->discard_changes;
        is $report->send_state, 'sent', 'Report marked as sent';

        my $req = Open311->test_req_used;
        my $cgi = CGI::Simple->new($req->content);
        is $cgi->param('attribute[postcode]'), 'XX1 1SZ', 'postcode param sent';
        is $cgi->param('attribute[house_no]'), '12', 'house_no param sent';
        is $cgi->param('attribute[street]'), 'A Street', 'street param sent';
        is $cgi->param('attribute[contributed_by]'), $staffuser->email, 'staff email address sent';
    };
};

for my $test (
    {
        lat => 52.5708,
        desc => 'council land - send by open311',
        method => 'Open311',
    },
    {
        lat => 52.5608,
        desc => 'leased council land - send by email',
        method => 'Email',
    },
    {
        lat => 52.5508,
        desc => 'non council land - send by email',
        method => 'Email',
    },
    {
        lat => 52.5408,
        desc => 'adopted road - send by open311',
        method => 'Open311',
    },
) {
    subtest "check get_body_sender: " . $test->{desc} => sub {
        FixMyStreet::override_config {
            STAGING_FLAGS => { send_reports => 1 },
            MAPIT_URL => 'http://mapit.uk/',
            ALLOWED_COBRANDS => 'peterborough',
            COBRAND_FEATURES => { open311_email => { peterborough => { flytipping => 'flytipping@example.org' } } },
        }, sub {
            my ($p) = $mech->create_problems_for_body(1, $peterborough->id, 'Title', {
                category => 'General fly tipping',
                latitude => $test->{lat},
                longitude => 0.2505,
                cobrand => 'peterborough',
            });

            my $cobrand = FixMyStreet::Cobrand::Peterborough->new;
            my $sender = $cobrand->get_body_sender($peterborough, $p);
            is $sender->{method}, $test->{method}, "correct body sender set";

            $p->update({ send_state => 'sent' });
        };
    };
}

# Fly tipping
for my $test (
    {   user_type     => 'standard',
        subcategories => [
            {   name           => 'General fly tipping',
                incident_sizes => [
                    {   name       => 'Car Boot Load or Less - S02',
                        land_types => [
                            {   name      => 'public',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 1,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => 'FLY',
                                    email_to     =>
                                        '"Environmental Services" <flytipping@example.org>',
                                },
                            },
                            {   name      => 'public witnessed',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                extra => [
                                    { name => 'pcc-witness', value => 'yes' },
                                ],

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 1,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => undef,
                                    email_to     =>
                                        '"Environmental Services" <flytipping@example.org>',
                                },
                            },
                            {   name      => 'private',
                                latitude  => 52.5608,
                                longitude => 0.2405,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 1,
                                    state        => 'closed',
                                    comment => qr/As this is private land/,
                                    service_code => undef,
                                    email_to     =>
                                        '"Peterborough City Council" <flytipping@example.org>',
                                },
                            },
                        ],
                    },
                    {   name       => 'Single Item - S01',
                        land_types => [
                            {   name      => 'public',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => 'FLY',
                                    email_to     => undef,
                                },
                            },
                            {   name      => 'public witnessed',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                extra => [
                                    { name => 'pcc-witness', value => 'yes' },
                                ],

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 1,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => undef,
                                    email_to     =>
                                        '"Environmental Services" <flytipping@example.org>',
                                },
                            },
                            {   name      => 'private',
                                latitude  => 52.5608,
                                longitude => 0.2405,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'closed',
                                    comment => qr/As this is private land/,
                                    service_code => undef,
                                    email_to     => undef,
                                },
                            },
                        ],
                    },
                    {   name       => 'Single Black Bag - S00',
                        land_types => [
                            {   name      => 'public',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => 'FLY',
                                    email_to     => undef,
                                },
                            },
                            {   name      => 'public witnessed',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                extra => [
                                    { name => 'pcc-witness', value => 'yes' },
                                ],

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 1,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => undef,
                                    email_to     =>
                                        '"Environmental Services" <flytipping@example.org>',
                                },
                            },
                            {   name      => 'private',
                                latitude  => 52.5608,
                                longitude => 0.2405,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'closed',
                                    comment => qr/As this is private land/,
                                    service_code => undef,
                                    email_to     => undef,
                                },
                            },
                        ],
                    },
                ],
            },
            {   name           => 'Hazardous fly tipping',
                incident_sizes => [
                    {   name       => 'Car Boot Load or Less - S02',
                        land_types => [
                            {   name      => 'public',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 1,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => 'HAZ',
                                    email_to     =>
                                        '"Environmental Services" <flytipping@example.org>',
                                },
                            },
                            {   name      => 'public witnessed',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                extra => [
                                    { name => 'pcc-witness', value => 'yes' },
                                ],

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 1,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => undef,
                                    email_to     =>
                                        '"Environmental Services" <flytipping@example.org>',
                                },
                            },
                            {   name      => 'private',
                                latitude  => 52.5608,
                                longitude => 0.2405,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 1,
                                    state        => 'closed',
                                    comment => qr/As this is private land/,
                                    service_code => undef,
                                    email_to     =>
                                        '"Peterborough City Council" <flytipping@example.org>',
                                },
                            },
                        ],
                    },
                    {   name       => 'Single Item - S01',
                        land_types => [
                            {   name      => 'public',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => 'HAZ',
                                    email_to     => undef,
                                },
                            },
                            {   name      => 'private',
                                latitude  => 52.5608,
                                longitude => 0.2405,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'closed',
                                    comment => qr/As this is private land/,
                                    service_code => undef,
                                    email_to     => undef,
                                },
                            },
                        ],
                    },
                    {   name       => 'Single Black Bag - S00',
                        land_types => [
                            {   name      => 'public',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => 'HAZ',
                                    email_to     => undef,
                                },
                            },
                            {   name      => 'private',
                                latitude  => 52.5608,
                                longitude => 0.2405,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'closed',
                                    comment => qr/As this is private land/,
                                    service_code => undef,
                                    email_to     => undef,
                                },
                            },
                        ],
                    },
                ],
            },
        ],
    },
    {   user_type     => 'staff',
        subcategories => [
            {   name           => 'General fly tipping',
                incident_sizes => [
                    {   name       => 'Car Boot Load or Less - S02',
                        land_types => [
                            {   name      => 'public',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => 'FLY',
                                    email_to     => undef,
                                },
                            },
                            {   name      => 'public witnessed',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                extra => [
                                    { name => 'pcc-witness', value => 'yes' },
                                ],

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 1,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => undef,
                                    email_to     =>
                                        '"Environmental Services" <flytipping@example.org>',
                                },
                            },
                            {   name      => 'private',
                                latitude  => 52.5608,
                                longitude => 0.2405,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'closed',
                                    comment => qr/As this is private land/,
                                    service_code => undef,
                                    email_to     => undef,
                                },
                            },
                        ],
                    },
                ],
            },
            {   name           => 'Hazardous fly tipping',
                incident_sizes => [
                    {   name       => 'Car Boot Load or Less - S02',
                        land_types => [
                            {   name      => 'public',
                                latitude  => 52.5708,
                                longitude => 0.2505,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'confirmed',
                                    comment      => undef,
                                    service_code => 'HAZ',
                                    email_to     => undef,
                                },
                            },
                            {   name      => 'private',
                                latitude  => 52.5608,
                                longitude => 0.2405,

                                expected => {
                                    has_whensent => 1,
                                    has_sent_to  => 0,
                                    state        => 'closed',
                                    comment => qr/As this is private land/,
                                    service_code => undef,
                                    email_to     => undef,
                                },
                            },
                        ],
                    },
                ],
            },
        ],
    },
){
    for my $subcat ( @{ $test->{subcategories} } ){
        if ( exists $subcat->{incident_sizes} ) {
            for my $size ( @{ $subcat->{incident_sizes} } ) {
                for my $land ( @{ $size->{land_types} } ) {
                    note 'Fly tipping: '
                        . "$test->{user_type} user: "
                        . "$subcat->{name}: "
                        . "$size->{name}: "
                        . "$land->{name}: ";

                    FixMyStreet::override_config {
                        STAGING_FLAGS    => { send_reports => 1 },
                        MAPIT_URL        => 'http://mapit.uk/',
                        ALLOWED_COBRANDS => 'peterborough',
                        COBRAND_FEATURES => {
                            open311_email => {
                                peterborough => {
                                    flytipping => 'flytipping@example.org'
                                }
                            }
                        },
                        },
                        sub {
                        $mech->clear_emails_ok;

                        my ($p) = $mech->create_problems_for_body(
                            1,
                            $peterborough->id,
                            'Title',
                            {   category  => $subcat->{name},
                                latitude  => $land->{latitude},
                                longitude => $land->{longitude},
                                cobrand   => 'peterborough',
                                extra     => {
                                    _fields => [
                                        {   name  => 'site_code',
                                            value => '12345',
                                        },
                                        {   name  => 'Incident_Size',
                                            value => $size->{name},
                                        },
                                        @{ $land->{extra} // [] },
                                    ],
                                },
                                ( user => $staffuser ) x !!($test->{user_type} eq 'staff'),
                            }
                        );

                        my $test_data = FixMyStreet::Script::Reports::send();
                        $p->discard_changes;

                        my $expected = $land->{expected};

                        if ($expected->{has_whensent}) {
                            isnt $p->whensent, undef;
                            is $p->send_state, 'sent';
                        } else {
                            is $p->whensent, undef;
                            is $p->send_state, 'unprocessed';
                        }
                        if ( $expected->{has_sent_to} ) {
                            is $p->get_extra_metadata('sent_to')->[0],
                                'flytipping@example.org',
                                'sent_to extra metadata is set';
                        }
                        else {
                            is $p->get_extra_metadata('sent_to'),
                                undef, 'no sent_to extra metadata';
                        }

                        is $p->state, $expected->{state}, 'check state';

                        if ( $expected->{comment} ) {
                            is $p->comments->count, 1, 'comment added';
                            like $p->comments->first->text,
                                $expected->{comment},
                                'correct comment text';
                        }
                        else {
                            is $p->comments->count, 0, 'no comments';
                        }

                        if ( $expected->{service_code} ) {
                            my $cgi = CGI::Simple->new(
                                Open311->test_req_used->content );
                            is $cgi->param('service_code'),
                                $expected->{service_code},
                                'open311 sent with correct service code';
                        }
                        else {
                            ok !$test_data->{test_req_used},
                                'open311 not sent';
                        }

                        $mech->email_count_is(
                            $land->{expected}{email_to} ? 1 : 0 );

                        if ( $land->{expected}{email_to} ) {
                            my $email = $mech->get_email;
                            ok $email, 'got an email';
                            is $email->header('To'),
                                $land->{expected}{email_to},
                                'email sent to correct address';
                        }
                        };
                }
            }
        }
    }
}

# Graffiti
for my $test (
    {   user_type     => 'standard',
        subcategories => [
            {   name       => 'Non offensive graffiti',
                land_types => [
                    {   name      => 'public',
                        latitude  => 52.5708,
                        longitude => 0.2505,

                        expected => {
                            has_whensent => 1,
                            has_sent_to  => 0,
                            state        => 'confirmed',
                            comment      => undef,
                            service_code => 'NON',
                            email_to     => undef,
                        },
                    },
                    {   name      => 'private',
                        latitude  => 52.5608,
                        longitude => 0.2405,

                        expected => {
                            has_whensent => 1,
                            has_sent_to  => 1,
                            state        => 'closed',
                            comment      => qr/As this is private land/,
                            service_code => undef,
                            email_to     =>
                                '"Peterborough City Council" <flytipping@example.org>',
                        },
                    },
                ],
            },
            {   name       => 'Offensive graffiti',
                land_types => [
                    {   name      => 'public',
                        latitude  => 52.5708,
                        longitude => 0.2505,

                        expected => {
                            has_whensent => 1,
                            has_sent_to  => 0,
                            state        => 'confirmed',
                            comment      => undef,
                            service_code => 'OFF',
                            email_to     => undef,
                        },
                    },
                    {   name      => 'private',
                        latitude  => 52.5608,
                        longitude => 0.2405,

                        expected => {
                            has_whensent => 1,
                            has_sent_to  => 1,
                            state        => 'closed',
                            comment      => qr/As this is private land/,
                            service_code => undef,
                            email_to     =>
                                '"Peterborough City Council" <flytipping@example.org>',
                        },
                    },
                ],
            },
        ],
    },
    {   user_type     => 'staff',
        subcategories => [
            {   name       => 'Non offensive graffiti',
                land_types => [
                    {   name      => 'public',
                        latitude  => 52.5708,
                        longitude => 0.2505,

                        expected => {
                            has_whensent => 1,
                            has_sent_to  => 0,
                            state        => 'confirmed',
                            comment      => undef,
                            service_code => 'NON',
                            email_to     => undef,
                        },
                    },
                    {   name      => 'private',
                        latitude  => 52.5608,
                        longitude => 0.2405,

                        expected => {
                            has_whensent => 1,
                            has_sent_to  => 0,
                            state        => 'closed',
                            comment      => qr/As this is private land/,
                            service_code => undef,
                            email_to     => undef,
                        },
                    },
                ],
            },
        ],
    },
) {
    for my $subcat ( @{ $test->{subcategories} } ) {
        for my $land ( @{ $subcat->{land_types} } ) {
            note 'Graffiti: '
                . "$test->{user_type} user: "
                . "$subcat->{name}: "
                . "$land->{name}: ";

            FixMyStreet::override_config {
                STAGING_FLAGS    => { send_reports => 1 },
                MAPIT_URL        => 'http://mapit.uk/',
                ALLOWED_COBRANDS => 'peterborough',
                COBRAND_FEATURES => {
                    open311_email => {
                        peterborough =>
                            { flytipping => 'flytipping@example.org' }
                    }
                },
                },
                sub {
                $mech->clear_emails_ok;

                my ($p) = $mech->create_problems_for_body(
                    1,
                    $peterborough->id,
                    'Title',
                    {   category  => $subcat->{name},
                        latitude  => $land->{latitude},
                        longitude => $land->{longitude},
                        cobrand   => 'peterborough',
                        extra     => {
                            _fields => [
                                {   name  => 'site_code',
                                    value => '12345',
                                },
                            ],
                        },
                        ( user => $staffuser )
                            x !!( $test->{user_type} eq 'staff' ),
                    }
                );

                my $test_data = FixMyStreet::Script::Reports::send();
                $p->discard_changes;

                my $expected = $land->{expected};

                if ($expected->{has_whensent}) {
                    isnt $p->whensent, undef;
                    is $p->send_state, 'sent';
                } else {
                    is $p->whensent, undef;
                    is $p->send_state, 'unprocessed';
                }
                if ( $expected->{has_sent_to} ) {
                    is $p->get_extra_metadata('sent_to')->[0],
                        'flytipping@example.org',
                        'sent_to extra metadata is set';
                }
                else {
                    is $p->get_extra_metadata('sent_to'),
                        undef, 'no sent_to extra metadata';
                }

                is $p->state, $expected->{state}, 'check state';

                if ( $expected->{comment} ) {
                    is $p->comments->count, 1, 'comment added';
                    like $p->comments->first->text,
                        $expected->{comment},
                        'correct comment text';
                }
                else {
                    is $p->comments->count, 0, 'no comments';
                }

                if ( $expected->{service_code} ) {
                    my $cgi
                        = CGI::Simple->new( Open311->test_req_used->content );
                    is $cgi->param('service_code'),
                        $expected->{service_code},
                        'open311 sent with correct service code';
                }
                else {
                    ok !$test_data->{test_req_used}, 'open311 not sent';
                }

                $mech->email_count_is( $land->{expected}{email_to} ? 1 : 0 );

                if ( $land->{expected}{email_to} ) {
                    my $email = $mech->get_email;
                    ok $email, 'got an email';
                    is $email->header('To'),
                        $land->{expected}{email_to},
                        'email sent to correct address';
                }
                };
        }
    }
}

subtest 'Land type' => sub {
    my %lat_lons = (
        public_default       => [ 51,   -1 ],
        private_leased       => [ 51.5, -1 ],
        public_adopted_roads => [ 52,   -1 ],
        private_default      => [ 52.5, -1 ],
    );

    $mock->mock(
        _fetch_features => sub {
            my ( $self, $args, $x, $y ) = @_;

            if ( $x =~ /^470/ && $args->{url} =~ m{4/query} ) {
                # Lat 50, lon 1
                # Council land - public
                return [ { geometry => { type => 'Point' } } ];
            }
            elsif ( $x =~ /^469/ && $args->{url} =~ m{3/query} ) {
                # Lat 51, lon 2
                # Leased-out council land - counts as private
                return [ { geometry => { type => 'Point' } } ];
            }
            elsif ( $x =~ /^468/ && $args->{url} =~ m{7/query} ) {
                # Lat 52, lon 3
                # Adopted roads - public
                return [ { geometry => { type => 'Point' } } ];
            }

            return [];
        }
    );

    sub handler_cobrand {
        my $problem = shift;
        return unless my $logged_cobrand = $problem->get_cobrand_logged;
        return $logged_cobrand->call_hook(
            get_body_handler_for_problem => $problem );
    }

    subtest 'Peterborough' => sub {
        FixMyStreet::override_config {
            MAPIT_URL        => 'http://mapit.uk/',
            ALLOWED_COBRANDS => [ 'fixmystreet', 'peterborough' ],
        } => sub {
            for my $test (
                { category => 'General fly tipping' },
                { category => 'Non offensive graffiti' }
                )
            {
                my $cat = $test->{category};

                subtest "$cat reported on Peterborough site" => sub {
                    my $contact = $mech->create_contact_ok(
                        email    => 'ABC',
                        body_id  => $peterborough->id,
                        category => $cat,
                    );

                    my ($problem) = $mech->create_problems_for_body(
                        1,
                        $peterborough->id,
                        "$cat on Peterborough",
                        {   category  => $cat,
                            latitude  => $lat_lons{public_default}[0],
                            longitude => $lat_lons{public_default}[1],
                            cobrand   => 'peterborough',
                            areas     => ',2566,',
                        },
                    );

                    is handler_cobrand($problem)
                        ->call_hook( land_type_for_problem => $problem ),
                        'public', 'land_type should be public';

                    $problem->latitude( $lat_lons{private_leased}[0] );
                    $problem->longitude( $lat_lons{private_leased}[1] );
                    is handler_cobrand($problem)
                        ->call_hook( land_type_for_problem => $problem ),
                        'private', 'land_type should be updated to private';

                    $problem->latitude( $lat_lons{public_adopted_roads}[0] );
                    $problem->longitude( $lat_lons{public_adopted_roads}[1] );
                    is handler_cobrand($problem)
                        ->call_hook( land_type_for_problem => $problem ),
                        'public', 'land_type should be updated to public';

                    $problem->latitude( $lat_lons{private_default}[0] );
                    $problem->longitude( $lat_lons{private_default}[1] );
                    is handler_cobrand($problem)
                        ->call_hook( land_type_for_problem => $problem ),
                        'private', 'land_type should be updated to private';
                };
            }

            subtest 'Category that is not graffiti or fly-tipping' => sub {
                my $cat = 'Bins';

                my $contact = $mech->create_contact_ok(
                    email    => 'ABC',
                    body_id  => $peterborough->id,
                    category => $cat,
                );

                my ($problem) = $mech->create_problems_for_body(
                    1,
                    $peterborough->id,
                    "$cat on Peterborough",
                    {   category  => $cat,
                        latitude  => $lat_lons{public_default}[0],
                        longitude => $lat_lons{public_default}[1],
                        cobrand   => 'peterborough',
                        areas     => ',2566,',
                    },
                );

                is handler_cobrand($problem)
                    ->call_hook( land_type_for_problem => $problem ),
                    '', 'land_type should be empty string';
            };

            subtest 'Peterborough fly-tipping reported on fixmystreet' =>
                sub {
                my $cat = 'General fly tipping';

                my $contact = $mech->create_contact_ok(
                    email    => 'ABC',
                    body_id  => $peterborough->id,
                    category => $cat,
                );

                my ($problem) = $mech->create_problems_for_body(
                    1,
                    $peterborough->id,
                    "Peterborough fly-tipping on FMS",
                    {   category  => $cat,
                        latitude  => $lat_lons{public_default}[0],
                        longitude => $lat_lons{public_default}[1],
                        cobrand   => 'fixmystreet',
                        areas     => ',2566,',
                    },
                );

                is handler_cobrand($problem)
                    ->call_hook( land_type_for_problem => $problem ),
                    'public', 'land_type should be public';
                };

            subtest 'Pin colours' => sub {
                my ($problem) = $mech->create_problems_for_body(
                    1,
                    $peterborough->id,
                    'General fly tipping',
                    {   category  => 'General fly tipping',
                        latitude  => $lat_lons{public_default}[0],
                        longitude => $lat_lons{public_default}[1],
                        cobrand   => 'peterborough',
                        areas     => ',2566,',
                    },
                );

                my $pbro_cobrand = handler_cobrand($problem);
                $pbro_cobrand->{c} = FixMyStreet::App->new;

                is $pbro_cobrand->pin_colour($problem), 'yellow',
                    'Should be yellow if not staff';

                $pbro_cobrand->{c}->user($staffuser);
                is $pbro_cobrand->pin_colour($problem), 'blue',
                    'Should be blue if staff and public land';

                $problem->latitude( $lat_lons{private_default}[0] );
                $problem->longitude( $lat_lons{private_default}[1] );
                is $pbro_cobrand->pin_colour($problem), 'orange',
                    'Should be orange if staff and private land';
            };
        };
    };

    subtest 'Another cobrand' => sub {
        my $bexley
            = $mech->create_body_ok( 2494, 'London Borough of Bexley' );

        my $cat = 'General fly tipping';

        my $contact = $mech->create_contact_ok(
            email    => 'ABC',
            body_id  => $bexley->id,
            category => $cat,
        );

        FixMyStreet::override_config {
            MAPIT_URL        => 'http://mapit.uk/',
            ALLOWED_COBRANDS => [ 'fixmystreet', 'bexley' ],
        } => sub {
            subtest "Fly-tipping reported on Bexley site" => sub {

                my ($problem) = $mech->create_problems_for_body(
                    1,
                    $bexley->id,
                    "Fly-tipping on Bexley",
                    {   category  => $cat,
                        latitude  => $lat_lons{public_default}[0],
                        longitude => $lat_lons{public_default}[1],
                        cobrand   => 'bexley',
                        areas     => ',2494,',
                    },
                );

                is handler_cobrand($problem)
                    ->call_hook( land_type_for_problem => $problem ),
                    undef, 'land_type should be undef';
                $problem->latitude( $lat_lons{private_leased}[0] );
                $problem->longitude( $lat_lons{private_leased}[1] );
            };

            subtest 'Bexley fly-tipping reported on fixmystreet' => sub {
                my ($problem) = $mech->create_problems_for_body(
                    1,
                    $bexley->id,
                    "Fly-tipping on Bexley",
                    {   category  => $cat,
                        latitude  => $lat_lons{public_default}[0],
                        longitude => $lat_lons{public_default}[1],
                        cobrand   => 'fixmystreet',
                        areas     => ',2494,',
                    },
                );

                is handler_cobrand($problem)
                    ->call_hook( land_type_for_problem => $problem ),
                    undef, 'land_type should be undef';
                $problem->latitude( $lat_lons{private_leased}[0] );
                $problem->longitude( $lat_lons{private_leased}[1] );
            };
        };
    };
};

subtest 'Dashboard CSV extra columns' => sub {
    my $UPLOAD_DIR = tempdir( CLEANUP => 1 );
    $report->update({
        state => 'unable to fix',
    });
    $mech->log_in_ok( $staffuser->email );
    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
        PHOTO_STORAGE_OPTIONS => { UPLOAD_DIR => $UPLOAD_DIR },
    }, sub {
        $mech->get_ok('/dashboard?export=1');
    };
    $mech->content_contains('"Reported As","Staff User",USRN,"Nearest address","External ID","External status code",Light,"CSC Ref"');
    $mech->content_like(qr/"No further action",.*?,peterborough,,[^,]*counciluser\@example.com,12345,"12 A Street, XX1 1SZ",248,EXT,light-ref,/);
    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
        PHOTO_STORAGE_OPTIONS => { UPLOAD_DIR => $UPLOAD_DIR },
    }, sub {
        FixMyStreet::Script::CSVExport::process(dbh => FixMyStreet::DB->schema->storage->dbh);
        $mech->get_ok('/dashboard?export=1');
        $mech->content_contains('"Reported As","Staff User",USRN,"Nearest address","External ID","External status code",Light,"CSC Ref"');
        $mech->content_like(qr/"No further action",.*?,peterborough,,[^,]*counciluser\@example.com,12345,"12 A Street, XX1 1SZ",248,EXT,light-ref,/);
        $mech->get_ok('/dashboard?export=1&state=unable+to+fix');
        $mech->content_contains("No further action");
        $mech->get_ok('/dashboard?export=1&state=confirmed');
        $mech->content_lacks("No further action");
    };
};

subtest 'Resending between backends' => sub {
    $staffuser->user_body_permissions->create({ body => $peterborough, permission_type => 'report_edit' });
    $mech->create_contact_ok(body_id => $peterborough->id, category => 'Pothole', email => 'Bartec-POT');
    $mech->create_contact_ok(body_id => $peterborough->id, category => 'Fallen tree', email => 'Ezytreev-Fallen');
    $mech->create_contact_ok(body_id => $peterborough->id, category => 'Flying tree', email => 'Ezytreev-Flying');
    $mech->create_contact_ok(body_id => $peterborough->id, category => 'Graffiti', email => 'graffiti@example.org', send_method => 'Email');

    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'peterborough',
    }, sub {
        # $problem is in Bins category from creation, which is Bartec
        my $whensent = $problem->whensent;
        $mech->get_ok('/admin/report_edit/' . $problem->id);
        foreach (
            { category => 'Pothole', resent => 0 },
            { category => 'Fallen tree', resent => 1 },
            { category => 'Flying tree', resent => 0 },
            { category => 'Graffiti', resent => 1, method => 'Email' },
            { category => 'Trees', resent => 1 }, # Not due to forced, but due to send method change
            { category => 'Bins', resent => 1 },
        ) {
            $mech->submit_form_ok({ with_fields => { category => $_->{category} } }, "Switch to $_->{category}");
            $problem->discard_changes;
            if ($_->{resent}) {
                is $problem->send_state, 'unprocessed', "Marked for resending";
                $problem->update({ whensent => $whensent, send_method_used => $_->{method} || 'Open311', send_state => 'sent' }); # reset as sent
            } else {
                is $problem->send_state, 'sent', "Not marked for resending";
            }
        }
    };
};

foreach my $cobrand ( "peterborough", "fixmystreet" ) {
    subtest "waste categories aren't available outside /waste on $cobrand cobrand" => sub {
        FixMyStreet::override_config {
            MAPIT_URL => 'http://mapit.uk/',
            ALLOWED_COBRANDS => $cobrand,
        }, sub {
            $peterborough->contacts->delete_all;
            my $contact = $mech->create_contact_ok(body_id => $peterborough->id, category => 'Litter Bin Needs Emptying', email => 'Bartec-Bins');
            my $waste = $mech->create_contact_ok(body_id => $peterborough->id, category => 'Missed Collection', email => 'Bartec-MissedCollection');
            $waste->set_extra_metadata(type => 'waste');
            $waste->update;

            subtest "not when getting new report categories via AJAX" => sub {
                my $json = $mech->get_ok_json('/report/new/ajax?latitude=52.57146&longitude=-0.24201');
                is_deeply $json->{by_category}, { "Litter Bin Needs Emptying" => { bodies => [ 'Peterborough City Council' ] } }, "Waste category not in JSON";
                lacks_string($json, "Missed Collection", "Waste category not mentioned at all");
            };

            subtest "not when making a new report directly" => sub {
                $mech->get_ok('/report/new?latitude=52.57146&longitude=-0.24201');
                $mech->content_contains("Litter Bin Needs Emptying", "non-waste category mentioned");
                $mech->content_lacks("Missed Collection", "waste category not mentioned");
            };

            subtest "not when browsing /around" => sub {
                $mech->get_ok('/around?latitude=52.57146&longitude=-0.24201');
                $mech->content_contains("Litter Bin Needs Emptying", "non-waste category mentioned");
                $mech->content_lacks("Missed Collection", "waste category not mentioned");
            };

            subtest "not when browsing all reports" => sub {
                $mech->get_ok('/reports/Peterborough');
                $mech->content_contains("Litter Bin Needs Emptying", "non-waste category mentioned");
                $mech->content_lacks("Missed Collection", "waste category not mentioned");
            };

        };
    };
}

done_testing;
