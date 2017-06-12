#!/usr/bin/perl
#Application:    Ecconnect script for removing binlog files base on state of Slave hosts.
##Licensee:      GNU General Public License
##Developer:     Marcin Szumski <marcin@ecconnect.com.au> http://www.ecconnect.com.au
$version=        "3.0.0";
##Dependencies:  perl:DBI,perl-Config-Tiny.noarch
##Copyright:     Appscorp PTY LTD T/A ECConnect ACN 122 532 076 ABN 91 122 532 076 C 2010.
##License:       It is free software; you can redistribute it and/or modify it under the terms of either:
##a) the GNU General Public License as published by the Free Software Foundation; either external linkversion 1, or (at your option) any later versionexternal link, or
##b) the "Artistic License".
##
##PURPOSE / USGAE / EXAMPLES / DESCRIPTION:
##--------------------------------------------------------------------------------------------------
## Documentation: http://wf-confluence.ecconnect.com.au:8090/display/WF/removing+binlog+files+with+BinlogCleaner.pl+script
##
##CHANGE LOG:
##--------------------------------------------------------------------------------------------------
##[DATE]      [INITIALS]     [ACTION]
# 08/04/2015  mszumski       added syslog loging. added Pod::Usage for documentation. no changes in script logic

use Switch;
use POSIX;
use Getopt::Long;
use DBI;
use Config::Tiny;
use Sys::Syslog qw(:standard :macros);
use Pod::Usage;

### V A R S ###
#this variable contains global parameters which defines the script logic.
my %CONF_PARAMS;
#this variable contains the key word which are interpreted by the script. If you
#want to extend the configuration parameters list, you need to add the key word to the
#variable below. And after config.ini file will be readed you can read this parameter value
#from the hass array named "CONF_INI_PARAMS"
my @ConfigIniDict = ('port','ipaddr','usernameusernameusernameusername','password','binlog_margin','slaves','master_alias');
#this variable contains readed values from ini file. First 'general' block is readed, and later if same
#param is defined for the database the first is covered.
my %CONF_INI_PARAMS;
#Variable with list of binarylogs readed from master server. Array is fullfilled by read_master_binlogs function.
my @master_binlogs;
#Array with binlog files processed by slave
my @slaves_binlogs;
#Master alias array, array contains hash pointers of aliases under which master can be defined on the slave
my @master_alias;


### M A I N ###                                 << starting here
main();
### E  N  D ###


### Functions
#Main function where whole processing starts.
sub main {
        pod2usage(1) if ($#ARGV == -1);
        GetOptions( 'c|config=s'    => \$CONF_PARAMS{'ConfigFilePath'},
                    'd|database=s'  => \$CONF_PARAMS{'DatabaseID'},
                    's|safe'        => \$CONF_PARAMS{'Bool_SafeMode'},
                    'showconfig'    => \$CONF_PARAMS{'Bool_ShowConfig'},
                    'printinfo'     => \$CONF_PARAMS{'Bool_PrintInfo'},
                    'ignore_slave'  => \$CONF_PARAMS{'Bool_IgnoreSlave'},
                    'run_purge'     => \$CONF_PARAMS{'Bool_RunPurge'},
                    'help|?'        => \$CONF_PARAMS{'Help'},
                    'man'           => \$CONF_PARAMS{'Man'},
                    'V|version'       => sub { printVersion() },
                    'debug'         => \$CONF_PARAMS{'Debug'}
                  );

        pod2usage(1) if $CONF_PARAMS{'Help'};
        pod2usage(-exitstatus => 0, -verbose => 2) if $CONF_PARAMS{'Man'};

#params logic
if ( $CONF_PARAMS{'Bool_SafeMode'} ) { $CONF_PARAMS{'Bool_RunPurge'} = 0 }
if ( $CONF_PARAMS{'ConfigFilePath'} ) {
        #Variable with list of slaves. Array of pointer to hash with databases configuration
        my @SlavesConfig;
        if ( ! defined $CONF_PARAMS{'DatabaseID'} ) {
                logM(2,"You must specify database id (-d|--database)");
        } #if
        #Geting pointer to master hash config ini
        my $hpt_master = readConfigFile($CONF_PARAMS{'DatabaseID'});
        #Get Slaves from master
    my $arrpt_slaves = getSlaves( $hpt_master );
        #Read configuration for each slave
        foreach( @{$arrpt_slaves} ) {
                my $hpt_slave = readConfigFile($_);
                push @SlavesConfig, $hpt_slave;
        } #foreach
    #Prepare master alias array base on readMasterAlias parameter in ini file
    readMasterAlias($hpt_master);
#    foreach ( @master_alias ) {
#        while( my($k,$v) = each(%$_) ) {
#            print "$k :: $v\n";
#        } #while
#    print "-----------------------\n";
#    } #foreach
#    exit(0);
        if ( $CONF_PARAMS{'Bool_ShowConfig'} ) {
                printIniConfig( $hpt_master,\@SlavesConfig );
                exit(0);
        } #if

    #fullfiling the master_binlogs array with the binlogs on the master
    read_master_binlogs($hpt_master);
    my $index; #look below
    if ( ! $CONF_PARAMS{'Bool_IgnoreSlave'} ) {
    #reads the slaves Relay_Master_Log_File and puts them into @slaves_binlogs
    foreach ( @SlavesConfig ) {
        read_slave_binlogs($_);
    } #foreach
    #reads for oldest binlog in use by a slaves
    $index = search_for_oldest_binlog_in_use();
   } #if - !Bool_IgnoreSlave

    #calculates a new index, base on configuration params
    my $indexPurge = getIndexBinlogForPrune($hpt_master,$index);


    if ( $CONF_PARAMS{'Bool_PrintInfo'} ) {
        print_info($hpt_master,\@SlavesConfig,$index,$indexPurge);
        exit(0);
    } #if

    if ( $CONF_PARAMS{'Bool_SafeMode'} ) {
         print "Purge query: purge binary logs to '" . $master_binlogs[$indexPurge] . "'\n";
         exit(0);
    } #if

    if ( $CONF_PARAMS{'Bool_RunPurge'} and !$CONF_PARAMS{'Bool_SafeMode'} ) {
        RunPurgeOnMaster($hpt_master,$indexPurge);
        exit(0);
    } #if

    print $master_binlogs[$indexPurge] . "\n";
    exit(0);

#    print "-". $master_binlogs[$index] . "\n";

#       while( my($k,$v) = each(%$hpt_master) ) {
#               print "$k :: $v\n";
#       }
} #if
} #main
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub printVersion
{
        print "$0 version: $version\n";
        exit(0);
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub readMasterAlias {
    my ($hpt_master) = @_;
    my $slaves_list = trim($hpt_master->{'master_alias'});
    my @aliases = split(/,/,$slaves_list);
    foreach ( @aliases ) {
        my @alias = split(/:/,trim($_));
        my %alias_hash;
        $alias_hash{'host'} = $alias[0];
        $alias_hash{'port'} = $alias[1];
        push @master_alias, \%alias_hash;
    } #foreach
} #readMasterAlias
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#Connects to the master database and base on the colected information
#executes purge query
sub RunPurgeOnMaster {
    my ($master_hash,$indexPurge) = @_;

    if ( ! defined $master_binlogs[$indexPurge] ) {
        logM(12,"Binlog file for purge doesn't exists. Probably binlog_margin value is to high.");
    } #if

    my $dbh = connect_to_DB( $master_hash );

    my $query    = "purge binary logs to '".$master_binlogs[$indexPurge]."'";
#    print "RunPurgeOnMaster: $query \n";
    my $sqlQuery  = $dbh->prepare($query)
            or logM(12,"Section:".$CONF_PARAMS{'DatabaseID'}." SQL prepare error. Can't prepare \'$query\': $dbh->errstr");
    my $rv = $sqlQuery->execute
            or logM(12,"Section:".$CONF_PARAMS{'DatabaseID'}." Are you sure that this is master?\nSQL prepare error. Can't execute the query \'$query\': $sqlQuery->errs
tr");
    my $rc = $sqlQuery->finish;
    logM(10,"Section:".$CONF_PARAMS{'DatabaseID'}." Query executed: $query");
} #RunPurgeOnMaster
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#Gets the hash pointer as an argument and reads the slaces list
#from it. Return the array of slaves.
sub getSlaves {
    my ($DB_hash) = @_;
        my $slaves_list = $DB_hash->{'slaves'};
        $slaves_list = trim($slaves_list);
        my @slaves = split(/,/,$slaves_list);
    return \@slaves;
} #getSlaves
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Writes a message to the log.
# use Sys::Syslog;
# v2.0
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
            print $0 . $message . "\n";
            closelog();
        } #if

        switch( $level ) {
                case 2 { exit(2) }
        } #switch
} #log
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#Reads config ini file. Exits if file doesn't exists. Function retuns
#the hash with the database configuration block
sub readConfigFile {
        my ($databaseID) = @_;
        my %DB;
    $DB{'section_name'} = $databaseID;
        #Check if file exists
        if ( ! -e $CONF_PARAMS{'ConfigFilePath'} ) {
                logM(12,"Section:".$CONF_PARAMS{'DatabaseID'}." Config file doesn't exists");
        } #if
        if ( ! -r $CONF_PARAMS{'ConfigFilePath'} ) {
                logM(12,"Section:".$CONF_PARAMS{'DatabaseID'}." Cannot read config file. Permission denied");
        } #if
        $Config = Config::Tiny->read( $CONF_PARAMS{'ConfigFilePath'} );

        # -- loading generic block to the %CONF_INI_PARAMS array
        foreach ( @ConfigIniDict ) {
                my $pname = $_;
                $DB{$pname} = $Config->{generic}->{$pname};
        } #foreach
    # -- checking if section in configuration file exists
    my $section = $Config->{$databaseID};
    if ( ! defined $section ) {
        logM(12,"Section:".$CONF_PARAMS{'DatabaseID'}." Section in configuration file doesn't exists");
    } #if
        # -- reloading database block to the %CONF_INI_PARAMS array
        foreach ( @ConfigIniDict ) {
                my $pname = $_;
                if ( defined $Config->{$databaseID}->{$pname} ) {
                  $DB{$pname} = $Config->{$databaseID}->{$pname};
                } #if
        } #foreach

   return \%DB;
} #readConfigFile
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# This function just prints the CONF_INI_PARAMS hash
sub printIniConfig {
        my ($master, $slaves) = @_;
        #printing master config
        print "======= MASTER ========\n";
        while ( my ($k,$v) = each (%$master) ) {
                print "$k = $v \n";
        } #while
        foreach( @{$slaves} ) {
                print "\t======= SLAVE ========\n";
                my $ptr = $_;  #pointer to hash
                while ( my ($k,$v) = each(%$ptr) ) {
                        print "\t\t$k = $v \n";
                } #while
        } #foreach
} #printIniConfig
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#This function gets the database hash pointer as an argument and returns the
#database DBI object.
sub connect_to_DB {
        my ( $DB_hash ) = @_;
        #check for mandatory fields needed to execute this function
        my @mandatoryDict = ('port','ipaddr','username','password');
        foreach ( @mandatoryDict ){
                if ( ! defined $DB_hash->{$_} ){
                  logM(12,"Section:".$CONF_PARAMS{'DatabaseID'}." Mandatory master parameter \'".$_."\' is not defined");
                } #if
        } #foreach
        my $ipaddr   =  $DB_hash->{'ipaddr'};
        my $port     =  $DB_hash->{'port'};
        my $username =  $DB_hash->{'username'};
        my $password =  $DB_hash->{'password'};
        #print "IP:".$ipaddr." Port:". $port . " username:" . $username . " password:" . $password ."\n";
        #print "Query: " . $query . "\n";
        my $dbh = DBI->connect("DBI:mysql::".$ipaddr.":".$port, $username, $password);
        if ( !defined $dbh ) {
            logM(12,"Section:".$CONF_PARAMS{'DatabaseID'}." Cannot establish connection to the database ($ipaddr:$port)");
        } #if
        return $dbh;
} #connect_to_DB
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Reads the list of binlogs from master
sub read_master_binlogs {
        my ($master_hash) = @_;
        my $dbh = connect_to_DB( $master_hash );
        my $query    = "show binary logs";
        my $sqlQuery  = $dbh->prepare($query)
        or logM("Section:".$CONF_PARAMS{'DatabaseID'}." SQL prepare error. Can't prepare \'$query\': $dbh->errstr\n");

        my $rv = $sqlQuery->execute
        or logM("Section:".$CONF_PARAMS{'DatabaseID'}." Are you sure that this is master?\nSQL prepare error. Can't execute the query \'$query\': $sqlQuery->errstr");

        while (@row= $sqlQuery->fetchrow_array()) {
                push @master_binlogs, $row[0];
        } #while
        my $rc = $sqlQuery->finish;
           $rc = $dbh->disconnect;
} #read_master_binlogs
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#Reads the 10-th column from slave status query which is "Relay_Master_Log_File"
#puts this value append the @slaves_binlogs array. Returns nothing.
sub read_slave_binlogs {
    my ($slave_hash) = @_;
    my $dbh = connect_to_DB( $slave_hash );
    my $query = "show slave status";
    my %master_host;
    my $sqlQuery  = $dbh->prepare($query)
    or logM(2,"Section:".$CONF_PARAMS{'DatabaseID'}." SQL prepare error. Can't prepare \'$query\': $dbh->errstr\n");

    my $rv = $sqlQuery->execute
    or logM(2,"Section:".$CONF_PARAMS{'DatabaseID'}." SQL prepare error. Can't execute the query \'$query\': $sqlQuery->errstr");

    while (@row= $sqlQuery->fetchrow_array()) {
            push @slaves_binlogs, $row[9];
            $master_host{'host'}  = $row[1];
            $master_host{'port'}  = $row[3];
            if ( ! checkIfSlaveBelongsToMaster( \%master_host ) ) {
                my $msg = "Section:".$CONF_PARAMS{'DatabaseID'}."\nOn slave (".$slave_hash->{'ipaddr'}.":".$slave_hash->{'port'}.") defined master is:\n";
                $msg .= "\t-host: $master_host{'host'} \n\t-ip:$master_host{'port'}\n";
                $msg .= "which doesn't fit to the master alias entry in the configuration file.";
                $msg .= "\nCheck if slave is correct, or add allias to the config file.";
                logM(12,"$msg");
            } #if
    } #while
    my $rc = $sqlQuery->finish;
    $rc = $dbh->disconnect;
} #read_slave_binlogs
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#compares hash
sub checkIfSlaveBelongsToMaster {
    my ($s) = @_;
    foreach ( @master_alias ) {
        my $m = $_;
        if ( $m->{'host'} eq $s->{'host'} ) {
            if ( $m->{'port'} eq $s->{'port'} ) {
               return 1;
            } #if
        } #if
    } #foreach
return 0;
} #checkIfSlaveBelongsToMaster
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#Reads the slaves binarylogs and checks which of this files is the oldes one
#returns the index to the master_binlogs array.
sub search_for_oldest_binlog_in_use {
        my $candidate=99999;
        foreach (@slaves_binlogs) {
                $element = $_;
                if (!(grep {$_ eq $element} @master_binlogs)) {
                    logM(12,"Section:".$CONF_PARAMS{'DatabaseID'}." Cannot find binlog file ".$element."on the masters binarylog list");
                } #if
                my $index=0;
                ++$index until $master_binlogs[$index] eq $element or $index > $#master_binlogs;
                if ( $index < $candidate ) { $candidate = $index }
        } #foreach
        return $candidate;
} #search_for_oldest_binlog_in_use
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#Gets the master hash and index of oldest binlog in user (array master_binlogs)
#as an argument, base on binlog_margin, shifts down the list, and returns the
#new index of binarylog which sould be removed.
sub getIndexBinlogForPrune {
    my ($master_hash,$usedIndex) = @_;
        my @mandatoryDict = ('binlog_margin');
        foreach ( @mandatoryDict ){
                if ( ! defined $master_hash->{$_} ){
                  logM(2,"Section:".$CONF_PARAMS{'DatabaseID'}." Mandatory master parameter \'".$_."\' is not defined");
                } #if
        } #foreach
    my $newIndex;
    if ( ! $CONF_PARAMS{'Bool_IgnoreSlave'} ) {
        $newIndex = $usedIndex - $master_hash->{'binlog_margin'};
    } #if

    if ( $CONF_PARAMS{'Bool_IgnoreSlave'} ) {
        $newIndex = $#master_binlogs - $master_hash->{'binlog_margin'};
    } #if
    return $newIndex;
} #getIndexBinlogForPrune
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub trim($)
{
        my $string = shift;
        $string =~ s/^\s+//;
        $string =~ s/\s+$//;
        return $string;
} #trim
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#just perform some report
sub print_info {
    my ($hpt_master,$SlavesConfig,$index,$indexPurge) = @_;
    printIniConfig( $hpt_master,$SlavesConfig );
    print "--- Master binlogs ---\n";
    print "\t$_\n" foreach (@master_binlogs);
    print "--- Slaves binlogs ---\n";
    print "\t$_\n" foreach (@slaves_binlogs);
    print "---\n";
    if ( ! $CONF_PARAMS{'Bool_IgnoreSlave'} ) {
     print "Oldest binary log in use by slaves : " . $master_binlogs[$index] . "\n";
    } #if
    print "Binary log for purge: " . $master_binlogs[$indexPurge] . "\n";
    print "Purge query: purge binary logs to '" . $master_binlogs[$indexPurge] . "'\n";
} #print_info
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
=head1 NAME

BinlogCleaner2.pl - removing binlog files from master

=head1 SYNOPSIS

BinlogCleaner2.pl [options] [-help] [-man]

=head1 OPTIONS

=over 8

=item B<-d --database SECTION>

master database section name

=item B<-c --config INI_FILE>

sets configuration file with the databases sections

=item B<-s --safe>

will not run purge query on the server

=item B<-showconfig>

prints databases sections related to the master

=item B<-printinfo>

prints exdended information about the master and slaves

=item B<-run_purge>

will run the purge command on the master

=item B<-ignore_slave>

ignores slves binlogs, even not connects to slave

=item B<-help>

Print a brief help message and exits.

=item B<-man>

Prints the manual page and exits.

=item B<-V --version>

Prints script version and exit

=back

=head1 DESCRIPTION

B<BinlogCleaner2.pl> removes binlog files from the mysql master host. Script is reading configuration parameters from the ini file. Ini file contains
databases information as user, pasword, port and relations between databases. Script is connecting to the mastar and all slaved and is checking
if binlog files for deletion has been applied on the slaves. If yes than script is runing PURGE query.

Example ini file:

[generic] E<10> E<8>
username=BinlogCleaner E<10> E<8>
password=***password*** E<10> E<8>
binlog_margin=10 E<10>
[eclb004_3306]E<10> E<8>
port=3306 E<10> E<8>
binlog_margin=5 E<10> E<8>
ipaddr=192.168.0.14 E<10> E<8>
slaves=vm-ecrep001_3306,vm-ecrep001_3312 E<10> E<8>
master_alias=192.168.0.14:3306 E<10>
[vm-ecrep001_3306] E<10> E<8>
port=3306 E<10> E<8>
ipaddr=192.168.0.22 E<10>
[vm-ecrep001_3312] E<10> E<8>
port=3312 E<10> E<8>
ipaddr=192.168.0.22 E<10> E<8>

=head2 Syslog

RunPurgeOnMaster function is loging into syslog (LOG_LOCAL6)


=head1 AUTHOR

        WebFusion 2015, Marcin Szumski

        Documentation: http://wf-confluence.ecconnect.com.au:8090/display/WF/removing+binlog+files+with+BinlogCleaner.pl+script

=cut