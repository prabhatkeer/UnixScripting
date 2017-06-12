#!/usr/bin/perl
use strict;
use warnings;

my $time_limit = 3600;

my $curr_time = `date +%s`;
my $last_file = `ls --sort=time /home/eccapi/processed/ | head -2 | tail -n 1`;
my $last_file_timestamp = `stat -c%Z /home/eccapi/processed/\$last_file`;

my $file_age = ($curr_time - $last_file_timestamp) / 60;
$file_age = sprintf("%d", $file_age);

if( $last_file_timestamp + $time_limit < $curr_time ) {
        print "Error! Last MUR file is $file_age minutes old | \$age=$file_age\n";
        exit 2;
} else {
        print "OK! Last MUR file is $file_age minutes old | \$age=$file_age\n";
        exit 0;
}