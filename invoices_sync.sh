#!/bin/bash
# Syncing invoices from Sanity1(Old Vaya setup) across to Sanity2(New Vaya setup)

print_usage () {
   echo "[USAGE] $0 -p [vaya|lc] -f [sync|compare] -d [date in yyyy_mm_dd format]";
   echo "[Example: ] $0 -p vaya -f sync -d 2016_12_22 (**Optionali arg)";
   echo "[Example: ] $0 -p vaya -f s3upload -d 2016_12_22 (**Optionali arg)";
   echo "(*Ooptionali arg: If no date is provided then it takes yesterday's date)";
   exit 1;
}

if [ $# -eq 0 ]; then echo "No arguments supplied"; print_usage; fi


# Getting the right options
while getopts ":p:f:d:h" option
do
   case $option in
        p) SRV_PDR=${OPTARG};;
        d) INVDIR=${OPTARG};;
        f) FUNCT=${OPTARG};;
        h) print_usage ;;
        \?) echo "Invalid option: -$OPTARG"
            print_usage ;;
        :) echo "Option -$OPTARG requires an argument"
           print_usage ;;
   esac
done

# Setting variables and main function

check_func () {
 if [ "$FUNCT" == 'compare' ]; then comparedirs;
 elif [ "$FUNCT" == 'sync' ]; then startsync;
 elif [ "$FUNCT" == 's3upload' ]; then s3upload;
 else echo "[ERROR] Wrong function provided"; print_usage; fi
}

check_mount () {
 if [ ! -d /mnt/va-sa2-sharedfs/bills_vaya ]; then
      echo "Destination directory does is not mounted, trying now";
      /bin/mount 10.5.19.231:/mnt/shared /mnt/va-sa2-sharedfs/
 else
      fuser -c /mnt/va-sa2-sharedfs
      if [ $? = 1 ]; then
           /bin/mount -o remount,rw 10.5.19.231:/mnt/shared /mnt/va-sa2-sharedfs/
      fi
 fi
}

# Using rsync for copying over the invoices
startsync () {
 #check_mount;
 if [ ! -d "$SRD_DIR"/"$TIMESTP"/ ]; then
      echo "Yesterday's invoices directory '$TIMESTP' does not exist under $SRD_DIR. Investigate";
 else
    # Check if an rsync in already in progress
      if /sbin/pidof rsync; then
           echo "Some rsync processes already running";
           exit 1;
      else
           echo "Starting rsync of $SRD_DIR/$TIMESTP to $DST_DIR at $(date)"; echo "";
           START=$(date +%s);
           /usr/bin/ionice -c3 -n7 nice -n19 /usr/bin/rsync -av $SRD_DIR/$TIMESTP $DST_DIR
           echo ""; echo "Rsync finished at $(date)"
           END=$(date +%s);
           echo "It took about $(echo $((END-START)) | awk '{printf "%d:%02d:%02d", $1/3600, ($1/60)%60, $1%60}') minutes:seconds"
      fi
 fi
}

# Uploading to S3
s3upload () {
CURYEAR=$(date +%Y)
if [ "$SRV_PDR" == 'vaya' ]; then
   /usr/bin/s3cmd -q --no-check-md5 -c /scripts/s3-bill-sync-s3cmd.cfg sync /data/bills/bills_vaya/"$TIMESTP" s3://vaya-bills-archive/"$CURYEAR"/
elif [ "$SRV_PDR" == 'lc' ]; then
   /usr/bin/s3cmd -q --no-check-md5 -c /scripts/s3-bill-sync-s3cmd.cfg sync /data/bills/bills_lc/"$TIMESTP" s3://lc-bills-archive/"$CURYEAR"/
else
    echo "[ERROR] Wrong service provider stated."
    print_usage;
    exit 1;
fi
}

# Comparing the two directories
comparedirs () {
 #check_mount;
     FCNTATSRC=$(ls -laR "$SRD_DIR"/"$TIMESTP" | wc -l)
     FCNTATDST=$(ls -laR "$DST_DIR"/"$TIMESTP" | wc -l)
     if [ "$FCNTATSRC" == "$FCNTATDST" ]; then
          echo -n "File count at source matches at destination. Do you need to try a rsync --dry-run? [y|n] : "
          read reply;
          if [ $reply = y ]; then
               #/usr/bin/rsync --dry-run --size-only $SRD_DIR/$TIMESTP $DST_DIR/
                diff -r "$SRD_DIR"/"$TIMESTP" "$DST_DIR"/"$TIMESTP"
          fi
     else
      echo "File count is not equal. Need to investigate further or try syncing manually. At source: $FCNTATSRC, but at destination: $FCNTATDST files."
     fi
}

## -- Main --
if [ "$SRV_PDR" == 'vaya' ]; then
    SRD_DIR=/data/bills/bills_vaya
    DST_DIR=/mnt/va-sa2-sharedfs/bills_vaya/
     if [ ! -z $INVDIR ]; then
        TIMESTP=$INVDIR
     else
        TIMESTP=$(date +'%Y_%m_%d' -d '-1 day');
     fi
    check_func;
elif [ "$SRV_PDR" == 'lc' ]; then
    SRD_DIR=/data/bills/bills_lc
    DST_DIR=/mnt/va-sa2-sharedfs/bills_lc/
    #STRA=$(date +'%Y_%m');
    #STRB='_07';
     if [ ! -z $INVDIR ]; then
        TIMESTP=$INVDIR
     else
        TIMESTP=$(date +'%Y_%m_%d' -d '-1 day');
     fi
    check_func;
else
    echo "[ERROR] Wrong service provider stated."
    print_usage;
    exit 1;
fi

# Finishing up
#/bin/mount -o remount,ro 10.5.19.231:/mnt/shared /mnt/va-sa2-sharedfs/