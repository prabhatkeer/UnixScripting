#!/bin/bash
# 21-07-2016 Prabhat Keer < prabhat@ecconnect.com.au >
# Script for Prabhat's deploy script checks

function log {
        echo "[`date`] $1"
        echo -e "$1\n$2" > /var/tmp/jeenee_gw_deploy.log
        exit $2
}
log "--------------------------------------------------------" 1

backup () {
if [ ! -d /home/jeenee/www/secure ]; then
   log "Missing /home/jeenee/www/secure dir, not deploying, exiting" 2
else
   tar -czf ecgateway.`date +%Y%m%d`.tar.gz  ecgateway
   log "Existing code is backed up in ecgateway.`date +%Y%m%d`.tar.gz in `pwd`" 1
fi
}

## Deploying
        backup;
        cd ecgateway;
        log "Deploying in `pwd`: " 1
        #git pull &> /var/tmp/temp_output || { log "Git pull has failed. Please investigate" 2; }
        /bin/cat /var/tmp/temp_output;
log "-------------------------COMPLETE-----------------------" 1

/bin/rm -f /var/tmp/temp_output
