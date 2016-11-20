#!/bin/bash
# Daily rbd differential backup via snapshot in the "ceph" pool
#
#
# Usage: ceph_backup.sh <NFS_DIR>

convertsecs() {
 ((h=${1}/3600))
 ((m=(${1}%3600)/60))
 ((s=${1}%60))
 printf "%02d:%02d:%02d\n" $h $m $s
}

LOG_FILE=/var/log/ceph_backup.log
SOURCEPOOL="ceph"


NFS_DIR="$1"
BACKUP_DIR="$NFS_DIR/ceph_backups"
CONFIG_DIR="$NFS_DIR/vm_configs"

PIDFILE=/var/run/ceph_backup.pid
if [[ -e "$PIDFILE" ]]; then
    PID=$(cat ${PIDFILE})
    ps -p $PID > /dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Process already running with pid ${PID}" >>$LOG_FILE
      exit 1
    else
      ## Process not found assume not running
      echo $$ > $PIDFILE
      if [ $? -ne 0 ]; then
        echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Could not create PID file $PIFDILE" >>$LOG_FILE
        exit 1
      fi
    fi
  else
    echo $$ > $PIDFILE
  if [ $? -ne 0 ]; then
    echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Could not create PID file $PIFDILE" >>$LOG_FILE
    exit 1
  fi
fi



if [[ -z "$NFS_DIR" ]]; then
    echo "Usage: ceph_backup.sh <NFS_DIR>"
    exit 1
fi


SNAPBACKUP=false
START=$(date +%s)
SAT_BACKUP=false

if [[ $(date '+%a') == "Sat"  ]]; then
 	SAT_BACKUP=true
fi
echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: backup started" >>$LOG_FILE

touch $LOG_FILE

#list all volumes in the pool
IMAGES=$(rbd ls $SOURCEPOOL)
#IMAGES="vm-105-disk-2"

#build inactive images list - images that are unused or backup=0
echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Building inactive image list" >>$LOG_FILE

declare -A isinactive

#For each node on the ProxMox cluster
for node in $(pvecm nodes | grep pve | awk '{print $3}' | awk -F. '{print $1}')
do
 	#Get list of all inactive disks from conf files
 	echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: getting node:${node} inactive image list" >>$LOG_FILE
 	while read image; do
              isinactive[$image]=1
	done < <(ssh root@${node} "grep \"\-disk-\" /etc/pve/qemu-server/*" | grep ceph | awk -F "\"*:\"*" '{print $2 ":" $4}' | grep "unused\|backup=0" | awk -F "\"*:\"*" '{print $2}' | awk -F "\"*,\"*" '{print $1}')
done

for LOCAL_IMAGE in $IMAGES; do

    #Check if image is in inactive images array
    if [[ ${isinactive[$LOCAL_IMAGE]-X} == "${isinactive[$LOCAL_IMAGE]}" ]]; then

 	   	#if the image was found to be unused or backup=0 skip it and move on to the next image
 	  	echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: ${LOCAL_IMAGE} found on inactive image list" >>$LOG_FILE
 	  	continue

    fi

    TODAY=$(date '+%m-%d-%Y-%H-%M-%S')
    echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Beginning backup for ${LOCAL_IMAGE}" >>$LOG_FILE
    LOCAL_START=$(date +%s)

    #Get newest snapshot for image
    LATEST_SNAP=$(rbd snap ls "${SOURCEPOOL}/${LOCAL_IMAGE}" | grep -v "SNAPID" |sort -r | head -n 1 |awk '{print $2}')

    IMAGE_DIR="${BACKUP_DIR}/${LOCAL_IMAGE}"
    if [[ ! -e "$IMAGE_DIR" ]]; then
 	   	echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: First run for ceph volume. Making backup directory $IMAGE_DIR" >>$LOG_FILE
        mkdir -p "$IMAGE_DIR"
    fi

    #Every Saturday grab a new snapshot and cleanup old backups
    if [[ "$SAT_BACKUP" == true  ]]; then
        echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Creating weekly snap for $SOURCEPOOL/$LOCAL_IMAGE to backup" >>$LOG_FILE
 	   	echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: rbd snap create ${SOURCEPOOL}/${LOCAL_IMAGE}@${TODAY}" >>$LOG_FILE
 	   	rbd snap create "${SOURCEPOOL}"/"${LOCAL_IMAGE}"@"${TODAY}"  >>$LOG_FILE 2>&1
 	   	echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: rbd snap protect ${SOURCEPOOL}/${LOCAL_IMAGE}@${TODAY}" >>$LOG_FILE
 	   	rbd snap protect "${SOURCEPOOL}"/"${LOCAL_IMAGE}"@"${TODAY}"  >>$LOG_FILE 2>&1
 	   	SNAPBACKUP=true
 	   	LATEST_SNAP=$(rbd snap ls "${SOURCEPOOL}"/"${LOCAL_IMAGE}" | grep -v "SNAPID" | sort -r | head -n 1 |awk '{print $2}')
 	   	OLDEST_SNAP=$(rbd snap ls "${SOURCEPOOL}"/"${LOCAL_IMAGE}" | grep -v "SNAPID" | sort | head -n 1 |awk '{print $2}')

 	   	#Cleanup backups retaining 3 full snaps and diffs in between from file system and remove old snaps from ceph
 	   	echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Cleanup old image backups" >>$LOG_FILE
 	   	REFERENCEIMG=$(find "${IMAGE_DIR}" -name *.img -type f -printf '%T+ %f\n' | sort -r | awk '{print $2}'| sed '3q;d')
 	   	#if we find files old enough to delete
 	   	if [[ $REFERENCEIMG ]]; then
        	find "${IMAGE_DIR}" -type f ! -newer "${IMAGE_DIR}"/"${REFERENCEIMG}" ! -name "${REFERENCEIMG}" -delete
 	   	fi
 	   	echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: rbd snap unprotect ${SOURCEPOOL}/${LOCAL_IMAGE}@${OLDEST_SNAP}" >>$LOG_FILE
 	   	rbd snap unprotect "${SOURCEPOOL}"/"${LOCAL_IMAGE}"@"${OLDEST_SNAP}"
        echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: rbd snap rm ${SOURCEPOOL}/${LOCAL_IMAGE}@${OLDEST_SNAP}" >>$LOG_FILE
 	   	rbd snap rm "${SOURCEPOOL}"/"${LOCAL_IMAGE}"@"${OLDEST_SNAP}" >>$LOG_FILE
        echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Cleanup finished" >>$LOG_FILE
    fi

    #check if there is a snapshot to backup
    if [[ -z "$LATEST_SNAP" ]]; then
       	echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: no snap for $SOURCEPOOL/$LOCAL_IMAGE to backup" >>$LOG_FILE
 	   	echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: rbd snap create ${SOURCEPOOL}/${LOCAL_IMAGE}@${TODAY}" >>$LOG_FILE
 	   	rbd snap create "${SOURCEPOOL}/${LOCAL_IMAGE}@${TODAY}"  >>$LOG_FILE 2>&1
 	   	echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: rbd snap protect ${SOURCEPOOL}/${LOCAL_IMAGE}@${TODAY}" >>$LOG_FILE
 	   	rbd snap protect "${SOURCEPOOL}/${LOCAL_IMAGE}@${TODAY}"
 	   	SNAPBACKUP=true
 	   	LATEST_SNAP=$(rbd snap ls "${SOURCEPOOL}/${LOCAL_IMAGE}" | grep -v "SNAPID" | sort -r | head -n 1 | awk '{print $2}')
    fi

    if [[ "$SNAPBACKUP" == true ]]; then
       # full export the image
       echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: rbd export --rbd-concurrent-management-ops 20 ${SOURCEPOOL}/${LOCAL_IMAGE}@${LATEST_SNAP} ${IMAGE_DIR}/${LATEST_SNAP}.img" >>$LOG_FILE
       rbd export --rbd-concurrent-management-ops 20 "${SOURCEPOOL}/${LOCAL_IMAGE}@${LATEST_SNAP}" "${IMAGE_DIR}/${LATEST_SNAP}".img  >>$LOG_FILE 2>&1

       LOCAL_END=$(date +%s)
       echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Finished backup for ${LOCAL_IMAGE} ($(convertsecs $(((LOCAL_END - LOCAL_START)))))" >>$LOG_FILE

       continue
    fi

    # export-diff the current from the weekly snapshot
    echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: rbd export-diff ${SOURCEPOOL}/${LOCAL_IMAGE} --from-snap ${LATEST_SNAP} ${IMAGE_DIR}/${TODAY}.diff" >>$LOG_FILE
    rbd export-diff "${SOURCEPOOL}/${LOCAL_IMAGE}" --from-snap "${LATEST_SNAP}" "${IMAGE_DIR}/${TODAY}".diff  >>$LOG_FILE 2>&1

    LOCAL_END=$(date +%s)
    echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Finished backup for ${LOCAL_IMAGE} ($(convertsecs $(((LOCAL_END - LOCAL_START)))))" >>$LOG_FILE

done

echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Copying ProxMox VM/CT config files" >>$LOG_FILE 2>&1
#For eachnode in the ProxMox cluster
for node in $(pvecm nodes | grep pve | awk '{print $3}' | awk -F. '{print $1}')
do
 		#Get list of conf files on each node
        for filename in $(ssh root@"${node}" ls /etc/pve/qemu-server)
        do
               	TODAY=$(date '+%m-%d-%Y-%H-%M-%S')
        		VM_DIR="${filename%.*}"
        		#if vm_dir doesn't exist, create it
        		if [ ! -d "${CONFIG_DIR}/${VM_DIR}" ]; then
              	  	echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: creating vm config directory ${CONFIG_DIR}/${VM_DIR}" >>$LOG_FILE
              	  	mkdir "${CONFIG_DIR}/${VM_DIR}"
        		fi
        		#Copy each conf file to backup server
                scp root@"${node}":/etc/pve/qemu-server/"$filename" "${CONFIG_DIR}/${VM_DIR}/$filename-${TODAY}" >>$LOG_FILE

        		echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Cleanup old vm config backups" >>$LOG_FILE
         	   	REFERENCECONF="$(find "${CONFIG_DIR}/${VM_DIR}" -type f -printf '%T+ %f\n' | sort -r | awk '{print $2}'| sed '14q;d')"
              	#if we find files old enough to delete
              	if [[ -n "$REFERENCECONF" ]]; then
                        find "${CONFIG_DIR}/${VM_DIR}" -type f ! -newer "${CONFIG_DIR}/${VM_DIR}/${REFERENCECONF}" ! -name "${REFERENCECONF}" -delete >>$LOG_FILE
              	fi
        		echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Finished cleanup of old vm config backups" >>$LOG_FILE

        done
done
echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: ProxMox VM/CT config files copied" >>$LOG_FILE 2>&1

END=$(date +%s)

echo "[$(date '+%m/%d/%Y:%H:%M:%S')] ceph_backup: Overall backup completed and took $(convertsecs $(((END - START))))" >>$LOG_FILE

rm $PIDFILE

