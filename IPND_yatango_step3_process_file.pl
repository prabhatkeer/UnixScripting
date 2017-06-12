#!/usr/bin/perl
# [Trung 28 Jan 2011] Upload files to IPND server
# [ Marek 17-07-2012 ] added IPND_routing.pl after dev001 crash

use strict;
use warnings;
use English qw( -no_match_vars );
use File::Copy;
use SOAP::Lite;
use IO::Dir;
use MIME::Lite;
use LWP::UserAgent;
use HTTP::Request::Common;

my $LOCAL_HOST = `uname -n`;
my $SCRIPT = "IPND_yatango_step3_process_file.pl";

## Initialisation
my $directory = "/home/yatango/";
my $processed_directory = "/home/yatango/IPND/processed/";
my $user = $ARGV[0] // "";
my $pwd = $ARGV[1] // "";

my $soap = SOAP::Lite->on_fault(
    sub {
        my $soap = shift;
        my $res  = shift;
        ref $res
            ? die( join "\n", '--- SOAP FAULT ---', $res->faultcode, $res->faultstring, '' )
            : die( join "\n", '--- TRANSPORT ERROR ---', $soap->transport->status, '' );
        return new SOAP::SOM;
    }
)->service('https://eap2.ecconnect.com.au/eap/owi/webservices/ecgw_webservice.cfc?wsdl');

sub SOAP::Transport::HTTP::Client::get_basic_credentials {
  return $user => $pwd;
}

my ( $logid, $filename, $file_path );

## Let's go to our new home
chdir $directory or die "chdir $directory: $OS_ERROR\n";
my $dir = IO::Dir->new(q{.}) or die "opendir: $OS_ERROR!\n";

## Process each text file
while ( defined( my $filename = $dir->read() ) ) {
    next if not -f $filename;                         # regular files
    next if not $filename =~ /\.err/ ;      # IPND file(s)

    eval {
            my $err_file = $filename;
            my $file_path = $directory . $err_file;

            print "Processing file: ". $file_path ."\n";

            ## Insert log via web service
            $soap->addBillLog( $filename, "Y", "IPND - Process result file", "0", "0", "0", "86", "7" );

            open(IN, $file_path);
            my @str = <IN>;
            close(IN);

            ## Error occur
            if( scalar(@str) > 2 ) {

                ## Invoke webservice
                my $err_file_path = $directory . $err_file;
                open my $file, '<', $err_file_path or die "open: $OS_ERROR!\n";
                LINE: while (<$file>) {
                    chomp;
                    my ( $phonenumber, $IPND_Error, $IPND_ErrorCodes ) = split( " ", $_ );

                    if ( $phonenumber eq "HDRIPNDPEYATAN" || $phonenumber eq "TRL" || $phonenumber eq "1F" || !$IPND_ErrorCodes ) {
                        if ( $phonenumber eq "1F" ) {
                                `echo 'Problem processing $err_file_path: 1F' | mail -s '$LOCAL_HOST - $SCRIPT - Errors from IPND' sysadmin\@ecconnect.com.au`;
                        }

                        next LINE;
                    }

                    ## Do not process Fail
                    next LINE if $filename =~ /F/ ;      # IPND file(s)

                    ## Eliminate last character
                    $IPND_ErrorCodes = substr( $IPND_ErrorCodes, 0, -1 );

                    print $phonenumber ." ". $IPND_Error  ." ". $IPND_ErrorCodes ."\n";
                    my $soap_reply = $soap->editService(
                        SOAP::Data->value(
                            SOAP::Data->name( 'spconfigID'    => "7" )->type('double'),
                            SOAP::Data->name( 'phonenumber'     => $phonenumber )->type('double'),
                            SOAP::Data->name( 'IPND_Error'         => "1" )->type('double'),
                            SOAP::Data->name( 'IPND_ErrorCodes'       => $IPND_ErrorCodes )->type('string'),
                            SOAP::Data->name( 'phoneid'       => "" )->type('double'),
                                SOAP::Data->name( 'session_var' => "" )->type('string'),
                        )
                    );
                } ## While
            } else {## Error occur
                    #$soap->addBillLog( $filename, "Y", "IPND - The result file is empty or it contains error(s)", "0", "0", "86" );
            }

            ## Move file to processed folder
            move( $directory . $err_file, $processed_directory . $err_file );

            ## Insert log via web service
            $soap->addBillLog( $filename, "Y", "IPND - Process file finished", "0", "0", "0", "86", "7" );
        } ## eval
} ## while

## Remove old files
my $command = `rm \`find /home/yatango/IPND/processed/IPNDUPECCON.* -mtime +7 | grep -v '.err'\``;