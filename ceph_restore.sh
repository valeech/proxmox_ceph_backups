#!/bin/bash

BACKUPPATH="/mnt/pve/pve-backup1/ceph_backups"
CEPHPOOL="ceph"

NUMVOLS=$(ls -l ${BACKUPPATH} | egrep '^d' | wc -l)

read -ra array <<<$(ls -l /mnt/pve/pve-backup1/ceph_backups | egrep '^d' | awk '{print $9}' | awk '!/^ / && NF {print $1; print $1}')
RESTOREVOL=$(whiptail --title "eResources Ceph Restore" --menu "Choose from available volumes: " --notags 25 60 14 "${array[@]}" 3>&1 1>&2 2>&3)

exitstatus=$?

case $exitstatus in
    1)
 exit -1
        ;;
    255)
        exit -1
        ;;
esac

    NUMIMGS="0"
    array=( `for file in $(ls ${BACKUPPATH}/${RESTOREVOL}/); do echo ${file##*/} ; done | awk '!/^ / && NF {print $1; print $1}'` )

    NUMIMGS=${#array[@]}

    if [[ "$NUMIMGS" -eq "0" ]]; then

        RESTOREIMG=$(whiptail --title "eResources Ceph Restore" --msgbox "There are no backups available for $RESTOREVOL" 8 60 3>&1 1>&2 2>&3)
 exit -1

    fi

    NUMIMGS=$(($NUMIMGS/2))
    RESTOREIMG=$(whiptail --title "eResources Ceph Restore" --menu "Choose from available backups: " --notags 25 60 14 ${array[@]} 3>&1 1>&2 2>&3
)

exitstatus=$?

case $exitstatus in
    1)
 exit -1
        ;;
    255)
        exit -1
        ;;
esac


if [[ "${RESTOREIMG##*.}" != "img"  && "${RESTOREIMG##*.}" != "diff" ]]
then
        whiptail --title "eResources Ceph Restore" --msgbox "${RESTOREIMG} is not in the proper format." 8 60 3>&1 1>&2 2>&3
 exit -1

elif [[ ${RESTOREIMG: -4} != ".img" ]]
then
 RESTOREDIFF=$RESTOREIMG
 RESTOREIMG=$(find ${BACKUPPATH}/${RESTOREVOL}/*.img -type f ! -newer ${BACKUPPATH}/${RESTOREVOL}/$RESTOREDIFF -printf '%f\n' | sort -r |
head -n 1)

        whiptail --title "eResources Ceph Restore" --yesno "In order to restore ${RESTOREDIFF}, ${RESTOREIMG} must also be restored. Proceed?" 860 3>&1 1>&2 2>&3

else
        whiptail --title "eResources Ceph Restore" --yesno "Are you sure you want to restore ${RESTOREIMG}?" 8 60 3>&1 1>&2 2>&3

fi

exitstatus=$?

case $exitstatus in
    0)
 #Proceed with restore
 while [ -z $RESTORETO ]
 do
        RESTORETO=$(whiptail --inputbox "Enter volume name to restore to:" 8 78 --title "eResources Ceph Restore" 3>&1 1>&2 2>&3)
 done
 ;;
    1)
 #Cancel
 exit -1
        ;;
    255)
        exit -1
        ;;
esac

exitstatus=$?
case $exitstatus in
    0)
 if [[ $(rbd ls -p $CEPHPOOL | grep "\<${RESTORETO}\>") ]]; then

        whiptail --title "eResources Ceph Restore" --msgbox "Image ${RESTORETO} already exists in pool ${CEPHPOOL}." 8 60 3>&1 1>&2 2>&3

 else

        if [ -z $RESTOREDIFF ]; then

              rbd import ${BACKUPPATH}/${RESTOREVOL}/${RESTOREIMG} ${CEPHPOOL}/${RESTORETO}

        else

              rbd import ${BACKUPPATH}/${RESTOREVOL}/${RESTOREIMG} ${CEPHPOOL}/${RESTORETO}
              rbd snap create ${CEPHPOOL}/${RESTORETO}@${RESTOREIMG%.*}
              rbd import-diff ${BACKUPPATH}/${RESTOREVOL}/${RESTOREDIFF} ${CEPHPOOL}/${RESTORETO}
              rbd snap rm ${CEPHPOOL}/${RESTORETO}@${RESTOREIMG%.*}
        fi



 fi
        ;;
    1)
        #Cancel
        exit -1
        ;;
    255)
        exit -1
        ;;
esac

