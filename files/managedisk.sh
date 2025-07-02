#!/bin/bash
#managedisk.sh
BUS=$1
UNIT=$2
LV_PATH=$3
LV_SIZE=$4

DEVICES=/sys/bus/pci/devices/*
DISK_PATH=/dev/disk/by-path/

ls /sys/class/scsi_host/ | while read host ; do echo "- - -" > /sys/class/scsi_host/$host/scan ; done

GREP_PCI=$( grep "SCSI${BUS}" ${DEVICES}/label | awk -F "/" '{print $6}' )
PCI_PATH="pci-${GREP_PCI}-scsi-0:0:${UNIT}:0"
GREP_DEV=$( ls -l $DISK_PATH | grep $PCI_PATH | awk -F "/" '{print $NF}' )

if [[ $LV_PATH == "block" ]]; then
  echo "No need LVM"
  exit 0
fi

if [[ ! "$( pvs | grep $GREP_DEV )" ]]; then
  pvcreate /dev/$GREP_DEV
fi

if [[ "$( vgdisplay -c | grep vg$BUS )" ]] && [[ "$( pvs /dev/$GREP_DEV | grep vg$BUS )" ]]; then
  echo "Nothing to do"
elif [[ "$( vgdisplay -c | grep vg$BUS )" ]]; then
  vgextend vg$BUS /dev/$GREP_DEV
else
  vgcreate vg$BUS /dev/$GREP_DEV
fi

((LV_SIZE-=4))
LV_NAME=$( echo $LV_PATH | awk -F "/" '{print $NF}' )

if [[ "$( lvdisplay -c | grep -w """$LV_NAME""" )" ]]; then
  lvextend -L+${LV_SIZE}M /dev/vg$BUS/$LV_NAME -r
else
  lvcreate -n $LV_NAME -L ${LV_SIZE}M vg$BUS
  mkfs.ext4 /dev/vg${BUS}/$LV_NAME
  mkdir -p /var$LV_PATH
  mount /dev/vg${BUS}/$LV_NAME /var$LV_PATH
  echo "/dev/vg${BUS}/$LV_NAME    /var$LV_PATH    ext4    defaults    0    1" | tee -a /etc/fstab
fi
