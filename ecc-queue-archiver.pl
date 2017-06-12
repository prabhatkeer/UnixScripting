#!/usr/bin/perl
#Application:    Gets row in tables
#Licensee:      GNU General Public License
#Developer:     Marcin Szumski <marcin@ecconnect.com.au> http://www.ecconnect.com.au
$version=        "1.1.0";
#Dependencies:  perl:DBI,perl-Config-Tiny.noarch
#Copyright:     Appscorp PTY LTD T/A ECConnect ACN 122 532 076 ABN 91 122 532 076 C 2010.
#License:       It is free software; you can redistribute it and/or modify it under the terms of either:
#a) the GNU General Public License as published by the Free Software Foundation; either external linkversion 1, or (at your option) any later versionexternal link, or
#b) the "Artistic License".
#
#PURPOSE / USGAE / EXAMPLES / DESCRIPTION:
#--------------------------------------------------------------------------------------------------
# Documentation: https://confluence.ecconnect.com.au/display/EAP/Queue+archive
# Ticket: https://jira.ecconnect.com.au/browse/EAP-665
#CHANGE LOG:
#--------------------------------------------------------------------------------------------------
#[DATE]       [INITIALS]      [ACTION]
#21/05/2015       mszumski    version 1.0.0
#10/06/2015       mszumski    version 1.1.0 - adding -graphite option for collecting and sending metrics to graphite

use Getopt::Long;
use Pod::Usage;
use warnings;
use Fcntl qw(:flock);
use Switch;
use Config::Tiny;
use POSIX;
use DBI;
use Sys::Syslog qw(:standard :macros);
use Net::Statsd;

# - Globals
my $lockfile = '/tmp/lock_file_ecc-queue-qrchiver';
my $SCRIPT = 'ecc-queue-archiver.pl';
my %CONF_PARAMS;
#this variable contains the key word which are interpreted by the script. If you
#want to extend the configuration parameters list, you need to add the key word to the
#variable below. And after config.ini file will be readed you can read this parameter value
#from the hass array named "CONF_INI_PARAMS"
my @ConfigIniDict = ('port','ipaddr','username','password','source_table','dest_table','number_of_days','database_name','id_field','metric_name');
my @ConfigGraphiteIniDict = ('port','ipaddr','protocol');
#we want to catch all the signals
use sigtrap 'handler' => \&sigtrap, 'HUP', 'INT','ABRT','QUIT','TERM';
### M A I N ###                                 << starting here
main();
### E  N  D ###

### Functions
#Main function where whole processing starts.
sub main {
        pod2usage(1) if ($#ARGV == -1);

        open(my $fhpid, '>', $lockfile) or die "error: open '$lockfile': $!";
        flock($fhpid, LOCK_EX|LOCK_NB) or BailOut();

        GetOptions(
                                'c|config=s'    => \$CONF_PARAMS{'ConfigFilePath'},
                                's|section=s'   => \$CONF_PARAMS{'DatabaseID'},
                                'man'           => \$CONF_PARAMS{'Man'},
                                'help|?'        => \$CONF_PARAMS{'Help'},
                                'debug'         => \$CONF_PARAMS{'Debug'},
                                'print_config'  => \$CONF_PARAMS{'PrintConfig'},
                                'graphite'      => \$CONF_PARAMS{'Graphite'}
        );

        logM(3,"debug on");
        pod2usage(1) if $CONF_PARAMS{'Help'};
        pod2usage(-exitstatus => 0, -verbose => 2) if $CONF_PARAMS{'Man'};

        logM(3,"reading config file for db section");
        my $config = readConfigFile($CONF_PARAMS{'ConfigFilePath'},$CONF_PARAMS{'DatabaseID'},\@ConfigIniDict);
        logM(3,"reading config file for graphite section");
        my $graphite = readConfigFile($CONF_PARAMS{'ConfigFilePath'},"graphite",\@ConfigGraphiteIniDict);
        if ($CONF_PARAMS{'PrintConfig'}) {
                                                                                printIniConfig($config,$CONF_PARAMS{'DatabaseID'});
                                                                                printIniConfig($graphite,"graphite");
                                                                                exit 0;
        } #if

        logM(3,"connecting to the database");
        my $dbh = connect_to_DB( $config );
        logM(3,"will just collect data, send to graphite and exit");
        send_graphite_data($dbh,$config,$graphite) if $CONF_PARAMS{'Graphite'};
        logM(3,"configuring statsd: host:".$graphite->{'ipaddr'}." port:".$graphite->{'port'});
        $Net::Statsd::HOST = $graphite->{'ipaddr'};
        $Net::Statsd::PORT = $graphite->{'port'};
        logM(3 ,"starting archiving for section:" . $CONF_PARAMS{'DatabaseID'} . " number_of_days:" . $config->{'number_of_days'});
        logM(3 ,"starting collecting stats");
        my $stats_before = getStats($dbh,$config);
        logM(10,"starting archiving for section:" . $CONF_PARAMS{'DatabaseID'} . " number_of_days:" .
                $config->{'number_of_days'} .
                " source_row_count:" . $stats_before->{'QRY_source_row_count'}->{'value'} .
                " dst_row_count:" . $stats_before->{'QRY_dst_row_count'}->{'value'} .
                " source_maxid:" . $stats_before->{'QRY_source_maxid'}->{'value'} .
                " dst_maxid:" . $stats_before->{'QRY_dst_maxid'}->{'value'}
                );
        send_stats_from_hash($stats_before);
        ArchiveRows($dbh, $config->{'number_of_days'},$stats_before->{'QRY_days_in_src'}->{'value'});
        my $stats_after = getStats($dbh,$config);
        send_stats_from_hash($stats_after);
        logM(10,"archive complete for section:" . $CONF_PARAMS{'DatabaseID'} . " number_of_days:" .
                $config->{'number_of_days'} .
                " source_row_count:" . $stats_after->{'QRY_source_row_count'}->{'value'} .
                " dst_row_count:" . $stats_after->{'QRY_dst_row_count'}->{'value'} .
                " source_maxid:" . $stats_after->{'QRY_source_maxid'}->{'value'} .
                " dst_maxid:" . $stats_after->{'QRY_dst_maxid'}->{'value'}
                );
} #main
# - - - - - - - - F U N C T I O N S - - - - - - - - - - - - - - - - -
#protect for one instance
sub BailOut {
    print "$0 is already running. Exiting.\n";
    print "(File '$lockfile' is locked).\n";
    exit(1);
} #BailOut
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub sigtrap(){
   logM(3,"sig_handler() - signal catched");
   logM(12,"Program terminated by signal");
   exit(1);
} #sigtrap
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub send_graphite_data {
        my ($dbh,$config,$graphite) = @_;
        $Net::Statsd::HOST = $graphite->{'ipaddr'};
        $Net::Statsd::PORT = $graphite->{'port'};
        logM(3 ,"starting collecting stats");
        my $stats_before = getStats($dbh,$config);
        logM(3,"collected data for section:" . $CONF_PARAMS{'DatabaseID'} . " number_of_days:" .
                $config->{'number_of_days'} .
                " source_row_count:" . $stats_before->{'QRY_source_row_count'}->{'value'} .
                " dst_row_count:" . $stats_before->{'QRY_dst_row_count'}->{'value'} .
                " source_maxid:" . $stats_before->{'QRY_source_maxid'}->{'value'} .
                " dst_maxid:" . $stats_before->{'QRY_dst_maxid'}->{'value'}
                );
        send_stats_from_hash($stats_before);
 exit(0);
} #send_graphite_data
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub send_stats_from_hash {
        my ($hash) = @_;
        foreach $key ( keys %{$hash} ) {
                send_stats(
                        $hash->{$key}->{'name'},
                        $hash->{$key}->{'value'}
                );
        } #foreach
} #send_stats_from_hash
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub send_stats {
        my ($metric_name,$value) = @_;
        logM(3,"send_stats: ".$metric_name.":".$value);
        Net::Statsd::gauge( $metric_name,$value  );
} #sent_stats
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub getStats {
        my ($dbh,$config) = @_;
        my %q_array;
        my %ret_array;
        $q_array{'QRY_source_row_count'} = "select count(*) from ".$config->{'source_table'};
        $q_array{'QRY_dst_row_count'}    = "select count(*) from ".$config->{'dest_table'};
        $q_array{'QRY_source_maxid'}     = "select max(".$config->{'id_field'}.") from ".$config->{'source_table'};
        $q_array{'QRY_dst_maxid'}        = "select max(".$config->{'id_field'}.") from ".$config->{'dest_table'};
        $q_array{'QRY_days_in_src'}      = "select count(distinct date(DateTimeInserted)) from " . $config->{'source_table'} .
                                           " where FK_status_id IN (4,5)";
        $q_array{'QRY_days_in_dest'}     = "select count(distinct date(DateTimeInserted)) from " . $config->{'dest_table'};

        logM(3,time . " getStats: QRY_source_row_count");
        $ret_array{'QRY_source_row_count'} = {
                name  => $config->{'metric_name'}.".".$config->{'source_table'}."_rowcount",
                value => executeSimpleQuery($dbh,$q_array{'QRY_source_row_count'})
        };
        logM(3,time . " getStats: QRY_dst_row_count");
        $ret_array{'QRY_dst_row_count'} = {
                name  => $config->{'metric_name'}.".".$config->{'dest_table'}."_rowcount",
                value => executeSimpleQuery($dbh,$q_array{'QRY_dst_row_count'})
        };
        logM(3,time . " getStats: QRY_source_maxid");
        $ret_array{'QRY_source_maxid'}  = {
                name  => $config->{'metric_name'}.".".$config->{'source_table'}."_maxid",
                value => executeSimpleQuery($dbh,$q_array{'QRY_source_maxid'})
        };
        logM(3,time . " getStats: QRY_dst_maxid");
        $ret_array{'QRY_dst_maxid'} = {
                name  =>  $config->{'metric_name'}.".".$config->{'dest_table'}."_maxid",
                value =>        executeSimpleQuery($dbh,$q_array{'QRY_dst_maxid'})
        };
        logM(3,time . " getStats: QRY_days_in_src");
        $ret_array{'QRY_days_in_src'} = {
                name  =>  $config->{'metric_name'}.".".$config->{'source_table'}."_daysin",
                value =>  executeSimpleQuery($dbh,$q_array{'QRY_days_in_src'})
        };
        logM(3,time . " getStats: QRY_days_in_dest");
        $ret_array{'QRY_days_in_dest'} = {
                name  =>  $config->{'metric_name'}.".".$config->{'dest_table'}."_daysin",
                value =>  executeSimpleQuery($dbh,$q_array{'QRY_days_in_dest'})
        };
        logM(3," getStats - exiting function");
        return \%ret_array;
} #getStats
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# just reads first field from the query result
sub executeSimpleQuery {
        my ($dbh,$query) = @_;
        logM(3,"executeSimpleQuery('".$query."')");
        my $ret_value;
        my $sqlQuery  = $dbh->prepare($query)
                        or die  "SQL prepare error. Can't prepare \'$query\': $dbh->errstr\n";
        my $rv = $sqlQuery->execute()
                        or die  "Can't execute the query \'$query\': $sqlQuery->errstr";
        logM(3,"executeSimpleQuery - query executed");
        $sqlQuery->bind_columns( undef, \$ret_value );
        $sqlQuery->fetch();
        $ret_value = "NULL" if !defined $ret_value;
        logM(3,"executeSimpleQuery. Return val:".$ret_value);
        $rv = $sqlQuery->finish;
        return $ret_value;
} #executeSimpleQuery
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
sub ArchiveRows {
        my ($dbh,$number_of_days,$days_in_db) = @_;
        logM(3,"ArchiveRows(".$number_of_days.",".$days_in_db.")");
        $number_of_days++; # I'm including today into a counter
        if ( $days_in_db <= $number_of_days ) {
                logM(3 ,"ArchiveRows, nothing to do - (days_in_db($days_in_db) <= number_of_days($number_of_days))");
                logM(10,"ArchiveRows, nothing to do - (days_in_db($days_in_db) <= number_of_days($number_of_days))");
        } else {
                logM(3,"ArchiveRows (days_in_db($days_in_db) > number_of_days($number_of_days))");
                # Number of days in database is higher than the reqired. But I want to archive only day by day
                # to avoid to big operation on the database
                $number_of_days = $days_in_db;
                $number_of_days --; # script is archaving rows older than the value so we need to decrease the number_of_days
                $number_of_days --; # additionally query for archive procedure is executing query with "DATE_ADD(DATE(NOW()), INTERVAL -number_of_days DAY)"
                                    # so we need to decrease number_of_days once more
                my $query_call_procedure  = "CALL archive_queue(".$number_of_days.")";
                logM(3,"Calling procedure:" . $query_call_procedure);
                my $query = $dbh->prepare($query_call_procedure) or logM(12,"ArchiveRows, cannot prepare query");
                sleep 120;
                $query->execute() or logM(12,"ArchiveRows(), Cannot execute archive query");
                $query->finish();
        } #if
        logM(3,"ArchiveRows end");
}  #ArchiveRows
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
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
        if ( $level == 3 and ! defined $CONF_PARAMS{'Debug'} ) { return; }
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
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# This function just prints the CONF_INI_PARAMS hash
sub printIniConfig {
        my ($config, $decription) = @_;
        #printing master config
        print "======= $decription ========\n";
        while ( my ($k,$v) = each (%$config) ) {
                print "$k = $v \n";
        } #while
} #printIniConfig
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#Reads config ini file. Exits if file doesn't exists. Function retuns
#the hash with the database configuration block
sub readConfigFile {
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
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#This function gets the database hash pointer as an argument and returns the
#database DBI object.
sub connect_to_DB {
        my ( $DB_hash ) = @_;
        my %attr = (RaiseError=>1,  # error handling enabled
                        PrintError=>0,
                         HandleError => \&handle_database_error,
                            AutoCommit=>1);
        #check for mandatory fields needed to execute this function
        my @mandatoryDict = ('port','ipaddr','username','password','database_name');
        foreach ( @mandatoryDict ){
                if ( ! defined $DB_hash->{$_} ){
                  logM(2,"Mandatory master parameter \'".$_."\' is not defined");
                } #if
        } #foreach
        my $ipaddr   =  $DB_hash->{'ipaddr'};
        my $port     =  $DB_hash->{'port'};
        my $username =  $DB_hash->{'username'};
        my $password =  $DB_hash->{'password'};
        #print "IP:".$ipaddr." Port:". $port . " username:" . $username . " password:" . $password ."\n";
        #print "Query: " . $query . "\n";
        my $dbh = DBI->connect("DBI:mysql:".$DB_hash->{'database_name'}.":".$ipaddr.":".$port, $username, $password, \%attr);
        if ( !defined $dbh ) {
            logM(2,"Cannot establish connection to the database ($ipaddr:$port)");
        } #if
        return $dbh;
} #connect_to_DB
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub handle_database_error {
        my $error = shift;
        logM(12,"Database error: ". $DBI::errstr );
} #handle_database_error
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
__END__

=head1 NAME

ecc-queue-archiver.pl - archive queue jobs

=head1 SYNOPSIS

ecc-queue-archiver.pl [options] [file ...]

=head1 OPTIONS

=over 8

=item B<-s|--section>

ini section name

=item B<-c|--config>

Config ini file

=item B<-graphite>

With this option script will only collect the data and send the metrics to graphite defined in the B<graphite> section in configuration file

=item B<-help>

Print a brief help message and exits.

=item B<-man>

Prints the manual page and exits.

=item B<-debug>
Debug mode

=back

=head1 DESCRIPTION

B<ecc-queue-archiver.pl> - archives rows by moving the from one table to another

Configuration file example:E<10>

[generic]E<10>
username=usernameE<10>
password=*****E<10>
[db]E<10> E<8>
port=3306E<10> E<8>
ipaddr=192.168.56.2E<10> E<8>
database_name=queueE<10> E<8>
source_table=queueE<10> E<8>
dest_table=queue_archE<10> E<8>
#number of days which you want to keep in tableE<10> E<8>
number_of_days=4E<10> E<8>
#name of id filed on which we will take the statistics<10> E<8>
id_field=id<10>
=cut