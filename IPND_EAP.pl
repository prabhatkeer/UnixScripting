#!/usr/bin/perl
# [Trung 28 Jan 2011] Upload files to IPND server
# [ Marek 17-07-2012 ] added IPND_routing.pl after dev001 crash

use strict;
use warnings;
use Config::Tiny;
use Data::Dumper;
use SOAP::Lite;

## Initialisation
my $src_directory = "/home/yatango/";
my $awaiting_directory = "/home/yatango/awaiting/";
my $des_directory = "/home/yatango/";
my $file = "IPNDUPECCON.";
my $env = "yatango";
my $config_file = '/scripts/IPND_EAP.ini';
my $action = $ARGV[0] // "";
my ($dir, $config_ini, $spconfigid, $user, $pwd );

if( $action eq "" || ( $action ne "upload" && $action ne "download" && $action ne "process") ){
  print "Please choose an action: upload, download or process\n";
  exit(0);
}


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
        return 'abc' => 'abc';
}

# Firstly, move files from $src_directory to $awaiting_directory
`/bin/mv $src_directory$file* $awaiting_directory`;

# Secondly, process files from $awaiting_directory one by one
$dir = "";
#while( defined( $dir = glob( $dir . "$src_directory$file*" ) ) ){
while( defined( $dir = glob( $dir . "$awaiting_directory$file*" ) ) ){
  #Move file from awaiting to processing folder
  `/bin/mv $dir $src_directory`;
  $dir =~ s/$awaiting_directory//;

  # Invoke webservice with file name to ask for SPConfigID
  if( $action eq "process" ){
    $dir =~ s/.err//;
  }

  $spconfigid = $soap->getSPConfig( 1, $dir )->{'response'}->{'spconfigID'};
  print "$dir spconfigid=$spconfigid\n";

  my $config = Config::Tiny->new;
  $config = Config::Tiny->read( $config_file );
  $user = $config->{$spconfigid}->{'user'};
  $pwd = $config->{$spconfigid}->{'pwd'};

  if( $action eq "upload" ){
    print `/scripts/IPND_yatango_step1_upload.pl $user $pwd $dir`;
#      print "/scripts/IPND_yatango_step1_upload.pl $user $pwd $dir\n";

  } elsif( $action eq "download" ){
    `/scripts/IPND_yatango_step2_download.pl $user $pwd $dir`;
#    print "/scripts/IPND_yatango_step2_download.pl $user $pwd $dir\n";

  } elsif( $action eq "process" ){
    print `/scripts/IPND_yatango_step3_process_file.pl $user $pwd`;
#      print "/scripts/IPND_yatango_step3_process_file.pl $user $pwd\n";

  }
}