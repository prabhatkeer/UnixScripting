#!/usr/bin/perl

use strict;
use English qw( -no_match_vars );
use DBI;
use POSIX qw/strftime/;
use DateTime;

## Initialisation
my $dbh_acqrep = DBI->connect( 'dbi:mysql:dbname=test;host=localhost;mysql_compression=1','yomojo', 'Crqi2ojySu0DvstRudaW', { PrintError => 0, AutoCommit => 1, RaiseError => 1 } ) or my_syslog( 'crit', "database: $DBI::errstr" );
my $dbh_ytbil3 = DBI->connect( 'dbi:mysql:dbname=test;host=localhost;mysql_compression=1','root', 'my!5ppxhhyt1', { PrintError => 0, AutoCommit => 1, RaiseError => 1 } ) or my_syslog( 'crit', "database: $DBI::errstr" );
my $now = localtime;
my ( $count, $min, $max, $loaded_count, $loaded_min, $loaded_max );
#######################################################################################################################################

sub backup_dest {
        ## Take a backup
        my $dt1 = DateTime->now;
		my $curr = $dt1->dmy('-');
		`/usr/bin/mysqldump --defaults-file=/scripts/MY_PASS test TestBoltOnHistoryFromAcquiresample > /var/tmp/$curr\_TestBoltOnHistoryFromAcquiresample.sql`;
		if ( -e /var/tmp/$curr\_TestBoltOnHistoryFromAcquiresample.sql) {
				print "$now : Backup dump completed.\n"
				return 0;
		} else {
				print "$now : Something wrong at backup\n"
				return 1;
		}
}

sub create_blank_dest {
		## Drop the table
		my $drop_table = $dbh_ytbil3->prepare( "DROP TABLE TestBoltOnHistoryFromAcquiresample" );
		$drop_table->execute();
        print "$now : Existing TestBoltOnHistoryFromAcquiresample table dropped.\n";
		
		## Create a new table
		my $create_table = $dbh_ytbil3->prepare( "CREATE TABLE `TestBoltOnHistoryFromAcquiresample` ( `id` int(11) NOT NULL AUTO_INCREMENT, `fkphoneid` bigint(10) DEFAULT NULL, `cellular_number` bigint(12) DEFAULT NULL, `owi_pplantophoneid` bigint(30) DEFAULT NULL, `EcStartDate` datetime DEFAULT NULL, `EcEndDate` datetime DEFAULT NULL, `fkowi_productplanid` bigint(10) DEFAULT NULL, `product_name` varchar(50) DEFAULT NULL, `partition_incl` varchar(50) DEFAULT NULL, `bundles_id` bigint(10) DEFAULT NULL, PRIMARY KEY (`id`), UNIQUE KEY `Unique_BoltOn_Constraint` (`owi_pplantophoneid`) )" );
        $create_table->execute();
		
		my $sql_count = $dbh_ytbil3->prepare( "SELECT COUNT(*) FROM TestBoltOnHistoryFromAcquiresample" );
        $sql_count->execute();
		my $new_count = $$sql_count->fetchrow_arrayref->[0];
		if ( $new_count = 0 ) {
				print "$now : Old deleted and a new table created.\n"
				return 0;
		} else {
				print "$now : Something wrong at table drop and create\n"
				return 1;
		}
}

sub export_table_data {
        ## Exporting only data
        print "now=$now Exporting data...\n";
        my $export_data = $dbh_acqrep->prepare( "SELECT * FROM bill_costs INTO OUTFILE '/var/tmp/BoltOnHistory_data'" );
        $export_data->execute();
		
		my $source_count = $dbh_ytbil3->prepare( "SELECT COUNT(*), MIN(bill_costid), MAX(bill_costid) FROM TestBoltOnHistoryFromAcquiresample" );
        $source_count->execute();
		
		$source_count->bind_columns( undef, \$loaded_count, \$loaded_min, \$loaded_max );
        $source_count->fetch();
        print "At Yomojo report server eap-aquirebpo-report01 : source_count=$loaded_count, source_min=$loaded_min, source_max=$loaded_max\n";
}

#######################################################################################################################################

sub import_data {
        ## Importing data
        print "now=$now Exporting data...\n";
        my $import_data = $dbh_ytbil3->prepare( "LOAD DATA LOCAL INFILE '/var/tmp/BoltOnHistoryFromAcquire_data' INTO TABLE TestBoltOnHistoryFromAcquiresample" );
        $import_data->execute();
		
        my $dest_count = $dbh_ytbil3->prepare( "SELECT COUNT(*), MIN(bill_costid), MAX(bill_costid) FROM TestBoltOnHistoryFromAcquiresample" );
        $dest_count->execute();

        $dest_count->bind_columns( undef, \$loaded_count, \$loaded_min, \$loaded_max );
        $dest_count->fetch();
        print "At Yomojo billing server vm-ytbill003 dest_count=$loaded_count, dest_min=$loaded_min, dest_max=$loaded_max\n";

}

#######################################################################################################################################

## main
print "$now Starting";
print "$now Taking backup on vm-ytbill003";
if( backup_dest() == 0 ) {
    print "$now Creating blank table on vm-ytbill003";
	if ( create_blank_dest() == 0 ) {
	     print "$now Export data from eap-aquirebpo-report01";
	     if ( export_table_data == 0 ) {
		      print "$now Starting import data from yomojo billing server vm-ytbill003";
			  if ( import_data == 0 ) {
			       print "$now Table has been successfully copied over" && `echo "Table has been successfully copied over" | mail -s '' prabhat\@ecconnect.com.au`;
			  } else { print "$now Some issues during importing data" && `echo "Some issues during importing data" | mail -s '' prabhat\@ecconnect.com.au`; }
		 } else { print "$now Some issues during exporting data" && `echo "Some issues during exporting data" | mail -s '' prabhat\@ecconnect.com.au`; }
	} else { print "$now Some issues during creating blank table" && `echo "Some issues during creating blank table" | mail -s '' prabhat\@ecconnect.com.au`; }
} else { print "$now Some issues during taking backup" && `echo "Some issues during taking backup" | mail -s '' prabhat\@ecconnect.com.au`; }

print "$now Completing";