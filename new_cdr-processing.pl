#!/usr/bin/perl
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
        
        my $cdr_processing_script = conf('cdr.CdrProcessingScript');
        my @cdr_service_providers = conf('cdr.ServiceProviders');
		my $batch = 0;

        foreach my $sp (@cdr_service_providers) {
                print ":Running cdr processing for $sp\n";
                system("$cdr_processing_script $sp $batch")
				
        }
}
# returns config value
sub conf($) {
     return $config->param(shift);
}

# Check if there is an existing process running
my $Qprocess=int(`/bin/ps aux | /bin/grep "cdr-processor" | grep cdr | /bin/grep -v "grep" | wc -l`);
if ($Qprocess > 1 ) {
     die('Another process-prepaid script running');
}
# ---------------------------------------------

main();