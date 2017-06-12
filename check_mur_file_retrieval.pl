#!/usr/bin/perl
#Application:    Ecconnect Centreon Functions
##Licensee:      GNU General Public License
##Version:       1.0.0
##Dependencies:  None
##Copyright:     Appscorp PTY LTD T/A ECConnect ACN 122 532 076 ABN 91 122 532 076 C 2010.
##License:       It is free software; you can redistribute it and/or modify it under the terms of either:
##a) the GNU General Public License as published by the Free Software Foundation; either external linkversion 1, or (at your option) any later versionexternal link, or
##b) the "Artistic License".
##
## PURPOSE / USGAE / EXAMPLES / DESCRIPTION:
##--------------------------------------------------------------------------------------------------
## description here
## You need to install perl-Config-Tiny.noarch package
## CHANGE LOG:
##--------------------------------------------------------------------------------------------------
## [DATE]    [INITIALS]                           [ACTION]
##

use Getopt::Long;
use Config::Tiny;
use Switch;
use DBI;

sub normal_mode;
sub print_usage;

my %CONFIG;
my %PARAMS;
my %DB;
my @INI_PARAMS = ('port','ip','fileformat','user','password','query');
my $db = "sp_mur";
my $exit_value = 0;

#==================== CONFIGURATION ====================

$CONFIG{'PATH'} = "/usr/local/nagios/etc/";
$CONFIG{'FILE'} = "mur_file_retrieval_check.ini";

#==================== M A I N  =========================

parse_entry();

#==================== F U N C T I O N S ================

sub parse_entry{
    if ( $#ARGV == -1 ) { print_usage(); } #if

    GetOptions( 'db|database=s'  => \$PARAMS{'database' },
                'pp|print'       => sub{ print_params() },
                'c|config=s'     => \$CONFIG{'FILE'},
                'help|?'         => sub{ print_usage()  }
              );

    #params logic
    if ( (!defined $PARAMS{'database'} )) {
        print ("Missing some parameters\nTry $0 --help\n");
        exit(1);
    } #if

    normal_mode(); #starting main code

    exit 1;
} #parse_entry

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

sub print_usage{
        print "Usage:\n";
        print "\t$0 [--help] [-db|--database database_section]\n";
        exit(0);
} #print_usage

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

sub normal_mode(){

  #READING CONFIGURATION FILE
        my $Config = Config::Tiny->new;
        my $INI = $CONFIG{'PATH'} . $CONFIG{'FILE'};
        $Config = Config::Tiny->read( $INI );
        my @INI_PARAMS = ('port','ip','fileformat','user','password','query');

        foreach ( @INI_PARAMS ) {
          my $pname = $_;
          $DB{$pname} = $Config->{generic}->{$pname};
        }

        foreach ( @INI_PARAMS ) {
          my $pname = $_;
          if ( defined $Config->{ $PARAMS{'database'} }->{$pname} ) {
                $DB{$pname} = $Config->{ $PARAMS{'database'} }->{$pname};
          }
        }

  #GETTING THE QUERY
       my $query = $DB{'query'};

  #MAKING THE DATABASE CONNECTION
        $dbh = DBI->connect("DBI:mysql:$db:".$DB{'ip'}.":".$DB{'port'}.":mysql_connect_timeout=2", $DB{'user'}, $DB{'password'})
        or die "Connection error: $DBI::errstr\n";

        my $sth = $dbh->prepare($query);
        $sth->execute() or die "SQL error: $DBI::errstr\n";

        my $value = $sth->fetchrow_array();

        if ( $value < 3600 ) {
             $exit_value = 0;
             print "[OK] All okay, last file arrived before $value seconds";
        }
        else {
            if ( $value >= 3600 ) {
                $exit_value = 1;
                print "[WARNING] No MUR files for the past hour $value seconds";
            } else {
                 $exit_value = 2;
                 print "[CRIT] No MUR files for the past hour $value seconds";
           }
        }


  exit($exit_value);
} #normal_mode

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

sub print_params {
        my $Config = Config::Tiny->new;
        my $INI = $CONFIG{'PATH'} . $CONFIG{'FILE'};
        print "opening config file: $INI\n";
        $Config = Config::Tiny->read( $INI );
        print "generic class:\n";

        foreach ( @INI_PARAMS ) {
          my $pname = $_;
          my $pval  = $Config->{generic}->{$pname};
          print "\t" . $pname ."=". $pval . "\n";
        } #foreach
        print $PARAMS{'database'} . "class:\n";

        foreach ( @INI_PARAMS ) {
          my $pname = $_;
          my $pval  = $Config->{ $PARAMS{'database'} }->{$pname};
          print "\t" . $pname ."=". $pval . "\n";
        } #foreach
  exit(0);
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

sub executeQuery {
        my ($dbh,$query,$field) = @_;
        if (!defined $dbh) { return };

        #my $fileformat = $DB{'fileformat'};

        my $sqlQuery  = $dbh->prepare($query)
                or die date_string() . " Error: Can't prepare $query: $dbh->errstr\n";
        my $rv = $sqlQuery->execute
                or die date_string() . " Error: can't execute the query: $sqlQuery->errstr";
        print $rv
        my @row= $sqlQuery->fetchrow_array();
        my $rc = $sqlQuery->finish;

        return $row[$field];
} #executeQuery

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -