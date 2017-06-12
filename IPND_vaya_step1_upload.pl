#!/usr/bin/perl
# [Trung 28 Jan 2011] Upload files to IPND server
# [ Marek 17-07-2012 ] added IPND_routing.pl after dev001 crash

use strict;
use warnings;
use English qw( -no_match_vars );
use Net::FTP;
use File::Copy;
use SOAP::Lite;
use IO::Dir;
require "/scripts/IPND_routing.pl";
ipnd_routing_other();

my $LOCAL_HOST = `uname -n`;
my $SCRIPT = "IPND_vaya_step1_upload.pl";

## Initialisation
#my $directory = "/home/compass/www/ecgateway/IPND/";
my $directory = "/home/vaya/";
my $processed_directory = "/home/vaya/IPND/processed/";
my $count = 0;
my $retry = 0;

my $soap_log = SOAP::Lite->on_fault(
    sub {
        my $soap_log = shift;
        my $res_log  = shift;
        ref $res_log
            ? die( join "\n", '--- SOAP FAULT ---', $res_log->faultcode, $res_log->faultstring, '' )
            : die( join "\n", '--- TRANSPORT ERROR ---', $soap_log->transport->status, '' );
        return new SOAP::SOM;
    }
)->service('https://ecgw001.vaya.net.au/ecgateway/owi/webservices/ecgw_webservice.cfc?WSDL');


my ( $filename, $file_path );

## Let's go to our new home
chdir $directory or die "chdir $directory: $OS_ERROR\n";
my $dir = IO::Dir->new(q{.}) or die "opendir: $OS_ERROR!\n";

## Process each text file
ATTEMPT: while ( defined( my $filename = $dir->read() ) ) {
    next if not -f $filename;                         # regular files
    next if $filename =~ /.IPNDUPVAYAP./ ;      # IPND file(s)
    next if $filename =~ /.err/ ;      # IPND file(s)

    next if not $filename =~ /IPNDUPVAYAP./ ;      # IPND file(s)

    eval {
        ## FTP connection
        my $ftp = Net::FTP->new("192.168.37.4", Debug => 0) or die "Cannot connect to some.host.name: $@";
        $ftp->login("vayapdp", "4zvfCOtB") or die "Cannot login ", $ftp->message;

        #my $ftp = Net::FTP->new("192.168.37.5", Debug => 0) or die "Cannot connect to some.host.name: $@";
        #$ftp->login("tvayapdp", "kqSo9\%zz") or die "Cannot login ", $ftp->message;

        $ftp->cwd("upload") or die "Cannot change working directory ", $ftp->message;

        $file_path = $directory . $filename;
        print $file_path ."\n";

        ## Upload
        $ftp->put($file_path) or die "Cannot upload ", $ftp->message;

        $ftp->quit;

        ## Update bill_log via web service
        $soap_log->addBillLog( $filename, "Y", "IPND - File Uploaded - VAYA", "0", "0", "86" );

        $count = $count + 1;

    };

    if($@ && $retry < 3) {
        warn "Problem processing $filename: $EVAL_ERROR";    ## no critic "RequireCarping"
        $retry = $retry + 1;
        `echo 'Problem processing $filename: $EVAL_ERROR\nRetrying...' | mail -s '$LOCAL_HOST - $SCRIPT - Errors from IPND' ming\@ecconnect.com.au sysadmin\@ecconnect.c
om.au`;
        redo ATTEMPT;
    };

}

## No file processed, still insert to bil_logs
if ($count eq 0) {
        $soap_log->addBillLog( "", "Y", "IPND - File Uploaded - VAYA", "0", "0", "86" );
        $soap_log->addBillLog( "", "Y", "IPND - Start downloading result file - VAYA", "0", "0", "86" );
        $soap_log->addBillLog( "", "Y", "IPND - Finish downloading - VAYA", "0", "0", "86" );
        $soap_log->addBillLog( "", "Y", "IPND - Process result file - VAYA", "0", "0", "86" );
        $soap_log->addBillLog( "", "Y", "IPND - Process file finished - VAYA", "0", "0", "86" );
}