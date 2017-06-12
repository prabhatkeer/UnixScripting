#!/usr/bin/perl
#Application:   Ecconnect Centreon Functions
#Licensee:      GNU General Public License
#Developer:     Marek Knappe
#Version:       1.0.0
#Dependencies:  None
#Copyright:     Appscorp PTY LTD T/A ECConnect ACN 122 532 076 ABN 91 122 532 076 C 2010.
#License:       It is free software; you can redistribute it and/or modify it under the terms of either:
#a) the GNU General Public License as published by the Free Software Foundation; either external linkversion 1, or (at your option) any later versionexternal link, or
#b) the "Artistic License".
#
#PURPOSE / USGAE / EXAMPLES / DESCRIPTION:
#--------------------------------------------------------------------------------------------------
# description here
# cript to get all files to process and process it by sdr/cdr script
#  Config is in ../config/config.ini
#  First is getting all service providers (cdr.serviceProviders) and then for each of them is processing files from $sp_cdr.Dir
#
#
#CHANGE LOG:
#--------------------------------------------------------------------------------------------------
#[DATE]    [INITIALS]                           [ACTION]
# 2014-10-30    Marek Knappe    First version
#
#
use strict;
use warnings;
use English qw( -no_match_vars );
use Config::Simple;
use File::Basename;
use File::Spec;
use File::Temp;
use IO::Dir;
use POSIX qw( strftime );
use Data::Dumper;

our $config;


sub main() {
        my $script_dir = dirname(File::Spec->rel2abs(__FILE__));
        my $config_filename = File::Spec->join($script_dir, '../config/config.ini');
        our $config = new Config::Simple($config_filename);

        my $sdr_process_script = conf('cdr.ProcessSdrScript');
  my $cdr_process_script = conf('cdr.ProcessCdrScript');
        my @cdr_service_providers = conf('cdr.ServiceProviders');

        foreach my $sp (@cdr_service_providers) {
                print ":Running processing for $sp\n";

                my $cdr_dir = conf($sp.'_cdr.Dir');
                my $cdr_done_dir = conf($sp.'_cdr.DoneDir');


                my @FileTypes = conf($sp.'_cdr.FileTypes');
                foreach my $FileType (@FileTypes) {
                        print ":: processing $FileType for $sp\n";
                        opendir(my $dh, $cdr_dir) || die;
                        while(readdir $dh) {
                                if (/^$FileType/) {
                                              if (/CDR/) {
                                                    print "::: Processing CDR $_\n";
                                                    system("$cdr_process_script $sp $cdr_dir/$_ && mv $cdr_dir/$_ $cdr_done_dir")
                                              } elsif (/SDR/) {
                                                print "::: Processing SDR $_\n";
                                                system("$sdr_process_script $sp $cdr_dir/$_ && mv $cdr_dir/$_ $cdr_done_dir")
                  }
                                    }
                }
        closedir $dh;
#
#for i in `ls /shared/application_data/owi_036/580_CDR*.tar.gz`; do
#/shared/scripts/cdr-loader/process-prepaid-cdr ctau $i && mv $i /shared/application_data/owi_036/processed/
#done;
                }
        }
}
# returns config value
sub conf($) {
     return $config->param(shift);
}

# Check if there is an existing process running
my $Qprocess=int(`/bin/ps aux | /bin/grep "process-prepaid" | grep cdr | /bin/grep -v "grep" | wc -l`);
if ($Qprocess > 1 ) {
     die('Another process-prepaid script running');
}
# ---------------------------------------------

main();