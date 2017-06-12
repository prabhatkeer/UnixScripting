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
use MIME::Lite;
require "/scripts/IPND_routing.pl";
ipnd_routing_other();

my $LOCAL_HOST = `uname -n`;
my $SCRIPT = "IPND_yatango_step2_download.pl";

## Initialisation
my $directory = "/home/yatango/";
my $processed_directory = "/home/yatango/IPND/processed/";
my $counter = 1;
my $retry = 0;
my $user = $ARGV[0] // "";
my $pwd = $ARGV[1] // "";
my $input_filename = $ARGV[2] // "";

my $soap_log = SOAP::Lite->on_fault(
    sub {
        my $soap_log = shift;
        my $res_log  = shift;
        ref $res_log
            ? die( join "\n", '--- SOAP FAULT ---', $res_log->faultcode, $res_log->faultstring, '' )
            : die( join "\n", '--- TRANSPORT ERROR ---', $soap_log->transport->status, '' );
        return new SOAP::SOM;
    }
)->service('https://eap2.ecconnect.com.au/eap/owi/webservices/ecgw_webservice.cfc?wsdl');

sub SOAP::Transport::HTTP::Client::get_basic_credentials {
#        return "acquirebpo" => "acq98aG3@#";
        return $user => $pwd;
}

my ( $filename, $file_path );

## Let's go to our new home
chdir $directory or die "chdir $directory: $OS_ERROR\n";
my $dir = IO::Dir->new(q{.}) or die "opendir: $OS_ERROR!\n";

## Process each text file
ATTEMPT: while ( defined( my $filename = $dir->read() ) ) {
    next if not -f $filename;                         # regular files
    next if $filename =~ /.err/ ;      # IPND file(s)
    next if not $filename =~ /$input_filename/;    # IPND file(s)

    eval {
        ## FTP connection
        my $ftp = Net::FTP->new("192.168.37.4", Debug => 0) or die "Cannot connect to some.host.name: $@";
        $ftp->login("eccondp", "cRa>4SLq") or die "Cannot login ", $ftp->message;
        $ftp->cwd("download") or die "Cannot change working directory ", $ftp->message;
        $file_path = $directory . $filename;

        my $browser;
        my $flag = 0;

        while($flag eq 0) {
                my @list = $ftp->ls( $filename .'.err' );
                foreach $browser (@list){
                        #my $err_file = $filename . '.err';
                        my $err_file = $browser;
                        print "Downloading file: ". $browser ."\n";

                        ## Insert log via web service
                        $soap_log->addBillLog( $err_file, "Y", "IPND - Start downloading result file", "0", "0", "0", "86", "7" );

                        $ftp->get( $err_file, $directory . $err_file );
                        $flag = 1;

                        open(IN, $directory . $err_file);
                        my @str = <IN>;
                        close(IN);

print "Re-download = $counter\n";

                        ## Error occur
                        if( scalar(@str) > 2 ) {
=comment
                                ## Send email
                                my $msg = MIME::Lite->new(
                                    From    => 'ecwd@ecconnect.com.au',
                                    To      => 'brad@ecconnect.com.au',
                                    CC      => 'ming@ecconnect.com.au',
                                    Subject => 'Errors from Yatango IPND',
                                    Type    => 'multipart/mixed',
                                );

                                $msg->attach(
                                    Type     => 'TEXT',
                                    Path     => $directory,
                                    Filename => $err_file,
                                );

                                $msg->send;
=cut
                            $counter = 99;

                        } ## Error occur

                }
                sleep(5);
                last if ($counter++ == 100);
        }

        move( $file_path, $processed_directory . $filename );

        ## Insert log via web service
        $soap_log->addBillLog( $filename, "Y", "IPND - Finish downloading", "0", "0", "0", "86", "7" );

        $ftp->quit;

    };

    if($@ && $retry <3) {
        warn "Problem processing $filename: $EVAL_ERROR";    ## no critic "RequireCarping"
        $retry = $retry + 1;
        `echo 'Problem processing $filename: $EVAL_ERROR' | mail -s '$LOCAL_HOST - $SCRIPT - Errors from IPND' ming\@ecconnect.com.au sysadmin\@ecconnect.com.au`;
        redo ATTEMPT;
    };

}