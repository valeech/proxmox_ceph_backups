# proxmox_ceph_backups.sh
BASH script to backup ceph images to NFS mount in ProxMox 4.x environment

ProxMox v4.x using a ceph storage cluster is slow to backup disk images due to a compatibility issue between ceph and qemu. Additionally, the ProxMox vzdump utility does not offer a differential backup capability, only full backups.

The ceph_backup.sh script will provide a differential backup capability that utilizes ceph export. This is a much faster backup method. On Saturday it will take a full export of the disk images in your ceph cluster. Every other day of the week it will take a differential snapshot based on the last Saturday's full image.

The script performs cleanup keeping only the last 14 days workth of backups. It does this not by date of the backups but rather by number of backups. This way if your backup job does not complete for a few days, you don't delete good backup jobs that could be useful. 

The script also captures the VM conf files from the /etc/pve/qemu-server directory nightly to ensure there is a good copy if needed.

The ceph_restore.sh script will walk a user through restoring a backup image or differential back into the ceph cluster using a menu based system.

