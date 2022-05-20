use CGI::Simple;
use Test::MockModule;
use Test::MockTime qw(:all);
use Test::Warn;
use DateTime;
use Test::Output;
use FixMyStreet::TestMech;
use FixMyStreet::SendReport::Open311;
use FixMyStreet::Script::Reports;
use FixMyStreet::Script::Alerts;
use Open311::PostServiceRequestUpdates;
use List::Util 'any';
use Regexp::Common 'URI';
my $mech = FixMyStreet::TestMech->new;

# disable info logs for this test run
FixMyStreet::App->log->disable('info');
END { FixMyStreet::App->log->enable('info'); }

# Mock fetching bank holidays
my $uk = Test::MockModule->new('FixMyStreet::Cobrand::UK');
$uk->mock('_fetch_url', sub { '{}' });

# Create test data
my $user = $mech->create_user_ok( 'kingston@example.com', name => 'Kingston' );
my $body = $mech->create_body_ok( 2480, 'Kingston upon Thames Council', {
    can_be_devolved => 1, send_extended_statuses => 1, comment_user => $user,
    send_method => 'Open311', endpoint => 'http://endpoint.example.com', jurisdiction => 'FMS', api_key => 'test', send_comments => 1
});
my $staffuser = $mech->create_user_ok( 'staff@example.com', name => 'Staffie', from_body => $body );


FixMyStreet::override_config {
    ALLOWED_COBRANDS => 'kingston',
    COBRAND_FEATURES => {
        bottomline => { kingston => { } },
    }
}, sub {
    subtest 'check direct debit reconcilliation' => sub {
        set_fixed_time('2021-03-19T12:00:00Z'); # After sample food waste collection
        my $echo = Test::MockModule->new('Integrations::Echo');
        $echo->mock('GetServiceUnitsForObject' => sub {
            my ($self, $id) = @_;

            if ( $id == 54321 ) {
                return [ {
                    Id => 1005,
                    ServiceId => 409,
                    ServiceName => 'Garden waste collection',
                    ServiceTasks => { ServiceTask => {
                        TaskTypeId => 2247,
                        Id => 405,
                        ScheduleDescription => 'every other Monday',
                        Data => { ExtensibleDatum => [ {
                            DatatypeName => 'SLWP - Containers',
                            ChildData => { ExtensibleDatum => {
                                DatatypeName => 'Quantity',
                                Value => 2,
                            } },
                        } ] },
                        ServiceTaskSchedules => { ServiceTaskSchedule => [ {
                            EndDate => { DateTime => '2020-01-01T00:00:00Z' },
                            LastInstance => {
                                OriginalScheduledDate => { DateTime => '2019-12-31T00:00:00Z' },
                                CurrentScheduledDate => { DateTime => '2019-12-31T00:00:00Z' },
                            },
                        }, {
                            EndDate => { DateTime => '2021-03-30T00:00:00Z' },
                            NextInstance => {
                                CurrentScheduledDate => { DateTime => '2020-06-01T00:00:00Z' },
                                OriginalScheduledDate => { DateTime => '2020-06-01T00:00:00Z' },
                            },
                            LastInstance => {
                                OriginalScheduledDate => { DateTime => '2020-05-18T00:00:00Z' },
                                CurrentScheduledDate => { DateTime => '2020-05-18T00:00:00Z' },
                                Ref => { Value => { anyType => [ 567, 890 ] } },
                            },
                        }
                    ] }
                } } } ];
            }
            if ( $id == 54322 || $id == 54324 || $id == 84324 || $id == 154323 ) {
                return [ {
                    Id => 1005,
                    ServiceId => 409,
                    ServiceName => 'Garden waste collection',
                    ServiceTasks => { ServiceTask => {
                        TaskTypeId => 2247,
                        Id => 405,
                        ScheduleDescription => 'every other Monday',
                        Data => { ExtensibleDatum => [ {
                            DatatypeName => 'SLWP - Containers',
                            ChildData => { ExtensibleDatum => {
                                DatatypeName => 'Quantity',
                                Value => 1,
                            } },
                        } ] },
                        ServiceTaskSchedules => { ServiceTaskSchedule => [ {
                            EndDate => { DateTime => '2020-01-01T00:00:00Z' },
                            LastInstance => {
                                OriginalScheduledDate => { DateTime => '2019-12-31T00:00:00Z' },
                                CurrentScheduledDate => { DateTime => '2019-12-31T00:00:00Z' },
                            },
                        }, {
                            EndDate => { DateTime => '2021-03-30T00:00:00Z' },
                            NextInstance => {
                                CurrentScheduledDate => { DateTime => '2020-06-01T00:00:00Z' },
                                OriginalScheduledDate => { DateTime => '2020-06-01T00:00:00Z' },
                            },
                            LastInstance => {
                                OriginalScheduledDate => { DateTime => '2020-05-18T00:00:00Z' },
                                CurrentScheduledDate => { DateTime => '2020-05-18T00:00:00Z' },
                                Ref => { Value => { anyType => [ 567, 890 ] } },
                            },
                        }
                    ] }
                } } } ];
            }
        });

        my $id_replacements = {};

        my $ad_hoc_orig = setup_dd_test_report({
            'Request_Type' => 1,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '54325',
            'uprn' => '654325',
        });
        $ad_hoc_orig->set_extra_metadata('dd_date', '01/01/2021');
        $ad_hoc_orig->update;

        $id_replacements->{AD_HOC_ORIG} = $ad_hoc_orig->id;

        my $ad_hoc = setup_dd_test_report({
            'Request_Type' => 3,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '54325',
            'uprn' => '654325',
        });
        $ad_hoc->set_extra_metadata('payerReference', get_reference("RBK-AD_HOC_ORIG-654325", $id_replacements));
        $ad_hoc->state('unconfirmed');
        $ad_hoc->update;

        $id_replacements->{AD_HOC} = $ad_hoc->id;

        my $ad_hoc_processed = setup_dd_test_report({
            'Request_Type' => 3,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '54426',
            'uprn' => '654326',
        });
        $ad_hoc_processed->set_extra_metadata('dd_date' => '16/03/2021');
        $ad_hoc_processed->update;

        $id_replacements->{AD_HOC_PROCESSED} = $ad_hoc_processed->id;

        my $ad_hoc_skipped = setup_dd_test_report({
            'Request_Type' => 3,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '94325',
            'uprn' => '954325',
        });
        $ad_hoc_skipped->state('unconfirmed');
        $ad_hoc_skipped->update;
        $id_replacements->{AD_HOC_SKIPPED} = $ad_hoc_skipped->id;

        my $hidden = setup_dd_test_report({
            'Request_Type' => 1,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '54399',
            'uprn' => '554399',
        });
        $hidden->state('hidden');
        $hidden->update;
        $id_replacements->{HIDDEN} = $hidden->id;

        my $cc_to_ignore = setup_dd_test_report({
            'Request_Type' => 1,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'credit_card',
            'property_id' => '54399',
            'uprn' => '554399',
        });
        $cc_to_ignore->state('unconfirmed');
        $cc_to_ignore->update;
        $id_replacements->{CC_TO_IGNORE} = $cc_to_ignore->id;

        my $integ = Test::MockModule->new('Integrations::Bottomline');
        $integ->mock('config', sub { return { dd_sun => 'sun', dd_client_id => 'client' }; } );
        $integ->mock('call', sub {
            my ($self, $method, $data) = @_;

            if ( $method eq 'query/execute#CollectionHistoryDates' ) {
            return {
                rows => [
                            { values => [ { resultValues => [ { value => {   # new sub
                                '@type' => "Instruction",
                                amount => 10.00,
                                paymentType => "AUDDIS",
                                lastUpdated => "16/03/2021",
                                paymentDate => "16/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-NEW_SUB-654321", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "2",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 1,
                                mandateId => 1,
                                applicationId => 1,
                                instructionId => 1,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # unhandled new sub
                                '@type' => "Instruction",
                                amount => 10.00,
                                lastUpdated => "16/03/2021",
                                paymentDate => "16/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-3000-554321", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "2",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 2,
                                mandateId => 2,
                                applicationId => 1,
                                instructionId => 2,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # hidden new sub
                                '@type' => "Instruction",
                                amount => 10.00,
                                lastUpdated => "16/03/2021",
                                paymentDate => "16/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-HIDDEN-554399", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "2",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 3,
                                mandateId => 3,
                                applicationId => 1,
                                instructionId => 3,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # ad hoc already processed
                                '@type' => "Instruction",
                                altReference => $ad_hoc_processed->id,
                                amount => 10.00,
                                lastUpdated => "16/03/2021",
                                paymentDate => "16/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-AD_HOC_PROCESSED-654326", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "1",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 4,
                                mandateId => 4,
                                applicationId => 1,
                                instructionId => 1,
                                batchId => 1,
                                submissionId => 4,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # renewal
                                '@type' => "Instruction",
                                amount => 10.00,
                                lastUpdated => "16/03/2021",
                                paymentDate => "16/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-SUB_FOR_RENEWAL-654322", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "1",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 5,
                                mandateId => 5,
                                applicationId => 1,
                                instructionId => 5,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # renewal already handled
                                '@type' => "Instruction",
                                amount => 10.00,
                                lastUpdated => "16/03/2021",
                                paymentDate => "16/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-PROCESSED_RENEWAL-654324", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "1",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 6,
                                mandateId => 6,
                                applicationId => 1,
                                instructionId => 6,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # renewal but payment too new
                                '@type' => "Instruction",
                                amount => 10.00,
                                lastUpdated => "18/03/2021",
                                paymentDate => "19/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK654329", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "1",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 7,
                                mandateId => 7,
                                applicationId => 1,
                                instructionId => 7,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # renewal but nothing in echo
                                '@type' => "Instruction",
                                amount => 10.00,
                                lastUpdated => "16/03/2021",
                                paymentDate => "16/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-RENEWAL_NOTHING_IN_ECHO-754322", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "1",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 8,
                                mandateId => 8,
                                applicationId => 1,
                                instructionId => 8,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # renewal but nothing in fms
                                '@type' => "Instruction",
                                amount => 10.00,
                                lastUpdated => "16/03/2021",
                                paymentDate => "16/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-4000-854324", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "1",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 9,
                                mandateId => 9,
                                applicationId => 1,
                                instructionId => 9,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # subsequent renewal from a cc sub
                                '@type' => "Instruction",
                                amount => 10.00,
                                lastUpdated => "16/03/2021",
                                paymentDate => "16/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-SUB_FOR_SUBSEQUENT_RENEWAL_FROM_CC_SUB-3654321", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "1",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 10,
                                mandateId => 10,
                                applicationId => 1,
                                instructionId => 10,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # renewal from cc payment
                                '@type' => "Instruction",
                                amount => 10.00,
                                lastUpdated => "27/02/2021",
                                paymentDate => "15/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-RENEWAL_FROM_CC_SUB-1654321", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "2",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 11,
                                mandateId => 11,
                                applicationId => 1,
                                instructionId => 1,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # ad hoc
                                '@type' => "Instruction",
                                altReference => $ad_hoc->id,
                                amount => 10.00,
                                lastUpdated => "14/03/2021",
                                paymentDate => "16/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-AD_HOC_ORIG-654325", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "1",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 12,
                                mandateId => 12,
                                applicationId => 1,
                                instructionId => 12,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # unhandled new sub, ad hoc with same uprn
                                '@type' => "Instruction",
                                amount => 10.00,
                                lastUpdated => "16/03/2021",
                                paymentDate => "16/03/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-AD_HOC_SKIPPED-954325", $id_replacements),
                                sortCode => "12345",
                                status => "SUCCESS",
                                transactionCode => "2",
                                created => "06/03/20201",
                                modelId => 1,
                                profileId => 13,
                                mandateId => 13,
                                applicationId => 1,
                                instructionId => 13,
                                batchId => 1,
                                submissionId => 1,
                                retryCount => 0,
                                serviceUserNumber => 1,
                            } } ] } ] },
                        ]
                };
            } elsif ( $method eq 'query/execute#getCancelledPayers' ) {
                return => {
                    rows => [
                            { values => [ { resultValues => [ { value => {   # cancel
                                '@type' => "MandateDTO",
                                payerId => 1,
                                profileId => 200,
                                created => "26/02/2021",
                                lastUpdated => "26/02/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-SUB_FOR_CANCEL-654323", $id_replacements),
                                sortCode => "12345",
                                status => "CANCELLED",
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # unhandled cancel
                                '@type' => "MandateDTO",
                                payerId => 24,
                                profileId => 200,
                                created => "21/02/2021",
                                lastUpdated => "26/02/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK954326", $id_replacements),
                                sortCode => "12345",
                                status => "CANCELLED",
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # unprocessed cancel
                                '@type' => "MandateDTO",
                                payerId => 329,
                                profileId => 200,
                                created => "21/02/2021",
                                lastUpdated => "21/02/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-SUB_FOR_UNPROCESSED_CANCEL-854325", $id_replacements),
                                sortCode => "12345",
                                status => "CANCELLED",
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # cancel nothing in echo
                                '@type' => "MandateDTO",
                                payerId => 103,
                                profileId => 200,
                                created => "21/02/2021",
                                lastUpdated => "26/02/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK-SUB_CANCEL_NOTHING_IN_ECHO-954324", $id_replacements),
                                sortCode => "12345",
                                status => "CANCELLED",
                            } } ] } ] },
                            { values => [ { resultValues => [ { value => {   # cancel no extended data
                                '@type' => "MandateDTO",
                                payerId => 24,
                                profileId => 200,
                                created => "26/02/2021",
                                lastUpdated => "26/02/2021",
                                accountName => "A Payer",
                                accountNumber => 123,
                                reference => get_reference("RBK6654326", $id_replacements),
                                sortCode => "12345",
                                status => "CANCELLED",
                            } } ] } ] },
                        ]
                };
            }
        });

        my $contact = $mech->create_contact_ok(body => $body, category => 'Garden Subscription', email => 'garden@example.com');
        $contact->set_extra_fields(
                { name => 'uprn', required => 1, automated => 'hidden_field' },
                { name => 'property_id', required => 1, automated => 'hidden_field' },
                { name => 'service_id', required => 0, automated => 'hidden_field' },
                { name => 'Request_Type', required => 1, automated => 'hidden_field' },
                { name => 'Subscription_Details_Quantity', required => 1, automated => 'hidden_field' },
                { name => 'Subscription_Details_Containers', required => 1, automated => 'hidden_field' },
                { name => 'Bin_Delivery_Detail_Quantity', required => 1, automated => 'hidden_field' },
                { name => 'Bin_Delivery_Detail_Containers', required => 1, automated => 'hidden_field' },
                { name => 'Bin_Delivery_Detail_Container', required => 1, automated => 'hidden_field' },
                { name => 'current_containers', required => 1, automated => 'hidden_field' },
                { name => 'new_containers', required => 1, automated => 'hidden_field' },
                { name => 'payment_method', required => 1, automated => 'hidden_field' },
                { name => 'pro_rata', required => 0, automated => 'hidden_field' },
                { name => 'payment', required => 1, automated => 'hidden_field' },
                { name => 'client_reference', required => 1, automated => 'hidden_field' },
        );
        $contact->update;

        my $sub_for_renewal = setup_dd_test_report({
            'Request_Type' => 1,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '54321',
            'uprn' => '654322',
        });

        $id_replacements->{SUB_FOR_RENEWAL} = $sub_for_renewal->id;

        my $sub_for_cancel = setup_dd_test_report({
            'Request_Type' => 1,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '54322',
            'uprn' => '654323',
        });

        $id_replacements->{SUB_FOR_CANCEL} = $sub_for_cancel->id;

        # e.g if they tried to create a DD but the process failed
        my $failed_new_sub = setup_dd_test_report({
            'Request_Type' => 1,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '54323',
            'uprn' => '654321',
        });
        $failed_new_sub->state('unconfirmed');
        $failed_new_sub->created(\" created - interval '2' second");
        $failed_new_sub->update;

        $id_replacements->{FAILED_NEW_SUB} = $failed_new_sub->id;

        my $new_sub = setup_dd_test_report({
            'Request_Type' => 1,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '54323',
            'uprn' => '654321',
        });
        $new_sub->state('unconfirmed');
        $new_sub->update;

        $id_replacements->{NEW_SUB} = $new_sub->id;

        my $renewal_from_cc_sub = setup_dd_test_report({
            'Request_Type' => 2,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '154323',
            'uprn' => '1654321',
        });
        $renewal_from_cc_sub->state('unconfirmed');
        $renewal_from_cc_sub->set_extra_metadata('payerReference' => 'RBK1654321');
        $renewal_from_cc_sub->update;

        $id_replacements->{RENEWAL_FROM_CC_SUB} = $renewal_from_cc_sub->id;

        my $sub_for_subsequent_renewal_from_cc_sub = setup_dd_test_report({
            'Request_Type' => 2,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '154323',
            'uprn' => '3654321',
        });
        $sub_for_subsequent_renewal_from_cc_sub->set_extra_metadata('payerReference' => 'RBK3654321');
        $sub_for_subsequent_renewal_from_cc_sub->update;

        $id_replacements->{SUB_FOR_SUBSEQUENT_RENEWAL_FROM_CC_SUB} = $sub_for_subsequent_renewal_from_cc_sub->id;

        my $sub_for_unprocessed_cancel = setup_dd_test_report({
            'Request_Type' => 1,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '84324',
            'uprn' => '854325',
        });
        $id_replacements->{SUB_FOR_UNPROCESSED_CANCEL} = $sub_for_unprocessed_cancel->id;
        my $unprocessed_cancel = setup_dd_test_report({
            'payment_method' => 'direct_debit',
            'property_id' => '84324',
            'uprn' => '854325',
        });
        $unprocessed_cancel->state('unconfirmed');
        $unprocessed_cancel->category('Cancel Garden Subscription');
        $unprocessed_cancel->set_extra_metadata('payerReference' => get_reference("RBK-SUB_FOR_UNPROCESSED_CANCEL-854325", $id_replacements));
        $unprocessed_cancel->update;

        my $sub_for_processed_cancel = setup_dd_test_report({
            'Request_Type' => 1,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '54324',
            'uprn' => '654324',
        });
        my $processed_renewal = setup_dd_test_report({
            'Request_Type' => 2,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '54324',
            'uprn' => '654324',
        });
        $processed_renewal->set_extra_metadata('dd_date' => '16/03/2021');
        $processed_renewal->update;
        $id_replacements->{PROCESSED_RENEWAL} = $processed_renewal->id;

        my $renewal_nothing_in_echo = setup_dd_test_report({
            'Request_Type' => 1,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '74321',
            'uprn' => '754322',
        });
        $id_replacements->{RENEWAL_NOTHING_IN_ECHO} = $renewal_nothing_in_echo->id;

        my $sub_for_cancel_nothing_in_echo = setup_dd_test_report({
            'Request_Type' => 1,
            'Subscription_Details_Quantity' => 1,
            'payment_method' => 'direct_debit',
            'property_id' => '94324',
            'uprn' => '954324',
        });
        $id_replacements->{SUB_CANCEL_NOTHING_IN_ECHO} = $sub_for_cancel_nothing_in_echo->id;

        my $cancel_nothing_in_echo = setup_dd_test_report({
            'payment_method' => 'direct_debit',
            'property_id' => '94324',
            'uprn' => '954324',
        });
        $cancel_nothing_in_echo->state('unconfirmed');
        $cancel_nothing_in_echo->category('Cancel Garden Subscription');
        $cancel_nothing_in_echo->set_extra_metadata('payerReference',  get_reference("RBK-SUB_CANCEL_NOTHING_IN_ECHO-954324", $id_replacements));
        $cancel_nothing_in_echo->update;
        $id_replacements->{CANCEL_NOTHING_IN_ECHO} = $cancel_nothing_in_echo->id;

        my $c = FixMyStreet::Cobrand::Kingston->new;
        warnings_are {
            $c->waste_reconcile_direct_debits;
        } [
            "no matching record found for Garden Subscription payment with id RBK-3000-554321\n",
            "no matching record found for Garden Subscription payment with id RBK-" . $id_replacements->{HIDDEN} . "-554399\n",
            "no matching service to renew for RBK-" . $id_replacements->{RENEWAL_NOTHING_IN_ECHO} . "-754322\n",
            "no matching record found for Garden Subscription payment with id RBK-4000-854324\n",
            "no matching record found for Garden Subscription payment with id RBK-" . $id_replacements->{AD_HOC_SKIPPED} . "-954325\n",
        ], "warns if no matching record";

        $new_sub->discard_changes;
        is $new_sub->state, 'confirmed', "New report confirmed";
        is $new_sub->get_extra_metadata('payerReference'), get_reference("RBK-NEW_SUB-654321", $id_replacements), "payer reference set";
        is $new_sub->get_extra_field_value('PaymentCode'), get_reference("RBK-NEW_SUB-654321", $id_replacements), 'correct echo payment code field';
        is $new_sub->get_extra_field_value('LastPayMethod'), 3, 'correct echo payment method field';
        is $new_sub->get_extra_metadata('dd_mandate_id'), 1, 'correct mandate id set';

        $renewal_from_cc_sub->discard_changes;
        is $renewal_from_cc_sub->state, 'confirmed', "Renewal report confirmed";
        is $renewal_from_cc_sub->get_extra_field_value('PaymentCode'), get_reference("RBK-RENEWAL_FROM_CC_SUB-1654321", $id_replacements), 'correct echo payment code field';
        is $renewal_from_cc_sub->get_extra_field_value('Request_Type'), 2, 'From CC Renewal has correct type';
        is $renewal_from_cc_sub->get_extra_field_value('Subscription_Details_Containers'), 26, 'From CC Renewal has correct container type';
        is $renewal_from_cc_sub->get_extra_field_value('service_id'), 2247, 'Renewal has correct service id';
        is $renewal_from_cc_sub->get_extra_field_value('LastPayMethod'), 3, 'correct echo payment method field';

        my $subsequent_renewal_from_cc_sub = FixMyStreet::DB->resultset('Problem')->search({
                extra => { like => '%uprn,T5:value,I7:3654321%' }
            },
            {
                order_by => { -desc => 'id' }
            }
        );
        is $subsequent_renewal_from_cc_sub->count, 2, "two record for subsequent renewal property";
        $subsequent_renewal_from_cc_sub = $subsequent_renewal_from_cc_sub->first;
        is $subsequent_renewal_from_cc_sub->state, 'confirmed', "Renewal report confirmed";
        is $subsequent_renewal_from_cc_sub->get_extra_field_value('PaymentCode'), get_reference("RBK-SUB_FOR_SUBSEQUENT_RENEWAL_FROM_CC_SUB-3654321", $id_replacements), 'correct echo payment code field';
        is $subsequent_renewal_from_cc_sub->get_extra_field_value('Request_Type'), 2, 'Subsequent Renewal has correct type';
        is $subsequent_renewal_from_cc_sub->get_extra_field_value('Subscription_Details_Containers'), 26, 'Subsequent Renewal has correct container type';
        is $subsequent_renewal_from_cc_sub->get_extra_field_value('service_id'), 2247, 'Subsequent Renewal has correct service id';
        is $subsequent_renewal_from_cc_sub->get_extra_field_value('LastPayMethod'), 3, 'correct echo payment method field';
        is $subsequent_renewal_from_cc_sub->get_extra_field_value('payment_method'), 'direct_debit', 'correctly marked as direct debit';

        $ad_hoc_orig->discard_changes;
        is $ad_hoc_orig->get_extra_metadata('dd_date'), "01/01/2021", "dd date unchanged ad hoc orig";

        $ad_hoc->discard_changes;
        is $ad_hoc->state, 'confirmed', "ad hoc report confirmed";
        is $ad_hoc->get_extra_metadata('dd_date'), "16/03/2021", "dd date set for ad hoc";
        is $ad_hoc->get_extra_field_value('PaymentCode'), get_reference("RBK-AD_HOC_ORIG-654325", $id_replacements), 'correct echo payment code field';
        is $ad_hoc->get_extra_field_value('LastPayMethod'), 3, 'correct echo payment method field';

        $ad_hoc_skipped->discard_changes;
        is $ad_hoc_skipped->state, 'unconfirmed', "ad hoc report not confirmed";

        $hidden->discard_changes;
        is $hidden->state, 'hidden', "hidden report not confirmed";

        $cc_to_ignore->discard_changes;
        is $cc_to_ignore->state, 'unconfirmed', "cc payment not confirmed";

        $cancel_nothing_in_echo->discard_changes;
        is $cancel_nothing_in_echo->state, 'hidden', 'hide already cancelled report';

        my $renewal = FixMyStreet::DB->resultset('Problem')->search({
                extra => { like => '%uprn,T5:value,I6:654322%' }
            },
            {
                order_by => { -desc => 'id' }
            }
        );

        is $renewal->count, 2, "two records for renewal property";
        my $p = $renewal->first;
        ok $p->id != $sub_for_renewal->id, "not the original record";
        is $p->get_extra_field_value('Request_Type'), 2, "renewal has correct type";
        is $p->get_extra_field_value('Subscription_Details_Quantity'), 2, "renewal has correct number of bins";
        is $p->get_extra_field_value('Request_Type'), 2, "renewal has correct type";
        is $p->get_extra_field_value('Subscription_Details_Containers'), 26, 'renewal has correct container type';
        is $p->get_extra_field_value('service_id'), 2247, 'renewal has correct service id';
        is $p->get_extra_field_value('LastPayMethod'), 3, 'correct echo payment method field';
        is $p->state, 'confirmed';

        my $renewal_too_recent = FixMyStreet::DB->resultset('Problem')->search({
                extra => { like => '%uprn,T5:value,I6:654329%' }
            },
            {
                order_by => { -desc => 'id' }
            }
        );
        is $renewal_too_recent->count, 0, "ignore payments less that three days old";

        my $cancel = FixMyStreet::DB->resultset('Problem')->search({ extra => { like => '%uprn,T5:value,I6:654323%' } }, { order_by => { -desc => 'id' } });
        is $cancel->count, 1, "one record for cancel property";
        is $cancel->first->id, $sub_for_cancel->id, "only record is the original one, no cancellation report created";

        my $processed = FixMyStreet::DB->resultset('Problem')->search({
                extra => { like => '%uprn,T5:value,I6:654324%' }
            },
            {
                order_by => { -desc => 'id' }
            }
        );
        is $processed->count, 2, "two records for processed renewal property";

        my $ad_hoc_processed_rs = FixMyStreet::DB->resultset('Problem')->search({
                extra => { like => '%uprn,T5:value,I6:654326%' }
            },
            {
                order_by => { -desc => 'id' }
            }
        );
        is $ad_hoc_processed_rs->count, 1, "one records for processed ad hoc property";

        $unprocessed_cancel->discard_changes;
        is $unprocessed_cancel->state, 'confirmed', 'Unprocessed cancel is confirmed';
        ok $unprocessed_cancel->confirmed, "confirmed is not null";
        is $unprocessed_cancel->get_extra_metadata('dd_date'), "21/02/2021", "dd date set for unprocessed cancelled";

        $failed_new_sub->discard_changes;
        is $failed_new_sub->state, 'unconfirmed', 'failed sub not confirmed';

        warnings_are {
            $c->waste_reconcile_direct_debits;
        } [
            "no matching record found for Garden Subscription payment with id RBK-3000-554321\n",
            "no matching record found for Garden Subscription payment with id RBK-" . $id_replacements->{HIDDEN} . "-554399\n",
            "no matching service to renew for RBK-" . $id_replacements->{RENEWAL_NOTHING_IN_ECHO} . "-754322\n",
            "no matching record found for Garden Subscription payment with id RBK-4000-854324\n",
            "no matching record found for Garden Subscription payment with id RBK-" . $id_replacements->{AD_HOC_SKIPPED} . "-954325\n",
        ], "warns if no matching record";

        $failed_new_sub->discard_changes;
        is $failed_new_sub->state, 'unconfirmed', 'failed sub still unconfirmed on second run';
        $ad_hoc_skipped->discard_changes;
        is $ad_hoc_skipped->state, 'unconfirmed', "ad hoc report not confirmed on second run";

    };

    subtest 'Garden Waste new subs alert update emails contain bin collection days link' => sub {
        FixMyStreet::override_config {
            ALLOWED_COBRANDS => 'bromley',
        }, sub {
            $mech->clear_emails_ok;

            my $property_id = '54323';

            my $new_sub = setup_dd_test_report({ property_id => $property_id });

            my $update = FixMyStreet::DB->resultset('Comment')->find_or_create({
                problem_state => 'action scheduled',
                problem_id => $new_sub->id,
                user_id    => $staffuser->id,
                name       => 'Staff User',
                mark_fixed => 'f',
                text       => "Green bin on way",
                state      => 'confirmed',
                confirmed  => 'now()',
                anonymous  => 'f',
            });

            my $alert = FixMyStreet::DB->resultset('Alert')->create({
                user => $user,
                parameter => $new_sub->id,
                alert_type => 'new_updates',
                whensubscribed => '2021-09-27 12:00:00',
                cobrand => 'bromley',
                cobrand_data => 'waste',
            });
            $alert->confirm;

            FixMyStreet::Script::Alerts::send_updates();

            my $email = $mech->get_email;
            my $text_body = $mech->get_text_body_from_email($email);
            like $text_body, qr/Check your bin collections day/, 'has bin day link text in text part';
            my @links = $mech->get_link_from_email($email, 'get_all_links');
            my $found = any { $_ =~ m"recyclingservices\.bromley\.gov\.uk/waste/$property_id" } @links;
            ok $found, 'Found bin day URL in text part of alert email';

            my $html_body = $mech->get_html_body_from_email($email);
            like $html_body, qr/Check your bin collections day/, 'has bin day link text in HTML part';
            my @uris = $html_body =~ m/$RE{URI}/g;
            $found = any { $_ =~ m"recyclingservices\.bromley\.gov\.uk/waste/$property_id" } @uris;
            ok $found, 'Found bin day URL in HTML part of alert email';
        }
    };
};

sub setup_dd_test_report {
    my $extras = shift;
    my ($report) = $mech->create_problems_for_body( 1, $body->id, 'Test', {
        category => 'Garden Subscription',
        latitude => 51.402096,
        longitude => 0.015784,
        cobrand => 'bromley',
        cobrand_data => 'waste',
        areas => '2482,8141',
        user => $user,
    });

    $extras->{service_id} ||= 2247;
    $extras->{Subscription_Details_Containers} ||= 26;

    my @extras = map { { name => $_, value => $extras->{$_} } } keys %$extras;
    $report->set_extra_fields( @extras );
    $report->update;

    return $report;
}

sub get_reference {
    my ($ref, $replacements) = @_;

    my ($key, $uprn) = $ref =~ /RBK-([A-Z_]*)-(\d+)/;

    return $ref unless $key;
    return $ref unless $replacements->{$key};

    return "RBK-" . $replacements->{$key} . "-$uprn";
}


done_testing();