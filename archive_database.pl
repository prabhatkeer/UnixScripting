archive_database.pl
#!/usr/bin/perl -w
#Application:   Ecconnect Archive Script
#Licensee:      GNU General Public License
#Developer:     Marcin Szumski <marcin@ecconnect.com.au> http://www.ecconnect.com.au
my $Version = "2.1.3";
#Dependencies Centos: perl-DBI perl-SOAP-Lite perl-Config-Tiny
#Dependencies Debian: libdbi-perl libsoap-lite-perl libconfig-tiny-perl
#Copyright:     Appscorp PTY LTD T/A ECConnect ACN 122 532 076 ABN 91 122 532 076 C 2010.
#License:       The licensee as listed above may contract Appscorp or any other party to
#               maintain, modify, improve or develop the application. The licensee may
#               not sell, transfer or licence all or any part of the application and must
#               ensure that the application is not sold, licensed or used by any party engaged
#               by or on behalf of the licensee.
#
#PURPOSE / USGAE / EXAMPLES / DESCRIPTION:
#--------------------------------------------------------------------------------------------------
#
#   See documentation:
#
#CHANGE LOG:
#--------------------------------------------------------------------------------------------------
#
# See todo section on the page bottom
#
#[DATE]          [INITIALS]     [ACTION]
# 07/01/2015     mszumski       Starting with this code base on archive_owi_trans.pl
# 08/01/2015     mszumski       Removing all LOW_PRIORITY statements from DELETE queries
# 08/01/2015     mszumski       Fixing count query for owi_trans
# 08/01/2015     mszumski       adding trim function



use strict;
use warnings;
use English qw( -no_match_vars );
use DBI;
use POSIX qw( strftime );
use Data::Dumper;
use Sys::Syslog qw(:standard :macros);
use Getopt::Long;
use Config::Tiny;
use Switch;

#==================== G L O B A L S  =========================
my  %PARAMS = ();
my  $LOCAL_HOST = `uname -n`;
my  $SCRIPT = "archive_database.pl";
our $start_unix_time = time();
# pointer to hashes with config ini parameters
my $source_db_ini;
my $dest_db_ini;
# hash with SQL queries
my %SQLQuery;

#==================== S T A R T  =========================
parse_entry();

## Main parsing function
sub parse_entry
{
    if ( $#ARGV == -1 ) { print_usage(); } #if

    GetOptions( 'c|config=s'            => \$PARAMS{'configfile'},
                'source_db=s'           => \$PARAMS{'source_db'},
                'dest_db=s'             => \$PARAMS{'dest_db'},
                'jp|justprint'          => \$PARAMS{'justprintFLAG'},
                'queries_function=s'    => \$PARAMS{'queriesfunc'},
                'help|?'                => sub{ print_usage() },
                'v|version'             => sub{ print_version() },
                'logdbchanges=s'        => \$PARAMS{'logdbchanges'},
                'debug'                 => \$PARAMS{'Debug'}
              );

    #Parameters logic
    logM(3,"[".__LINE__."] parse_entry() validatign paramters logic");

    if ( (!defined $PARAMS{'source_db'}) ) {
        logM(2,"Missing -source_db parameter. Try $0 --help");
    } #if

    if ( (!defined $PARAMS{'dest_db'}) ) {
        logM(2,"Missing -dest_db parameter. Try $0 --help");
    } #if

    if ( (!defined $PARAMS{'configfile'}) ) {
        logM(2,"Missing configfile parameter. You need to provide configuration ini file. Try $0 --help");
        exit(1);
    } #if

    #Processing the parameters

    # this variable contains the keyworks which are the parameters readed from the config ini file,
    # Parameters values from this array will be readed from ini file and placed in the array returned by
    # readConfigFile(...) function
    my @DB_IniDict     = ('Port','Host','User','Password','DbName');

    #Geting pointer to master hash config ini
    $source_db_ini = readConfigFile( $PARAMS{'configfile'}, $PARAMS{'source_db'}, \@DB_IniDict );
    $dest_db_ini   = readConfigFile( $PARAMS{'configfile'}, $PARAMS{'dest_db'},   \@DB_IniDict );

    # checking if u want only to print the configuration params
    if ( defined $PARAMS{'justprintFLAG'} ) {
        printIniConfig( $source_db_ini,"source database",0); #last arg in the end says if you want to exit or continue;
        printIniConfig( $dest_db_ini,"destination database",1); #last arg in the end says if you want to exit or continue;
    } #if

    # checking queries function,
    if ( ! defined $PARAMS{'queriesfunc'} ) {
        logM(2,"Missing -queries_function parameter. You need to provide query function name. Try $0 --help");
        exit(1);
    } #if

    program(); #starting main program code

    exit(2); #this line shouldn't be reached
} # parse_entry

## Main program function
sub program
{
    logM(3,"- running program");
    logM(10,"starting script for " . $PARAMS{'queriesfunc'} );
    my $dbh_sourceDB = make_database_connection($source_db_ini);
    my $dbh_destDB   = make_database_connection($dest_db_ini);
    logM(3,"- connected to databases");
    logM(3,"- setting queries... [".$PARAMS{'queriesfunc'}."]");
    eval $PARAMS{'queriesfunc'};
    if ( !defined $SQLQuery{'ID'} ) {
        logM(12,"query function [".$PARAMS{'queriesfunc'}."] is not correctly defined");
    } #if
    logM(3," done");

    # ------ milestone - getting rows for archieve
    logM(3,"- getting rows for archive");
    my $rows_for_arch = $dbh_sourceDB->prepare( $SQLQuery{'select_ids'} );
    my $queryStart = time();
    $rows_for_arch->execute();
    my $queryEnd = time();
    logM(3,"- query executed in:" . ($queryEnd - $queryStart) . "[s]");
    my $count_rows_for_arch = $rows_for_arch->rows;
    logM(3,"- found " . $count_rows_for_arch . " rows for archive");

    # ------ milestone - counting rows in the archive datatabase
    my $arch_count_before;  # number of rows before archivization
    my $arch_count_after;   # number of rows after archivization
    my $arch_count = $dbh_destDB->prepare( $SQLQuery{'count_rows'} );
    logM(3,"- counting rows in the archive datatabase");
    $arch_count->execute();
    $arch_count->bind_columns( undef, \$arch_count_before );
    $arch_count->fetch();
    logM(3,"- counted " . $arch_count_before . " rows");

    # ------ milestone - copy data from source database to destination db and run delete function for every 1000
    # read about the bind_columns http://www.perlmonks.org/?node_id=7568
    # Here we are going to read column names and crete coresponding hash array
    my @columns;      # this array will contain references to the fields from hash array, this array will be passed later to the bind function
    my @column_names; # we need an order list of column names
    my %ColumnsHash;  # this hash will keep filed values for one feached row, keys are the column names,
                      # you can get them sorted from column_names array

    foreach ( @{ $rows_for_arch->{NAME_lc} } )  {
        my $row = $_;
        #adding column names to the array, needed to keep order
        push @column_names, $row;
        #initialization
        $ColumnsHash{ $row } = "";
        #putting references into an array
        push @columns, \$ColumnsHash{ $row };
    } #foreach

    $rows_for_arch->bind_columns( @columns );   # here we are going to put the list of references (values from hash array)
                                                # into the function which will bound them to the feached row from the query
                                                # result

    my $putRow_query = $dbh_destDB->prepare( $SQLQuery{'put_row'} ); # preparing inserting query into destination database

    # do the main job - here we are going to use selected ids from the table
    # we will insert rows into a destination database and than we will remove
    # 1000 rows portion using delete_rows function
    logM(3,"- start moving the data from source to destination database");
    my $start_move_t = time;
    my @rows_for_delete;
    my @rowFields; # additional array which will contain fields value in the proper order
                   # this array will be passed into execute() function

    while( $rows_for_arch->fetch() )
    {
        @rowFields = ();
        # we are puting here all fileds into a rowFields array in the same order as reded,
        # order or filed is in column_names array
        foreach ( @column_names )
        {
            push @rowFields, $ColumnsHash{$_};
        } #foreach

        $putRow_query->execute( @rowFields );
        # preparing ids for deletion
        push( @rows_for_delete, $ColumnsHash{ $SQLQuery{'ID'} } );
        if ( $#rows_for_delete > 998 )
        {
            delete_rows($dbh_sourceDB, \@rows_for_delete);
            @rows_for_delete = (); #flush array
        } #if
    } #while

    delete_rows($dbh_sourceDB, \@rows_for_delete);
    @rows_for_delete = (); #flush array

    my $end_move_t = time;
    logM(3,"- moving done in ". ($end_move_t - $start_move_t) . "[s]");

    # ------ milestone - again counting rows in the archive datatabase
    logM(3,"- counting rows in the archive datatabase");
    $arch_count->execute();
    $arch_count->bind_columns( undef, \$arch_count_after );
    $arch_count->fetch();
    logM(3,"- counted " . $arch_count_after . " rows");

    # ----- print some stats
    logM(3,"count_rows_for_arch: ".$count_rows_for_arch);
    logM(3,"arch_count_after: ".   $arch_count_after);
    logM(3,"arch_count_before: ".  $arch_count_before);
    logM(3,"- disconnect databases connection");
    logM(10,$count_rows_for_arch." rows has been archived in ".($end_move_t - $start_move_t)."[s]. arch_count_before: ".$arch_count_before." arch_count_after: ".$arch_count_after);
    $dbh_sourceDB->disconnect;
    $arch_count->finish();
    $dbh_destDB->disconnect;
    logM(3,"- done");
    logM(10,"script ended for ". $PARAMS{'queriesfunc'} );
    exit(0); #program ends successfully
} #program

## Prints script usage
sub print_usage
{
        print "Usage:\n";
        print "\t$0 [options]\n";
        print "\n-h,--help\t\tthis output";
        print "\n-c,--config\t\tconfig ini file";
        print "\n-source_db\t\tconfig ini database section name";
        print "\n-dest_db\t\tconfig ini database section name";
        print "\n-jp,--justprint\t\tif flag is set prints section from config file and exit(1)";
        print "\n-v,--version\t\tprint version and exit";
        print "\n-debug\t\t\tenter debug mode";
        print "\n-logdbchanges\t\tfile where deleted IDs will be placed";
        print "\n-queries_function\tname of the function with queries set for archivization";
        print "\n";
        exit(0);
} # print_usage

## Prints script version
sub print_version
{
    print $0 . " version: " . $Version . "\n";
    exit(0);
} #print_version

## This function just prints the configuration hash
sub printIniConfig
{
    my ($hashPointer,$hashName,$exit) = @_;
    #printing master config
    print "======= $hashName ========\n";
    while ( my ($k,$v) = each (%$hashPointer) ) {
        if ( ! defined $v ) { $v = ""; } #don't want complaining about uninitialized value
        print "\t$k = $v \n";
    } #while

    if ( $exit != 0 ) {
        exit($exit);
    } #if
} #printIniConfig

##Reads config ini file. Exits if file doesn't exists. Function retuns
##the hash with the database configuration block
sub readConfigFile
{
    my $ConfigIniFile = $_[0];
    my $DatabaseID    = $_[1];
    my @ConfigIniDict = @{$_[2]};
    my %DB;

    # print "file: $ConfigIniFile\n";
    # print "sectionId: $DatabaseID\n";
    # foreach ( @ConfigIniDict ) {
    #     print "ConfigIniDict : ". $_ ."\n";
    # }

    $DB{'section_name'} = $DatabaseID;
    #Check if file exists
    if ( ! -e $ConfigIniFile ) {
        logM(2,"Config file doesn't exists");
        exit(2);
    } #if
    if ( ! -r $ConfigIniFile ) {
        logM(2,"Cannot read config file. Permission denied");
        exit(2);
    } #if
    my $Config = Config::Tiny->read( $ConfigIniFile );

    # -- loading generic block to the %CONF_INI_PARAMS array
    foreach ( @ConfigIniDict ) {
        my $pname = $_;
        $DB{$pname} = $Config->{generic}->{$pname};
    } #foreach
    # -- checking if section in configuration file exists
    my $section = $Config->{$DatabaseID};
    if ( ! defined $section ) {
        logM(2,"Provided section doesn't exists in configuration file");
    } #ifvim
    # -- reloading database block to the %CONF_INI_PARAMS array
    foreach ( @ConfigIniDict ) {
        my $pname = $_;
        if ( defined $Config->{$DatabaseID}->{$pname} ) {
          $DB{$pname} = $Config->{$DatabaseID}->{$pname};
        } #if
    } #foreach
   return \%DB;
} #readConfigFile

#Writes a message to the log.
#       0 - info
#       1 - warning
#       2 - error
#       3 - verbose/debug mode
#       +10 - syslog - add 10 to the base to log into a syslog
sub logM
{
        my ($level,$message) = @_;
        my $syslog_flag=0;
        if ( $level >= 10 ) { $level-=10; $syslog_flag=1; }
        if ( $level == 3 and ! defined $PARAMS{'Debug'} ) { return; }
        my $prefix;
        switch( $level ) {
                case 0 { $prefix = "[Info]"; }
                case 1 { $prefix = "[Warning]"; }
                case 2 { $prefix = "[Error]"; }
                case 3 { $prefix = "[Debug]"; }
        } #switch
        $message = $prefix . " " . $message;
        # just log on screen
        if ( $syslog_flag == 0 ) {
            print $0 . $message . "\n";
        } #if
        # log to syslog
        if ( $syslog_flag == 1 ) {
            my $fmt = 'ndelay,pid';
            if ( $level == 2 ) {
                $fmt = $fmt.",perror";
            } #if
            openlog( $SCRIPT, $fmt, LOG_LOCAL6 );
            syslog(LOG_INFO, $message );
            closelog();
        } #if

        switch( $level ) {
                case 2 { exit(2) }
        } #switch
} #log

# make_database_connection
sub make_database_connection
{
    my ($db_ini) = @_;

    my $connectionString = 'dbi:mysql:dbname='. $db_ini->{'DbName'} .';host='.$db_ini->{'Host'}.';';

    my $dbh = DBI->connect( $connectionString,
                            $db_ini->{'User'}, $db_ini->{'Password'},
                            { PrintError => 1, AutoCommit => 1, RaiseError => 1 } )
              or logM(2,"database connection error");
    return $dbh;
} # make_database_connection

sub delete_rows
{
    logM(3,"- entering delete function");
    my ($dbh, $ids) = @_;
    my ($file_h_);
    logM(3,"\t\tgot ". ($#{$ids} + 1)." for delete");
    if ( defined $PARAMS{'logdbchanges'} )
    {
        logM(3,"- logdbchanges file defined: " . $PARAMS{'logdbchanges'} );
        open $file_h_,">>",$PARAMS{'logdbchanges'};
    } #if

    my $count =0;
    my $ids_lists ="";
    foreach( @{$ids} )
    {
        $ids_lists .=  $_ .",";
        $count++;
            if ( $count % 1000 eq 0 )
            {
                logM(3,"\t\tdeleting 1000 rows");
                $ids_lists = substr( $ids_lists, 0, -1);
                my $q = $SQLQuery{'delete_rows'};
                $q =~ s/_IDS_/$ids_lists/g;
                my $delete_rows_query = $dbh->prepare( $q );
                if ( defined $PARAMS{'logdbchanges'} ) {
                    print $file_h_ $q . "\n";
                } #if
                $delete_rows_query->execute();
                $ids_lists = "";
                sleep(5); #some rest for database
            } #if
    } #while
    # delete the rest of ids
    if ( $ids_lists ne "" )
    {
        logM(3,"\t\tdeleting the rest which left");
        $ids_lists = substr( $ids_lists, 0, -1);
        my $q = $SQLQuery{'delete_rows'};
        $q =~ s/_IDS_/$ids_lists/g;
        my $delete_rows_query = $dbh->prepare( $q );
        if ( defined $PARAMS{'logdbchanges'} ) {
            print $file_h_ $q . "\n";
        } #if
        $delete_rows_query->execute();
        $ids_lists = "";
    } #if
    if ( defined $PARAMS{'logdbchanges'}) {
        close $file_h_;
    } #if
    logM(3,"\t\tdelete completed. ".$count." rows has been deleted");
} #delete_rows


sub trim($)
{
        my $string = shift;
        $string =~ s/^\s+//;
        $string =~ s/\s+$//;
        return $string;
}

#
# Queries functions
#   If you need to add anotcher table to archivzation you can copy and modify one of the functions
#   from below and set queries.

# function version 1.0.2
# changes: - removed LOW_PRIORITY from DELETE query
#          - fixed count query,
sub set_queryies_owi_trans
{
  my $no_of_days = 35;
  # this var will contain name of ID field, field will be used later to
  $SQLQuery{'ID'} = "owi_transid";
  # this query is used for selecting rows for archivization
  $SQLQuery{'select_ids'} = "SELECT SQL_CACHE * FROM owi_trans WHERE req_date <  DATE_ADD(DATE(NOW()), INTERVAL -".$no_of_days." DAY) AND fkowi_requestsid = 100";
  #count number of rows
  $SQLQuery{'count_rows'}  = "SELECT COUNT(owi_transid) AS count FROM `owi_trans`";
  #place new row into a destination table
  $SQLQuery{'put_row'}     = "INSERT  INTO `owi_trans` VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
  # delete rows, for this operation I'm not using '?' in preparation, I wont work (don't know why).
  # Later before issuing prepare function key word "_IDS_" is replaced by the list of the ips
  $SQLQuery{'delete_rows'} = "DELETE  FROM owi_trans WHERE owi_transid IN ( _IDS_ );";
} # prepare_queryies

# function version 1.0.1
# changes: removed LOW_PRIORITY from DELETE query
sub set_queryies_action_log
{
  my $no_of_days = 380;
  # this var will contain name of ID field, field will be used later to
  $SQLQuery{'ID'} = "logid";
  # this query is used for selecting rows for archivization
  $SQLQuery{'select_ids'}  = "SELECT * FROM `action_log` WHERE logtime <  DATE_ADD(DATE(NOW()), INTERVAL -".$no_of_days." DAY)"; ##380
  #count number of rows
  $SQLQuery{'count_rows'}  = "SELECT COUNT(*) AS count FROM `action_log`";
  #place new row into a destination table
  $SQLQuery{'put_row'}     = "INSERT INTO `action_log` VALUES (?, ?, ?, ?, ?, ?, ?)";
  # delete rows, for this operation I'm not using '?' in preparation, I wont work (don't know why).
  # Later before issuing prepare function key word "_IDS_" is replaced by the list of the ips
  $SQLQuery{'delete_rows'} = "DELETE  FROM `action_log` WHERE logid IN ( _IDS_ );";
} # prepare_queryies

# function version 1.0.1
# changes: removed LOW_PRIORITY from DELETE query
sub set_queryies_totalcheck_requests
{
  my $no_of_days = 60;
  # this var will contain name of ID field, field will be used later to
  $SQLQuery{'ID'} = "";
  # this query is used for selecting rows for archivization
  $SQLQuery{'select_ids'}  = "SELECT * FROM `totalcheck_requests` WHERE `dateentered` <  DATE_ADD(DATE(NOW()), INTERVAL -".$no_of_days." DAY)"; ##
  #count number of rows
  $SQLQuery{'count_rows'}  = "SELECT COUNT(*) AS count FROM `totalcheck_requests`";
  #place new row into a destination table
  $SQLQuery{'put_row'}     = "INSERT INTO `totalcheck_requests` VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)";
  # delete rows, for this operation I'm not using '?' in preparation, I wont work (don't know why).
  # Later before issuing prepare function key word "_IDS_" is replaced by the list of the ips
  $SQLQuery{'delete_rows'} = "DELETE  FROM `totalcheck_requests` WHERE totalcheck_requestid IN ( _IDS_ );";

} # set_queryies_totalcheck_requests

# function version 1.0.1
# changes: removed LOW_PRIORITY from DELETE query
sub set_queryies_bill_trans_invoicedetails
{
  my $no_of_days = trim(`date --date\="45 days ago" +%Y-%m-%d`);
  # this var will contain name of ID field, field will be used later to
  $SQLQuery{'ID'} = "bill_trans_invoicedetails_id";
  # this query is used for selecting rows for archivization
  $SQLQuery{'select_ids'}  =  "SELECT SQL_CACHE * FROM bill_trans_invoicedetails WHERE processed = 1 AND dtcreated <  '".$no_of_days." 00:00:00'";
  #count number of rows
  $SQLQuery{'count_rows'}  = "SELECT COUNT(*) AS count FROM bill_trans_invoicedetails";
  #place new row into a destination table
  $SQLQuery{'put_row'}     =  "INSERT  INTO bill_trans_invoicedetails VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
  # delete rows, for this operation I'm not using '?' in preparation, I wont work (don't know why).
  # Later before issuing prepare function key word "_IDS_" is replaced by the list of the ips
  $SQLQuery{'delete_rows'} = "DELETE  FROM bill_trans_invoicedetails WHERE bill_trans_invoicedetails_id IN ( _IDS_ );"
} # set_queryies_bill_trans_invoicedetails


# function version 1.0.1
# changes: removed LOW_PRIORITY from DELETE query
sub set_queryies_sms_log
{
  my $no_of_days = 105;
  # this var will contain name of ID field, field will be used later to
  $SQLQuery{'ID'} = "sms_logid";
  # this query is used for selecting rows for archivization
  $SQLQuery{'select_ids'}  = "SELECT SQL_CACHE * FROM sms_log WHERE smsdate <  DATE_ADD(DATE(NOW()), INTERVAL -".$no_of_days." DAY)";
  #count number of rows
  $SQLQuery{'count_rows'}  = "SELECT COUNT(*) AS count FROM sms_log";
  #place new row into a destination table
  $SQLQuery{'put_row'}     = "REPLACE INTO sms_log VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
  # delete rows, for this operation I'm not using '?' in preparation, I wont work (don't know why).
  # Later before issuing prepare function key word "_IDS_" is replaced by the list of the ips
  $SQLQuery{'delete_rows'} = "DELETE FROM sms_log WHERE sms_logid IN ( _IDS_ );";
} # set_queryies_sms_log

# function version 1.0.1
# changes: removed LOW_PRIORITY from DELETE query
sub set_queryies_owi_calldata
{
  my $no_of_days = 105;
  # this var will contain name of ID field, field will be used later to
  $SQLQuery{'ID'} = "owi_calldataid";
  # this query is used for selecting rows for archivization
  $SQLQuery{'select_ids'}  = "SELECT SQL_CACHE * FROM owi_calldata_old WHERE call_placed_time <  DATE_ADD(DATE(NOW()), INTERVAL -".$no_of_days." DAY)";
  #count number of rows
  $SQLQuery{'count_rows'}  = "SELECT COUNT(*) AS count FROM owi_calldata_old";
  #place new row into a destination table
  $SQLQuery{'put_row'}     = "REPLACE INTO owi_calldata VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
  # delete rows, for this operation I'm not using '?' in preparation, I wont work (don't know why).
  # Later before issuing prepare function key word "_IDS_" is replaced by the list of the ips
  $SQLQuery{'delete_rows'} = "DELETE FROM owi_calldata_old WHERE owi_calldataid IN ( _IDS_ );";
} # set_queryies_owi_calldata



#TODO:

# - add logging, two levels basic and extended, logs should be send to syslog
# - add logfile which will contain ids which has been processed