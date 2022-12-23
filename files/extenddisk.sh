#!/bin/bash

ls /sys/block/ | grep sd | while read sd ; do echo "1" > /sys/block/$sd/device/rescan ; done

LIST=$( pvs --noheadings -o pv_name | grep -v sda )

while IFS= read -r disk
do
  /sbin/pvresize $disk
done <<< "$LIST"

MOUNTS="/tmp/mounts.txt"

while IFS='|' read -r lname lsize
do
  if [[ "$( lsblk | grep $lname | grep ${lsize}G )" ]]; then
    echo "Nothing to do for ${lname}. Size is OK"
  elif [[ $lname == "block" ]]; then
    echo "Nothing to do for ${lname} device"
  else
    LVNAME=$(echo $lname | awk -F "/" '{print $NF}')
    _vg=$( ls /dev/mapper/ | grep $LVNAME | awk -F "-" '{print $1}' )
    lvextend -l+100%FREE /dev/$_vg/$LVNAME -r
  fi
done < "$MOUNTS"
