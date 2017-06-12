#!/usr/bin/python2.6
## Application:   Ecconnect Centreon Functions
## Licensee:      GNU General Public License
## Developer:     Prabhat Keer <prabhat@ecconnect.com.au> http://www.ecconnect.com.au
## Version:       1.0.0
## Dependencies:  None
## Copyright:     Appscorp PTY LTD T/A ECConnect ACN 122 532 076 ABN 91 122 532 076 C 2010.
## License:       It is free software; you can redistribute it and/or modify it under the terms of either:
## a) the GNU General Public License as published by the Free Software Foundation; either external linkversion 1, or (at your option) any later versionexternal link, or
## b) the "Artistic License".
##
## PURPOSE / USGAE / EXAMPLES / DESCRIPTION:
##----------------------------------------------------------------------------------------------------
## This script uses the Sendgrid V2 API to gather the count for the spam reports for the past one day
## https://sendgrid.com/docs/API_Reference/Web_API/spam_reports.html
## https://sendgrid.com/docs/Glossary/spam_reports.html
##
## CHANGE LOG:
##----------------------------------------------------------------------------------------------------
## [DATE]    [INITIALS]    [ACTION]
##

import urllib2
import json
from sys import exit
from BaseHTTPServer import BaseHTTPRequestHandler
import ConfigParser
from optparse import OptionParser
import datetime as dt
from datetime import date, timedelta

# Setting the dates as required by the Sendgrid API2
enddate = dt.datetime.today().strftime("%Y-%m-%d")
yesterday = date.today() - timedelta(1)
startdate = yesterday.strftime("%Y-%m-%d")

# Getting the argument
parser = OptionParser()
parser.add_option("-c", "--client", dest="client", help="clients e.g. vaya, eap, jira", metavar="CLIENTS")
(options, args) = parser.parse_args()
clientsection = options.client

# Reading the configuration file
config = ConfigParser.RawConfigParser()
config.read('/usr/local/nagios/etc/sendgrid_credentials.ini')
apiuser = config.get(clientsection, 'APIusername')
apikey = config.get(clientsection, 'APIpassword')

try:
    import urllib
    params = urllib.urlencode({'start_date': startdate, 'end_date': enddate, 'api_user': apiuser, 'api_key': apikey})
    f = urllib.urlopen("https://api.sendgrid.com/api/spamreports.count.json?%s" % params)
    response = f.read()
    json_data = json.loads(response)
    count_spams = int(json_data['count'])

    if count_spams >= 50:
        print "[CRITICAL] " + str(count_spams) + " spam reports since yesterday"
        exit(2)

    elif count_spams >= 10:
        print "[WARNING] " + str(count_spams) + " spam reports since yesterday"
        exit(1)

    else:
        print "[OK] " + str(count_spams) + " spam reports since yesterday"
        exit(0)

except urllib2.HTTPError as e:
    print "HTTP Error: " + str(e.code) + " " + str(BaseHTTPRequestHandler.responses[e.code][0])
    exit(2)
except urllib2.URLError as e:
    print "URL Error: " + str(e.reason)
    exit(2)
except KeyError as e:
    print "Key Error: " + str(e)
    exit(2)
except Exception:
    print "Unknown error."
    exit(2)