#!/bin/bash

ls /sys/block/ | grep sd | while read sd ; do echo "1" > /sys/block/$sd/device/rescan ; done

LIST=$( ls /dev/ | grep '^sd.$' | grep -v sda )

while IFS= read -r disk
do
  /sbin/pvresize /dev/$disk
done <<< "$LIST"

MOUNTS="/tmp/mounts.txt"

while IFS='|' read -r lname lsize
do
  if [[ "$( lsblk | grep $lname | grep ${lsize}G )" ]]; then
    echo "Nothing to do for ${lname}. Size is OK"
  else
    _vg=$( ls /dev/mapper/ | grep $lname | awk -F "-" '{print $1}' )
    lvextend -l+100%FREE /dev/$_vg/$lname -r
  fi
done < "$MOUNTS"
