#!/usr/bin/python
import MySQLdb
import ConfigParser
from datetime import datetime


def main():
    office_hours_start = '0800'
    office_hours_end = '1800'
    time_now = datetime.now().strftime('%H%M')


    config = ConfigParser.ConfigParser()
    config.readfp(FakeGlobalSectionHead(open('/usr/local/nagios/etc/VA_databases.ini')))

    user = config.get('generic', 'user')
    password = config.get('generic', 'password')
    host = config.get('vaya-replica002_3306', 'ip')
    port = config.getint('vaya-replica002_3306', 'port')

    db = MySQLdb.connect(host=host,
                         user=user,
                         passwd=password,
                         port=port,
                         db="vaya")

    cursor = db.cursor()
    cursor.execute("SELECT count(*) FROM `bill_log` WHERE `importerror` LIKE 'Logistics CSV Completed' AND logtime >= date(now()) AND logtime < date(now() + interval 1
day)")

    result = cursor.fetchall()[0][0]

    if result == 1:
    #    if int(office_hours_start) < int(time_now) < int(office_hours_end):
    #        exit_msg(2, result)
    #    else:
    #        exit_msg(1, result)
         exit_msg(0, result)
    elif result > 1:
        exit_msg(2, result)
    else:
        exit_msg(2, result)


def exit_msg(code, val):
    print str(val) + " record(s)| records=" + str(val)
    exit(code)


class FakeGlobalSectionHead(object):
    def __init__(self, fp):
        self.fp = fp
        self.sechead = '[global]\n'

    def readline(self):
        if self.sechead:
            try:
                return self.sechead
            finally:
                self.sechead = None
        else:
            return self.fp.readline()

if __name__ == "__main__":
    main()
