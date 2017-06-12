#!/usr/bin/perl -I /scripts/lbf_load
# [MJS 23 Oct 2010] Use INotify to react to new files very quickly.
# [KO 27 Nov 2015] Small changes after migration Yatango to EAP

use strict;
use warnings;
use English qw( -no_match_vars );
use Proc::Daemon;
use File::Basename;
use Linux::Inotify2;
use DBI;
use SOAP::Lite;
use Data::Dumper;
use Sys::Syslog qw(:standard :macros);
use XML::Simple;

our ($VERSION) = '1';

our $ndb_db_user; our $ndb_db_password; our $ndb_db, our $secure_link, our $sp_config_id;
our $watch_dir = "/shared/application_data/acquirebpo/owi_ppin/";
require configdb;

## Run as a daemon
my $daemon = Proc::Daemon->new(
    pid_file     => '/var/run/process-prepaid-files',
    child_STDOUT => '/tmp/process-prepaid-files.log_stdout',
    child_STDERR => '/tmp/process-prepaid-files.log_stderr'
);

my $child = $daemon->Init();
unless ($child) {
    watch($watch_dir);
}

## Loging - will die for priority critical.  See /etc/syslog.conf for message handling
sub my_syslog {
    my ( $pri, $fmt, @messages ) = @_;

    ## Syslog the message, assuming nothing
    openlog( 'process-prepaid-files', 'ndelay,pid', LOG_LOCAL4 );
    syslog( $pri, $fmt, @messages );
    closelog();

    #Die for the critical case
    #if ( $pri eq 'crit' ) {
    #    die sprintf "$fmt\n", @messages;
    #}
}

## Watch a directory and dispatch for "new" files
sub watch {
    my @directories = @_;

    ## Create the watcher
    my $inotify = new Linux::Inotify2()
        or my_syslog( 'crit', "inotify create object failed: $OS_ERROR" );

    ## Watch the directories
    foreach (@directories) {
        $inotify->watch( $_, IN_CLOSE | IN_MOVE )
            or my_syslog( 'crit', "inotify watch creation failed for ". $_ . " directory" );
    }

    ## Handle any events
    my_syslog( 'crit', 'Ready for work... ' );
    while () {
#        my_syslog( 'crit', "Touch all awaiting files" );
        `/scripts/lbf_load/refresh-files.sh $watch_dir`;
        sleep 10;
        my @events = $inotify->read()
            or my_syslog( 'crit', "inotify read failed: $OS_ERROR" );
        foreach my $e (@events) {
            my_syslog( 'crit', 'inotify queue failed.' ) if $e->IN_Q_OVERFLOW();
            next if not -f $e->fullname();

            ## Connect to the database
            my $dbh = DBI->connect( $ndb_db,
                $ndb_db_user, $ndb_db_password, { PrintError => 0, AutoCommit => 0, RaiseError => 1 } )
            or my_syslog( 'crit', "database: $DBI::errstr" );

            ## Dispatch then commit/rollback
            my_syslog( 'crit', 'Starting processing for file %s', $e->fullname() );
            my $result;
            eval {
                $result = process_file( $dbh, $e->fullname() );
                my_syslog( 'info', 'Finished processing for file %s', $e->fullname() );
                $dbh->commit();
                1;
            } or do {
                $result = 'failed';
                my_syslog( 'crit', 'Failed processing for file %s.  Aborted: %s', $e->fullname(), $EVAL_ERROR )
                    ;    ## no critic "RequireCarping"
                eval { $dbh->rollback(); };
            };

            ## EAP-1720
            my $filesystem_error_path = sprintf '%s%s%s', dirname( $e->fullname() ), "/filesystem_error/", basename( $e->fullname() );

            ## Move according to $result
            rename( $e->fullname(), sprintf '%s/%s/%s', dirname( $e->fullname() ), $result, basename( $e->fullname() ) )
                or  my_syslog( 'crit', "rename error: $OS_ERROR" );

                    if (-e $e->fullname()) {
                        system("mv", $e->fullname(), $filesystem_error_path);
                        my_syslog( 'crit', "File moved to filesystem_error_directory: $e->fullname()" );
                    }

            ## Disconnect from the database
            $dbh->disconnect() or my_syslog( 'crit', $dbh->errstr() );
        }
    }
}

## Handle a single file - dumb dispatch
sub process_file {
    my ( $dbh, $filename ) = @_;

    my_syslog( 'crit', 'Dispatching file %s', $filename );

    my $result = 'processed';
    if ( $filename =~ m{ \A .+ / BAR _ }msix ) {
        process_bar( $dbh, $filename );
    }
    else {
        $result = 'skipped';
    }

    my_syslog( 'crit', 'File %s: %s', $filename, $result );

    return $result;
}

## Process a "top-up needed notification"
sub process_bar {
    my ( $dbh, $filename ) = @_;

    my $file_without_path = $filename;
    $file_without_path =~ s{.*/}{};

    ## Prepare our queries
    my $get_billt
        = $dbh->prepare(
        'SELECT billing_type FROM phones WHERE phoneid = ?'
        );
    my $get_topup
        = $dbh->prepare(
        'SELECT top_up_balance, top_up_amount, ph_threshold1, ph_threshold2, top_up_threshold FROM phones WHERE phoneid = ?'
        );
    my $process1
        = $dbh->prepare(
        'INSERT INTO log_processing_files (processing_date, processing_type, filename, msn, fkclientid, fkphoneid, active, overlimit, totalamount, threshold_code) VALUES (Now(), 1, ?, ?, ?, ?, ?, ?, ?, ?)'
        );
    my $process2
        = $dbh->prepare(
        'INSERT INTO log_processing_files (processing_date, processing_type, filename, msn, fkclientid, fkphoneid, active, overlimit, totalamount, billing_type, top_up_balance, top_up_amount, ph_threshold1, ph_threshold2, top_up_threshold, threshold_code) VALUES (Now(), 2, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
        );
    my $process3
        = $dbh->prepare(
        'INSERT INTO log_processing_files (processing_date, processing_type, filename, msn, fkclientid, fkphoneid, active, overlimit, totalamount, billing_type, top_up_balance, top_up_amount, ph_threshold1, ph_threshold2, top_up_threshold, top_up_result, threshold_code) VALUES (Now(), 3, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
        );
    my $get_fresh
        = $dbh->prepare(
        'SELECT callback_date > ( NOW() - INTERVAL 1 HOUR ) AS flag FROM owi_trans WHERE ( ( fkowi_requestsid = 1 AND status_flag = "Y" ) OR ( fkowi_requestsid = 12 AND status_flag = "Y" ) OR ( fkowi_requestsid = 27 AND status_flag = "Y" AND portnotify = "PCCOM" ) ) AND fkphoneid = ?'
        );
    my $get_fresh2
        = $dbh->prepare(
        'SELECT req_date > ( NOW() - INTERVAL 12 HOUR ) AS flag FROM owi_trans WHERE req_date > ( NOW() - INTERVAL 12 HOUR ) AND fkowi_requestsid = 106 AND status_flag = "Y" AND fkphoneid = ?'
        );
    my $get_mod
        = $dbh->prepare(
        'SELECT req_date > ( NOW() - INTERVAL 30 MINUTE ) AS flag FROM owi_trans WHERE fkowi_requestsid = 19 AND Length(status_flag) = 0 AND fkphoneid = ?'
        );
    my $get_accountid
        = $dbh->prepare(
        'SELECT fkaccountid FROM clients WHERE clientid = ?'
        );
    my $reset_auto_topup
        = $dbh->prepare(
        'UPDATE phones SET top_up_balance = 0 WHERE phoneid = ?'
        );

    ## Basic Authentication for webservice
    sub SOAP::Transport::HTTP::Client::get_basic_credentials {
    return acquirebpo => 'acq98aG3@#';
    }

    ## Prepare our SOAP clients
    my $soap = SOAP::Lite->on_fault(
        sub {
            my $soap = shift;
            my $res  = shift;
            ref $res
                ? die( join "\n", '--- SOAP FAULT ---', $res->faultcode, $res->faultstring, '' )
                : die( join "\n", '--- TRANSPORT ERROR ---', $soap->transport->status, '' );
            return new SOAP::SOM;
        }
    )->service($secure_link.'/owi/webservices/ecgw_webservice.cfc?wsdl');
    my $soap_post = SOAP::Lite->on_fault(
        sub {
            my $soap = shift;
            my $res  = shift;
            ref $res
                ? die( join "\n", '--- SOAP FAULT ---', $res->faultcode, $res->faultstring, '' )
                : die( join "\n", '--- TRANSPORT ERROR ---', $soap->transport->status, '' );
            return new SOAP::SOM;
        }
    )->service($secure_link.'/owi/business/FinancialFunc.cfc?wsdl');

    ## Open the file
    open my $file, '<', $filename or die "open: $OS_ERROR!\n";

    ## Keep a note of any topups to avoid doing a double-topup
    # for postpaid (billing_type == 1) topup on either / both events (everytime) but not both times if in the same file
    #
    # 61466964894,505023203712356,620,P_THRESHOLD1
    # 61466964894,505023203712356,620,P_THRESHOLD2
    my %history = ();

    ## Handle each line
LINE: while (<$file>) {
        chomp;
        my ( $num1, $num2, $provider, $code ) = split( /,/, $_ );


        ## TEMPORARY, until we know what we are doing with 'P_THRESHOLD3'
        if ( $code eq 'P_THRESHOLD3' ) {
            my_syslog(
                'crit',                                      join q{ },
                'Processing[1]: ',                           "filename=$filename",
                "msn=$num1",                                 "code=$code",
                "file_result=Skipping Due to Threshold 3"
            );
            next LINE;
        }
        ## TEMPORARY, until we know what we are doing with 'P_THRESHOLD3'


        ## Get the Client record (CLIENTID, PHONEID and ACTIVE)
        my_syslog( 'crit', 'Doing getRelevantPhone for %s', $num1 );
        my $client = $soap->getRelevantPhone(
                            SOAP::Data->value(
                                 SOAP::Data->name( 'spconfigID' => $sp_config_id )->type('double'),
                                 SOAP::Data->name( 'phoneNumber'  => $num1 )->type('double'),
                            )
                        );

        #$num1->{PHONENUMBER}, $sp_config_id->{SPCONFIGID} );
        my_syslog( 'crit', 'getRelevantPhoneAnswer: %s %s', $soap->transport->status );

        ## Nothing to do if client not found
        if ( $client->{CLIENTID} eq '0' ) {
            next LINE;
        }

        ## Get the limits (TOTALAMOUNT and OVERLIMIT)
        my_syslog( 'crit', 'Doing checkLimits for phoneid %s', $client->{PHONEID} );
        my $limits = $soap->checkLimits(
                            SOAP::Data->value(
                                 SOAP::Data->name( 'spconfigID' => $sp_config_id )->type('double'),
                                 SOAP::Data->name( 'phoneid'  => $client->{PHONEID} )->type('double'),
                            )
                        );

        ## Log Point
        my_syslog( 'crit', 'Doing INSERT INTO log_processing_files for phoneid %s', $client->{PHONEID} );
        my_syslog( 'crit', 'Response from checkLimits__overlimit:%s ___Transport_ %s', $limits->{OVERLIMIT}, $soap->transport->status );
        $process1->execute( $file_without_path, $num1, $client->{CLIENTID}, $client->{PHONEID}, $client->{ACTIVE},
            $limits->{OVERLIMIT}, $limits->{TOTALAMOUNT}, $code );
        my_syslog(
            'crit',                         join q{ },
            'Processing[1]: ',              "filename=$filename",
            "msn=$num1",                    "code=$code",
            "clientid=$client->{CLIENTID}", "phoneid=$client->{PHONEID}",
            "active=$client->{ACTIVE}",     "overlimit=$limits->{OVERLIMIT}",
            "totalamount=$limits->{TOTALAMOUNT}"
        );

        ## Nothing to do if client is overlimit
        if ( $limits->{OVERLIMIT} eq 'true' ) {
            next LINE;
        }

        ## Get the Billing Type (and do a sanity check)
        $get_billt->execute( $client->{PHONEID} );
        my %billt;
        $get_billt->bind_columns( \( @billt{ @{ $get_billt->{NAME_lc} } } ) );
        $get_billt->fetch();
        if ( $billt{billing_type} != 0 and $billt{billing_type} != 1 ) {
            die
                "Unimplemented billing type $billt{billing_type} found: filename=$filename, msn=$num1, clientid=$client->{CLIENTID}, phoneid=$client->{PHONEID}\n";
        }

        ## History value: 0 => seen, 1 => topped-up (not exists means not seen)
        ## Billing types: 0 => pre-paid, 1 => post-pay
        ##
        ## History Billing
        ##    -      0      => continue
        ##    -      1      => continue
        ##    0      0      => continue
        ##    0      1      => stop
        ##    1      0      => stop
        ##    1      1      => stop
        ##
        if ( exists $history{$num1} and $history{$num1} == 0 and $billt{billing_type} == 1 ) {
            next LINE;
        }
        elsif ( exists $history{$num1} and $history{$num1} == 1 ) {
            next LINE;
        }

        ## Get the Topup records
        $get_topup->execute( $client->{PHONEID} );
        my %topup;
        $get_topup->bind_columns( \( @topup{ @{ $get_topup->{NAME_lc} } } ) );
        $get_topup->fetch();

        ## Is this a freshly created account? (assume 0 when no records found)
        $get_fresh->execute( $client->{PHONEID} );
        my %fresh;
        $get_fresh->bind_columns( \( @fresh{ @{ $get_fresh->{NAME_lc} } } ) );
        $get_fresh->fetch();
        defined $fresh{flag} or $fresh{flag} = 0;

        ## Is this a freshly debited account? (assume 0 when no records found)
        $get_fresh2->execute( $client->{PHONEID} );
        my %fresh2;
        $get_fresh2->bind_columns( \( @fresh2{ @{ $get_fresh2->{NAME_lc} } } ) );
        $get_fresh2->fetch();
        defined $fresh2{flag} or $fresh2{flag} = 0;

        ## Did this phone have a modify plans request? (assume 0 when no records found)
        $get_mod->execute( $client->{PHONEID} );
        my %modRequest;
        $get_mod->bind_columns( \( @modRequest{ @{ $get_mod->{NAME_lc} } } ) );
        $get_mod->fetch();
        defined $modRequest{flag} or $modRequest{flag} = 0;

        ## Log Point
        $process2->execute(
            $file_without_path,                $num1,                 $client->{CLIENTID},    $client->{PHONEID},
            $client->{ACTIVE},        $limits->{OVERLIMIT},  $limits->{TOTALAMOUNT}, $billt{billing_type},
            $topup{top_up_balance},   $topup{top_up_amount}, $topup{ph_threshold1},  $topup{ph_threshold2},
            $topup{top_up_threshold}, $code
        );
        my_syslog(
            'crit',                                         join q{ },
            'Processing[2]: ',                              "filename=$filename",
            "msn=$num1",                                    "code=$code",
            "clientid=$client->{CLIENTID}",                 "phoneid=$client->{PHONEID}",
            "active=$client->{ACTIVE}",                     "overlimit=$limits->{OVERLIMIT}",
            "totalamount=$limits->{TOTALAMOUNT}",           "billing_type=$billt{billing_type}",
            "fresh_account=$fresh{flag}",                   "fresh_debit=$fresh2{flag}", "mod_request=$modRequest{flag}",
            "top_up_balance=$topup{top_up_balance}",        "top_up_amount=$topup{top_up_amount}",
            "ph_threshold1=$topup{ph_threshold1}",          "ph_threshold2=$topup{ph_threshold2}",
            "top_up_threshold=$topup{top_up_threshold}",    "history=$history{$num1}"
        );

        ## When does this client want to be topped up?
        my $want = undef;
        $want = 1 if $topup{ph_threshold1} == $topup{top_up_threshold};
        $want = 2 if $topup{ph_threshold2} == $topup{top_up_threshold};
        defined $want or die "Client $client->{CLIENTID} has an invalid top_up_threshold in phones table.\n";

        ## Convert $code into a number, for numerical comparison with $want
        $code =~ s{ \A P_THRESHOLD ( 1 | 2 ) \Z }{$1}msix or die "Invalid code at line $INPUT_LINE_NUMBER: $code\n";

        ## Type 0 clients with top_up_balance not set
        if ( not $fresh{flag} and not $fresh2{flag} and $billt{billing_type} == 0 and $topup{top_up_balance} != 1 ) {
            if ( $code eq 'P_THRESHOLD2' or $code == 2 ) {
                ## Notify customer
                my_syslog( 'crit', "notify_customer function started for clientid $client->{CLIENTID}");
                notify_customer( $soap, $dbh, 'top-up-needed2', $client->{CLIENTID}, $client->{PHONEID}, $num1, $topup{ph_threshold2} );
            }
            next LINE;
        }

        ## Postpaid clients (billing_type = 1) are topped up at both thresholds
        ## The larger code (2) means topup at a smaller balance ($2).  For completness, code (1) means topup at balance ($10).
        ##  Want  Code
        ##   1  <=  1   means do a topup        (Customer said $10, we're at that point)
        ##   1  <=  2   means do a topup        (Customer said $10, we at the $2 alert !!)
        ##   2  <=  1   means nothing to do     (Customer said $2, this is the $10 alert)
        ##   2  <=  2   means do a topup        (Customer said $2, we're at that point)


        if ( $billt{billing_type} == 1 or $want <= $code ) {

            ## Record our history
            $history{$num1} = 0;

            ## Variables for getBalance
            my $soap_balance = undef;
            my $soap_balance_response_scalar = undef;
            my $cut = undef;
            my $cut2 = undef;
            my $soap_balance_response_hash = undef;

            ## Check balance for fresh accounts - PREPAID
            if ( $fresh{flag} and $billt{billing_type} == 0 ) {
##Trung 20140325                my $soap_balance = $soap->getBalance( $client->{PHONEID} );
                my $soap_balance = $soap->getBalance(
                            SOAP::Data->value(
                                SOAP::Data->name( 'spconfigID' => $sp_config_id )->type('double'),
                                SOAP::Data->name( 'session_var' => '' )->type('string'),
                                SOAP::Data->name( 'phonenumber' => $num1 )->type('string'),
                            )
                        );

                ## Parsing CDATA from XML (SCALAR) into HASH
                my $soap_balance_response_scalar = Dumper($soap_balance);
                my $cut = substr $soap_balance_response_scalar, 9;
                my $cut2 = substr($cut,0,-3);
                my $soap_balance_response_hash = XMLin($cut2, ForceArray => 1);

                ## We have a response?

                ## Do we have a response?
                if (not defined $soap_balance_response_hash->{RESULTCODE} ) {

                    ## We may safely ignore this not-really-an-error lack of a response, ...
                    if (    defined $soap_balance->{Type}
                        and defined $soap_balance->{Message}
                        and $soap_balance->{Type} eq 'Status'
                        and $soap_balance->{Message} eq
                        'getBalance: phone balance can not be queried due to the current phone status' )
                    {
                        next LINE;
                    }

                    ## Otherwise, we can't continue.
                    die "Line 363 - getBalance failed, dumping response: ", Dumper( \$soap_balance );
                }

                my_syslog(
                    'crit',                                      join q{ },
                    'Processing[3]: ',                           "filename=$filename",
                    "msn=$num1",                                 "code=$code",
                    "clientid=$client->{CLIENTID}",              "phoneid=$client->{PHONEID}",
                    "active=$client->{ACTIVE}",                  "overlimit=$limits->{OVERLIMIT}",
                    "totalamount=$limits->{TOTALAMOUNT}",        "billing_type=$billt{billing_type}",
                    "fresh_account=$fresh{flag}",                "fresh_debit=$fresh2{flag}", "mod_request=$modRequest{flag}",
                    "top_up_balance=$topup{top_up_balance}",     "top_up_amount=$topup{top_up_amount}",
                    "ph_threshold1=$topup{ph_threshold1}",       "ph_threshold2=$topup{ph_threshold2}",
                    "top_up_threshold=$topup{top_up_threshold}", "history=$history{$num1}",
                    "balance_result=$soap_balance_response_hash->{RealBalance}->[0]"
                );
                next LINE if ( $soap_balance_response_hash->{RealBalance}->[0] > 1 );
            }

            ## SKIP for fresh accounts - POSTPAID
            if ( $fresh{flag} and $billt{billing_type} == 1 ) {
                my_syslog(
                    'crit',                                      join q{ },
                    'Processing[3]: ',                           "filename=$filename",
                    "msn=$num1",                                 "code=$code",
                    "clientid=$client->{CLIENTID}",              "phoneid=$client->{PHONEID}",
                    "active=$client->{ACTIVE}",                  "overlimit=$limits->{OVERLIMIT}",
                    "totalamount=$limits->{TOTALAMOUNT}",        "billing_type=$billt{billing_type}",
                    "fresh_account=$fresh{flag}",                "fresh_debit=$fresh2{flag}", "mod_request=$modRequest{flag}",
                    "top_up_balance=$topup{top_up_balance}",     "top_up_amount=$topup{top_up_amount}",
                    "ph_threshold1=$topup{ph_threshold1}",       "ph_threshold2=$topup{ph_threshold2}",
                    "top_up_threshold=$topup{top_up_threshold}", "history=$history{$num1}",
                    "balance_result=Skipping Fresh Account Postpaid"
                );
                next LINE;
            }

            ## SKIP for phones with pending modify plan requests
            if ( $modRequest{flag} ) {
                my_syslog(
                    'crit',                                      join q{ },
                    'Processing[3]: ',                           "filename=$filename",
                    "msn=$num1",                                 "code=$code",
                    "clientid=$client->{CLIENTID}",              "phoneid=$client->{PHONEID}",
                    "active=$client->{ACTIVE}",                  "overlimit=$limits->{OVERLIMIT}",
                    "totalamount=$limits->{TOTALAMOUNT}",        "billing_type=$billt{billing_type}",
                    "fresh_account=$fresh{flag}",                "fresh_debit=$fresh2{flag}", "mod_request=$modRequest{flag}",
                    "top_up_balance=$topup{top_up_balance}",     "top_up_amount=$topup{top_up_amount}",
                    "ph_threshold1=$topup{ph_threshold1}",       "ph_threshold2=$topup{ph_threshold2}",
                    "top_up_threshold=$topup{top_up_threshold}", "history=$history{$num1}",
                    "balance_result=Skipping Pending Modify Request"
                );
                next LINE;
            }

            my $soap_reply = undef;
            my $soap_reply_message = undef;
            my $soap_reply_response_hash = undef;

            ## PREPAID
            if ( $billt{billing_type} == 0 ) {
                ## See if the client has an active bank account, save the web service call to do this simple check
                $get_accountid->execute( $client->{CLIENTID} );
                my %accountid;
                $get_accountid->bind_columns( \( @accountid{ @{ $get_accountid->{NAME_lc} } } ) );
                $get_accountid->fetch();
                if ( $accountid{fkaccountid} == 0 ) {
                    ## Notify customer
                    notify_customer( $soap, $dbh, 'top-up-conditions', $client->{CLIENTID}, $client->{PHONEID}, $num1, $topup{ph_threshold2} );
                    my_syslog( 'info', 'No Active Bank Account',
                        $client->{PHONEID}, $client->{CLIENTID}, "fkaccountid: $accountid{fkaccountid}" );
                }
                else {

                        ##Check and exclude newly MNPNotificationNotify,activated, and or ported service
                        if ($fresh{flag}){
                            ##Do nothing
                        }

                    ## See if the top up amount is greater than 0 (the default amount), save the web service call to do this simple check
                    elsif ( $topup{top_up_amount} == 0 ) {
                        ## Notify customer
                        if ( $fresh2{flag} == 0 ) {
                        notify_customer( $soap, $dbh, 'top-up-conditions', $client->{CLIENTID}, $client->{PHONEID}, $num1, $topup{ph_threshold2} );
                        my_syslog( 'info', 'Top up amount equals 0',
                            $client->{PHONEID}, $client->{CLIENTID}, "top_up_amount: $topup{top_up_amount}" );
                        }
                        my_syslog( 'crit', "notification has not been sent because itwas modify the balance on the IN for clientid: $client->{CLIENTID}" );
                    }
                    else {

                        ## Do a read balance
                        ## Check the CURRENT CREDIT IS STILL UNDER THE THRESHOLD
                        ###my $soap_balance = $soap->getBalance( $client->{PHONEID} );
                        my $soap_balance = $soap->getBalance(
                            SOAP::Data->value(
                                SOAP::Data->name( 'spconfigID' => $sp_config_id )->type('double'),
                                SOAP::Data->name( 'session_var' => '' )->type('string'),
                                SOAP::Data->name( 'phonenumber' => $num1 )->type('string'),
                            )
                        );

                        ## Parsing CDATA from XML (SCALAR) into HASH
                        my $soap_balance_response_scalar = Dumper($soap_balance);
                        my $cut = substr $soap_balance_response_scalar, 9;
                        my $cut2 = substr($cut,0,-3);
                        my $soap_balance_response_hash = XMLin($cut2, ForceArray => 1);

                        ## Do we have a response?
                        if (not defined $soap_balance_response_hash->{RESULTCODE} ) {

                            ## We may safely ignore this not-really-an-error lack of a response, ...
                            if (    defined $soap_balance->{Type}
                                and defined $soap_balance->{Message}
                                and $soap_balance->{Type} eq 'Status'
                                and $soap_balance->{Message} eq
                                'getBalance: phone balance can not be queried due to the current phone status' )
                            {
                                next LINE;
                            }

                            ## Otherwise, we can't continue.
                            die "Line: 467: getBalance failed, dumping response: ", Dumper( \$soap_balance );
                        }

                        if ( $soap_balance_response_hash->{RealBalance}->[0] <= $topup{top_up_threshold} ) {
                            ## Do topup like we normally would
                            ###$soap_reply = $soap->doTopup( $topup{top_up_amount}, $client->{PHONEID} );
                            $soap_reply = $soap->doTopup(
                                SOAP::Data->value(
                                    SOAP::Data->name( 'spconfigID' => $sp_config_id )->type('double'),
                                    SOAP::Data->name( 'amount'       => $topup{top_up_amount} )->type('double'),
                                    SOAP::Data->name( 'phoneid'      => $client->{PHONEID} )->type('double'),
                                    SOAP::Data->name( 'session_var'  =>  )->type('string'),
                                )
                            );

                            $soap_reply_response_hash = XMLin($soap_reply, ForceArray => 1);

                            my_syslog(
                                'crit',                                      join q{ },
                                'Processing[3]: ',                           "filename=$filename",
                                "msn=$num1",                                 "code=$code",
                                "clientid=$client->{CLIENTID}",              "phoneid=$client->{PHONEID}",
                                "active=$client->{ACTIVE}",                  "overlimit=$limits->{OVERLIMIT}",
                                "totalamount=$limits->{TOTALAMOUNT}",        "billing_type=$billt{billing_type}",
                                "fresh_account=$fresh{flag}",                "fresh_debit=$fresh2{flag}", "mod_request=$modRequest{flag}",
                                "top_up_balance=$topup{top_up_balance}",     "top_up_amount=$topup{top_up_amount}",
                                "ph_threshold1=$topup{ph_threshold1}",       "ph_threshold2=$topup{ph_threshold2}",
                                "top_up_threshold=$topup{top_up_threshold}", "history=$history{$num1}",
                                "balance_result=$soap_balance_response_hash->{RealBalance}->[0]","topup_result_message= $soap_reply_response_hash->{Result}[0]",
                                );
                            defined $soap_reply_response_hash->{Result}[0] or die "Topup failed, dumping response: ", Dumper( \$soap_reply );
                        }
                        else {
                            my_syslog(
                                'crit',                                      join q{ },
                                'Processing[3]: ',                           "filename=$filename",
                                "msn=$num1",                                 "code=$code",
                                "clientid=$client->{CLIENTID}",              "phoneid=$client->{PHONEID}",
                                "active=$client->{ACTIVE}",                  "overlimit=$limits->{OVERLIMIT}",
                                "totalamount=$limits->{TOTALAMOUNT}",        "billing_type=$billt{billing_type}",
                                "fresh_account=$fresh{flag}",                "fresh_debit=$fresh2{flag}", "mod_request=$modRequest{flag}",
                                "top_up_balance=$topup{top_up_balance}",     "top_up_amount=$topup{top_up_amount}",
                                "ph_threshold1=$topup{ph_threshold1}",       "ph_threshold2=$topup{ph_threshold2}",
                                "top_up_threshold=$topup{top_up_threshold}", "history=$history{$num1}",
                                "balance_result=Skipping due to TOTAL balance is greater than threshold ($soap_balance_response_hash->{RealBalance}->[0])"
                            );
                            next LINE;
                        }
                    }
                }
            }

            ## POSTPAID
            else {
                $soap_reply = $soap_post->postTopup( $client->{PHONEID} );
                defined $soap_reply->{response} or die "Topup failed, dumping response: ", Dumper( \$soap_reply );
            }

            my_syslog( 'crit', 'soap_reply_response_hash_Result =  %s', $soap_reply_response_hash->{Result}[0] );

            if ( defined $soap_reply_response_hash->{Result}[0] ) {

                ## Log Point
                $process3->execute(
                    $file_without_path,       $num1,                             $client->{CLIENTID},
                    $client->{PHONEID},       $client->{ACTIVE},                 $limits->{OVERLIMIT},
                    $limits->{TOTALAMOUNT},   $billt{billing_type},              $topup{top_up_balance},
                    $topup{top_up_amount},    $topup{ph_threshold1},             $topup{ph_threshold2},
                    $topup{top_up_threshold}, $soap_reply_response_hash->{Result}[0], $code
                );
                my_syslog(
                    'crit',                                      join q{ },
                    'Processing[4]: ',                           "filename=$filename",
                    "msn=$num1",                                 "code=$code",
                    "clientid=$client->{CLIENTID}",              "phoneid=$client->{PHONEID}",
                    "active=$client->{ACTIVE}",                  "overlimit=$limits->{OVERLIMIT}",
                    "totalamount=$limits->{TOTALAMOUNT}",        "billing_type=$billt{billing_type}",
                    "fresh_account=$fresh{flag}",                "fresh_debit=$fresh2{flag}", "mod_request=$modRequest{flag}",
                    "top_up_balance=$topup{top_up_balance}",     "top_up_amount=$topup{top_up_amount}",
                    "ph_threshold1=$topup{ph_threshold1}",       "ph_threshold2=$topup{ph_threshold2}",
                    "top_up_threshold=$topup{top_up_threshold}", "history=$history{$num1}",
                    "balance_result=$soap_balance_response_hash->{RealBalance}->[0]",
                    "topup_result=$soap_reply_response_hash->{Result}[0]"
                );

                if ( $soap_reply_response_hash->{Result}[0] =~ m{ ERROR \s - \s CC \s Topup \s Failed \s Payment }msix ) {
                    $reset_auto_topup->execute( $client->{PHONEID} );
                    ## Notify customer
                    notify_customer( $soap, $dbh, 'card-failed', $client->{CLIENTID}, $client->{PHONEID}, $num1, $topup{ph_threshold2} );
                    my_syslog( 'crit', 'Topup of phone %s for client %s failed: %s',
                        $client->{PHONEID}, $client->{CLIENTID}, $soap_reply_response_hash->{Result}[0]);
                }
                elsif ( $soap_reply_response_hash->{Result}[0] =~ m{ CC \s Topup \s Success }msix ) {
                    ## Notify customer
                    notify_customer( $soap, $dbh, 'topup-success', $client->{CLIENTID}, $client->{PHONEID}, $num1, $topup{ph_threshold2}, $soap_balance_response_hash->{RealBalance}->[0], $topup{top_up_amount} );
                    my_syslog( 'info', 'Topup of phone %s for client %s succeeded: %s',
                        $client->{PHONEID}, $client->{CLIENTID}, $soap_reply_response_hash->{Result}[0] );

                        ## Record our history
                        $history{$num1} = 1;
                }
                elsif ( $billt{billing_type} == 1 and $soap_reply_response_hash->{Result}[0] !~ m{ Topup \s Success }msix and ( $code eq 'P_THRESHOLD2' or $code == 2 ) ) {
                    ## Notify customer
                    notify_customer( $soap, $dbh, 'almost_reached_limit', $client->{CLIENTID}, $client->{PHONEID}, $num1, $topup{ph_threshold2} );
                    my_syslog( 'crit', 'Topup of phone %s for client %s failed: %s. Sent almost_reached_limit .',
                        $client->{PHONEID}, $client->{CLIENTID}, $soap_reply_response_hash->{Result}[0] );
                }
                else {
                    my_syslog( 'crit', 'Topup response not handled in the perl script: %s',
                        $soap_reply_response_hash->{Result}[0]);
                }

            }

        }

    }
    close $file or die "close: $OS_ERROR!\n";

    return;
}

## Notify Customer
sub notify_customer {
    my ( $soap, $dbh, $type, $clientid, $phoneid, $phonenum, $this_threshold2, $RealBalance, $top_up_amount, $extra ) = @_;

    ## Get the client's name (use "Customer" on failure)
    my %firstname;
    my $get_firstname = $dbh->prepare('SELECT p.firstname FROM client_to_person cp INNER JOIN person p ON cp.FK_person_id = p.id WHERE cp.FK_client_id = ? AND cp.role = 1');
    $get_firstname->execute($clientid);
    $get_firstname->bind_columns( \( @firstname{ @{ $get_firstname->{NAME_lc} } } ) );
    $get_firstname->fetch();
    defined $firstname{firstname} or $firstname{firstname} = "Customer";

    ## Format the phone number
    my $formatted_phone = substr($phonenum, 2, 10);

    ## Handle the types
    my $messageid;
    my $request_type;
    my $repVars;
    if ( $type eq 'card-failed' ) {
        $messageid = 14314;
        $request_type = 3;
        $repVars = "$firstname{firstname},$this_threshold2";
    }
    elsif ( $type eq 'top-up-needed' ) {
        $messageid = 0;
        $request_type = 3;
        $repVars = "";
    }
    elsif ( $type eq 'top-up-needed2' ) {
        $messageid = 14289;
        $request_type = 3;
        $repVars = "$firstname{firstname},$this_threshold2";
    }
    elsif ( $type eq 'top-up-conditions' ) {
        $messageid = 14289;
        $request_type = 3;
        $repVars = "$firstname{firstname},$this_threshold2";
    }
    elsif ( $type eq 'almost_reached_limit' ) {
        $messageid = 14310;
        $request_type = 3;
        $repVars = "$firstname{firstname}";
    }
    elsif ( $type eq 'topup-success' ) {
        $messageid = 14313;
        $request_type = 2;
        $repVars = "$firstname{firstname},$this_threshold2,".($RealBalance + $top_up_amount)."";
    }
    else {
        die "Message type $type is not known\n";
    }

    my_syslog( 'crit', 'Sending message: type=%s, clientid=%s, phoneid=%s, phonenum=%s, messageid=%s, repVars=%s',
        $type, $clientid, $phoneid, $phonenum, $messageid, $repVars );

    if ( $messageid > 0 ) {
         my $soap_reply = $soap->sendMessage(
            SOAP::Data->value(
                SOAP::Data->name( 'phoneid'      => $phoneid )->type('double'),
                SOAP::Data->name( 'request_type' => $request_type )->type('string'),
                SOAP::Data->name( 'message'      => 0 )->type('string'),
                SOAP::Data->name( 'clientid'     => $clientid )->type('double'),
                SOAP::Data->name( 'messageid'    => $messageid )->type('double'),
                SOAP::Data->name( 'repVars'      => $repVars ),
                SOAP::Data->name( 'spconfigID'   => $sp_config_id )->type('double'),
            )
        );

        #$soap_reply = $soap->sendMessage(
        #    SOAP::Data->value(
        #        SOAP::Data->name( 'request_type' => $request_type )->type('string'),
        #        SOAP::Data->name( 'clientid'     => $clientid )->type('double'),
        #        SOAP::Data->name( 'phoneid'      => $phoneid )->type('double'),
        #        SOAP::Data->name( 'messageid'    => $messageid )->type('double'),
        #        SOAP::Data->name( 'repVars'      => $repVars ),
        #        SOAP::Data->name( 'message'      => 0 )->type('string'),
        #    )
        #);

        defined $soap_reply->{response}
            or die "Sending message failed, dumping response: ", Dumper( \$soap_reply );
        $soap_reply->{response}->{Result} =~ m{ Email \s Sent \s Successfully }msix
            or my_syslog( 'crit', 'Sending message to %s for client %s about topup issue failed: %s',
            $phonenum, $clientid, $soap_reply->{response}->{Result} );
    }

    return;
}
[root@eap-worker01 ~]# ls -ld /etc/init.d/process-prepaid-files
-rwxr-x--x 1 root root 1182 Nov 29  2015 /etc/init.d/process-prepaid-files
You have new mail in /var/spool/mail/root
[root@eap-worker01 ~]#
[root@eap-worker01 ~]#
[root@eap-worker01 ~]# cat /etc/init.d/process-prepaid-files
#!/bin/bash
# [KO 27 Nov 2015]
#
# process-prepaid-files       Start/Stop process-prepaid-files
#
# chkconfig: 345 13 87
# description: The process-prepaid-files daemon handles files from Optus.
# processname: process-prepaid-files

# Source function library.
. /etc/init.d/functions

prog="process-prepaid-files"
pidfile=/var/run/$prog

RETVAL=0

start() {
        echo -n $"Starting $prog: "
        daemon /scripts/lbf_load/$prog
        RETVAL=$?
        echo
        [ $RETVAL -eq 0 ] && touch /var/lock/subsys/$prog
        return $RETVAL
}

stop() {
        echo -n $"Stopping $prog: "
        killproc -p $pidfile $prog
        RETVAL=$?
        echo
        [ $RETVAL -eq 0 ] && rm -f /var/lock/subsys/$prog
        return $RETVAL
}

restart() {
    stop
    start
}


# See how we were called.
case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    status)
        status -p $pidfile $prog
        ;;
    restart|reload)
        restart
        ;;
    condrestart)
        [ -f /var/lock/subsys/$prog ] && restart || :
        ;;
    *)
        echo $"Usage: $0 {start|stop|status|restart|reload|condrestart}"
        exit 1
esac

exit $?