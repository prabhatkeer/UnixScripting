#!/bin/sh

#this script needs to be modified:
#                                 configuration should be placed in the config ini file
#                                 put_owi_to_ftp()  - script is sending all the *.tar.gz files to remote location, this seems to be incorrect
#                                 clean_owi_on_ftp() - we want to avoid using another communication channel, myaybe beter will be use perl with the  Net::FTP lib
#                                 All functions - configuration parameters inside the functions cannot be accepted
#                                 Documentation link should be placed

ftpHost="eap-ftp01"
ftpUser="moosemobile"
ftpKey="~/.ssh/id_rsa_mule" #Key authentication not implemented
ftpPass="2ekPNaC94" #Ask Michal Kopacki to create user and password

ftpHome="/data/ftp/moosemobile"

#put_owi_to_ftp() {
#  local remote_folder=optus
#  local local_folder=/shared/application_data/owi_036

#  if lftp -e "set ftp:passive-mode false; set ssl:verify-certificate no; lcd $local_folder; cd $remote_folder; mput *.tar.gz; bye" -u $ftpUser,$ftpPass $ftpHost; then
#    logger -p local6.notice -s -t $(basename $0) "[OK] Owi files for moosemobile uploaded to ftp server"
#  else
#    logger -p local6.notice -s -t $(basename $0) "[ERROR] Owi files for moosemobile upload to ftp FAILED for some reason"
#  fi
#}

put_logistics_to_ftp() {
  remote_folder=logistics
  local_folder=/shared/application_data/data/logistics/moosemobile

  cd $local_folder
  for file in `ls *.csv`; do
    if lftp -e "set ftp:passive-mode false; set ssl:verify-certificate no; lcd $local_folder; cd $remote_folder; put $file; bye" -u $ftpUser,$ftpPass $ftpHost; then
      logger -p local6.notice -s -t $(basename $0) "[OK] Logistics file $file for moosemobile uploaded to ftp server";
      mv $file processed/
    else
      logger -p local6.notice -s -t $(basename $0) "[ERROR] Logistics file $file for moosemobile upload to ftp FAILED for some reason";
    fi
  done;
}

get_files_from_ftp() {
  remote_folder=logistics/shipped
  local_folder=/shared/application_data/data/logistics/moosemobile/shipped

  if lftp -e "set ftp:passive-mode false; set ssl:verify-certificate no; set xfer:clobber on; lcd $local_folder; cd $remote_folder; mget *.csv; renlist > downloaded_list.lst; put -c -E downloaded_list.lst; bye" -u $ftpUser,$ftpPass $ftpHost; then
    logger -p local6.notice -s -t $(basename $0) "[OK] Files shipped by customer for moosemobile downloaded from ftp server"
  else
    logger -p local6.notice -s -t $(basename $0) "[ERROR] Files shipped by customer for moosemobile download from ftp FAILED for some reason"
  fi
}

usage() {
  cat <<EOF
 usage:
     $1 --put_owi | --put_logistics | --get_shipped | --put_cdrs | --put_murs
         [-h|--help]

 Args:
   --put_owi            sends owi files for ACQUIREBPO to theirs FTP (on eap-ftp01) / works also from cron every hour
   --put_logistics      sends logistics files for ACQUIREBPO to theirs FTP (on eap-ftp01) / works also from cron every hour
   --get_shipped        downloads all data from ACQUIREBPO (on eap-ftp01)  /  works also from cron every 10 minutes
   --put_cdrs   relocate CDRS
   --put_murs   relocate MURS
   -h,--help            print this help
EOF
 return 0
}

 options=$(getopt -o hols -l help,put_owi,put_logistics,get_shipped,put_cdrs,put_murs -- "$@")

 if [ -z $1 ]; then
   usage $(basename $0)
   exit 1
 fi

 eval set -- "$options"

 while true
 do
     case "$1" in
     -h|--help)      usage $0 && exit 0;;
     --put_owi)      put_owi_to_ftp; break;;
     --put_logistics)      put_logistics_to_ftp; break;;
     --get_shipped)  get_files_from_ftp; break;;
     --put_cdrs)
         mv /shared/application_data/owi_084/RESELL*.zip /shared/application_data/moosemobile/cdr_unprocessed
         break;;
     --put_murs)
         mv /shared/application_data/owi_084/RESELL_MUR* /shared/application_data/moosemobile/unprocessed
         break;;
     *)              usage $(basename 0); exit 1; break;;
     esac
 done