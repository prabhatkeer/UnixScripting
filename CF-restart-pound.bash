#!/bin/bash

logfile="/data/coldfusion9/logs/cfserver.log"
search_text="Server coldfusion ready"
cf_bin="/etc/init.d/coldfusion_9"
http_bin="/etc/init.d/httpd"
restart_next=60
restart_count=0
cfmail_folder="/data/coldfusion9/Mail/Spool/"
cfmail_folder_tmp="/tmp/cfmail/"
cf_poir_ooxml_tmp="/tmp/poifiles"

process=$( ps -eo "%p|%a" | grep -v "grep" | grep -v "vi" | grep -v "sudo" | grep -c "CF-restart-pound.sh" )
if [ "$process" -gt 2 ]; then
        ps -eo "%p|%a" | grep -v "grep" | grep -v "vi" | grep "CF-restart-pound.sh"
        exit
fi

server=`uname -n`
arg1=$1;

if [[ "$1" != "NO_CHECK" ]]; then
##cross checking
    case $server in
        vaya-backend01)
            url1="http://10.11.1.31/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
            url2="http://10.11.1.159/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
            url3="http://10.11.1.160/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
        ;;
        vaya-backend02)
            url1="http://10.11.1.30/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
            url2="http://10.11.1.159/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
            url3="http://10.11.1.160/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
        ;;
        vaya-backend07)
            url1="http://10.11.1.31/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
            url2="http://10.11.1.30/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
            url3="http://10.11.1.160/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
        ;;
        vaya-backend08)
            url1="http://10.11.1.30/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
            url2="http://10.11.1.31/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
            url3="http://10.11.1.159/ecgateway/owi/webservices/ecgw_webservice.cfc?wsdl"
        ;;
        *)
            echo "I'm not designed to work with that server: $server"
            exit 1
        ;;
    esac

    echo "Check url 1: $url1"
    checkService1=`lynx --source $url1 | grep '<wsdl:operation name="doLogin"' | wc -l `;

    echo "Check url 2: $url2"
    checkService2=`lynx --source $url2 | grep '<wsdl:operation name="doLogin"' | wc -l `;

    echo "Check url 3: $url3"
    checkService3=`lynx --source $url3 | grep '<wsdl:operation name="doLogin"' | wc -l `;

    if [[ $checkService1 -gt 0 ]] && [[ $checkService2 -gt 0 ]] && [[ $checkService3 -gt 0 ]]; then
        echo "Service OK";
    else
        echo "Service on other host is not working, check $url and start restart script again or run
        $0 NO_CHECK to not check";
        exit 1
    fi
fi

echo "=== Stopping httpd"
$http_bin stop
sleep 10

echo "=== Stopping coldfusion"
/bin/mv "$cfmail_folder"* "$cfmail_folder_tmp"

echo "=== cleaning up poi-ooxml"
/bin/rm -fr $cf_poir_ooxml_tmp/*

$cf_bin restart
sleep 10
while [[ `tail -n 5 "$logfile" | grep "$search_text" | wc -l` -eq 0 ]]
    do
        echo "=== Coldfusion still not up, waiting 10 sec more... Try: $restart_count"
        /bin/mv "$cfmail_folder"* "$cfmail_folder_tmp"
        let "restart_count=$restart_count+1"
        if [[ $restart_count -gt $restart_next ]]; then
            $cf_bin restart
            restart_count=0
        fi
        sleep 10
    done

echo "=== Starting http"
$http_bin start
/bin/mv "$cfmail_folder_tmp"* "$cfmail_folder"
exit 0