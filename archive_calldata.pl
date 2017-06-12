#!/usr/bin/perl

use strict;
#use warnings;
use English qw( -no_match_vars );
use DBI;
use POSIX qw/strftime/;

## Initialisation
my $now;
my $jump = 50000;

my $dbh = DBI->connect( 'dbi:mysql:dbname=vaya;host=localhost;mysql_compression=1',
        'root', 'my!5ppx', { PrintError => 0, AutoCommit => 1, RaiseError => 1 } )        or my_syslog( 'crit', "database: $DBI::errstr" );

my $dbh_rds = DBI->connect( 'dbi:mysql:dbname=vaya_archive;host=mysqlarchive.csuzmykgr9wi.ap-southeast-2.rds.amazonaws.com;mysql_compression=1',
        'mysqlroot', 'AqC0G8BuKoZ9RxNpJf', { PrintError => 0, AutoCommit => 1, RaiseError => 1 } )        or my_syslog( 'crit', "database: $DBI::errstr" );

my ( $count, $min, $max, $loaded_count, $loaded_min, $loaded_max );

#######################################################################################################################################

sub export_partition {
        my ( $partition ) = @_;
        my $now = localtime;
        print "now=$now Exporting...\n";

        my $count_owi_calldata = $dbh->prepare( "SELECT COUNT(*), MIN(owi_calldataid), MAX(owi_calldataid) FROM owi_calldata PARTITION ($partition)" );
        my $export = $dbh->prepare( "SELECT * FROM owi_calldata PARTITION ($partition) INTO OUTFILE '/data/tmp/owi_calldata_$partition'" );

        $count_owi_calldata->execute();
        $export->execute();

        $count_owi_calldata->bind_columns( undef, \$count, \$min, \$max );

        $count_owi_calldata->fetch();

        print "count=$count, min=$min, max=$max\n";
        if ( $count > 0 && $min > 0 && $max > 0 ) {
                return 0;
        } else {
                print "Something wrong with export_partition count=$count, min=$min, max=$max\n";
                return 1;
        }
}

#######################################################################################################################################

sub import_data {
        my ( $partition ) = @_;
        my $now = localtime;
        print "now=$now Importing...\n";

        my $load_data = $dbh_rds->prepare( "LOAD DATA LOCAL INFILE '/data/tmp/owi_calldata_$partition' INTO TABLE owi_calldata_tmp" );
        my $count_loaded = $dbh_rds->prepare( "SELECT COUNT(*), MIN(owi_calldataid), MAX(owi_calldataid) FROM owi_calldata_tmp" );
        my $copy_to_arch = $dbh_rds->prepare( "INSERT IGNORE INTO owi_calldata SELECT * FROM owi_calldata_tmp" );

        $load_data->execute();
        $count_loaded->execute();

        $count_loaded->bind_columns( undef, \$loaded_count, \$loaded_min, \$loaded_max );

        $count_loaded->fetch();

        print "loaded_count=$loaded_count, loaded_min=$loaded_min, loaded_max=$loaded_max\n";

        if ( $count == $loaded_count && $min == $loaded_min && $max == $loaded_max) {
                $copy_to_arch->execute();
                if( $copy_to_arch->rows == $count ) {
                        return 0;
                } else {
                        print "Something wrong with import_data (err=2) copy_to_arch->rows=". $copy_to_arch->rows ." count=$count\n";
                        return 2;
                }
        } else {
                print "Something wrong with import_data (err=1) loaded_count=$loaded_count, loaded_min=$loaded_min, loaded_max=$loaded_max count=$count, min=$min, max=$
max\n";
                return 1;
        }
}

#######################################################################################################################################
sub truncate_tmp {
        my $empty_data = $dbh_rds->prepare( "TRUNCATE TABLE owi_calldata_tmp" );
        $empty_data->execute();
}

#######################################################################################################################################

my @partitions = ( "p201411", "p201412", "p201501", "p201502", "p201503", "p201504", "p201505", "p201506" );

#done "p201301", "p201302", "p201303", "p201304", "p201305", "p201306", "p201307", "p201308", "p201309", "p201310", "p201311", "p201312", "p201401", "p201402", "p201403
", "p201404", "p201405", "p201406", "p201407", "p201408", "p201409", "p201410"
@partitions = ( "p201409" );


foreach my $i (0 .. $#partitions ) {
        $now = localtime;
        print "now=$now owi_calldata partition $partitions[$i]\n";

        if( export_partition( $partitions[$i] ) == 0 && import_data( $partitions[$i] ) == 0 ){
                print "TRUNCATE TABLE owi_calldata_tmp\n";
                truncate_tmp();

        } else {
                print "Something wrong!!!\n";
                `echo "Something wrong with partitions=$partitions[$i]" | mail -s 'archive_calldata.pl' trung\@ecconnect.com.au`;
                print "=============================================================================================================\n";
        }

        $now = localtime;
        print "now=$now\n=============================================================================================================\n";
}