#!/bin/bash
#
# This script is meant for AWS EC2 instances (RHEL7 and CentOS7) to wipe out any
# existing Docker storage and recreate the necessary PVs, VG, and LV through
# devicemapper to use ephemeral and/or EBS storage. It then formats the resulting LV
# for ext4, and makes Docker use the LV. It can be run any number of times without
# negative effects.
#
# You need to run all this ephemeral setup stuff on every boot, not only on first
# boot of an ECS instance. User-data provided scripts are only executed on the
# first boot, so install this script as a service which starts before Docker.
#
# The flow of this script is as follows:
#
# 1. Disable Docker
# 2. Stop Docker
# 3. Unmount the Docker mount point
# 4. Unmount ephemeral drives
# 5. Sanitise block devices
# 6. Remove logical volumes ('dmsetup remove', 'vgremove', 'lvremove' and 'pvremove')
# 7. Prepare and (optionally) mount ('vgcreate', 'lvcreate', 'mkfs', and 'mount')
#
# There are several sleeps during each step because sometimes on slower EC2
# instances it takes a couple of seconds for changes to become active and visible.
#
# Usage
# This will recreate the storage and not mount:
# sudo ./recreate-docker-storage-ec2.sh
#
# This will recreate the storage and mount:
# sudo ./recreate-docker-storage-ec2.sh mount

readonly docker_mount="/var/lib/docker"
readonly fstab="/etc/fstab"
export mountyesno=0
export mountdocker="/usr/local/bin/mount-docker.sh"

sleep5() {
  echo -n "$0: sleeping for 5 seconds: "
  for ((i=0; i < 5; i++)); do
    echo -n "."
    sleep 1
  done
  echo
}

unmount_ephs() {
  local ephemeral="/media/ephemeral"
  echo "$0 ${FUNCNAME[0]}(): removing mounts for ephemeral storage '${ephemeral}' in '${fstab}':" >&2
  sed -i -e "\@${ephemeral}@d" "${fstab}"

  echo "$0 ${FUNCNAME[0]}(): trying to unmount ephemeral mounts. Some may fail to unmount, please ignore this..." >&2
  EPHEMERAL_MOUNTS=$(mount | grep ${ephemeral} | awk '{ print $3 }')
  for i in ${EPHEMERAL_MOUNTS}; do
    mount | grep -qw "${i}" || \
      continue
    echo "$0 ${FUNCNAME[0]}(): unmount -f ${i}" >&2
    umount -f "${i}"
    if [ $? -ne 0 ]; then
      echo "$0 ${FUNCNAME[0]}(): cannot umount '${i}'"
    fi
  done
}

# We need to filter as these are the ones that we have attached on boot - so
# any extra EBS volumes we attach later are not wiped out!
filter_block_devs() {
  local DEVS=" "
  for device in "$@"; do
    DEV="$(curl -sS http://169.254.169.254/latest/meta-data/block-device-mapping/${device})"

    # AWS reports some devices as sdX devices and some as xvdX devices.
    # docker-storage-setup uses /proc/partitions to query disk size, but this
    # proc file only reports with the xvdX name. We change sdX to xvdX here now
    DEV=$(echo "${DEV}" | sed 's/^sd\([a-z]\)/xvd\1/g')
    echo "$0 ${FUNCNAME[0]}(): '${device}' DEV FOUND: '${DEV}'" >&2

    if [[ "${DEV}" == "xvdcz" || "${DEV}" == "xvdd" || "${DEV}" == "xvde" ]]; then
      echo "$0 ${FUNCNAME[0]}(): '${device}' DEV FOUND: '${DEV}', BUT SKIPPING" >&2
      continue
    fi

    DEVS="${DEVS}/dev/${DEV} "
  done

  if [ "${DEVS}" == " " ]; then
    DEVS=""
  fi

  echo ${DEVS}
}

sanitise_blockdevices() {
  echo "$0 ${FUNCNAME[0]}(): unmounting and removing block devices from '${fstab}'" >&2
  for device in "$@"; do
    mount | grep -qw "${device}"
    if [ $? -eq 0 ]; then
      echo "$0 ${FUNCNAME[0]}(): umount -f ${device}"
      umount -f "${device}"
      if [ $? -ne 0 ]; then
        echo "$0 ${FUNCNAME[0]}(): cannot umount '${device}'"
      fi
    fi

    sed -i -e "\@${device}@d" "${fstab}"
  done

  sleep5
} >&2

remove_docker_and_wipe_devices() {
  echo "$0 ${FUNCNAME[0]}(): wiping '${docker_mount}' and related" >&2

  mount | grep -q "${docker_mount}"
  if [ $? -eq 0 ]; then
    echo "$0 ${FUNCNAME[0]}(): umount -f ${docker_mount}"
    umount -f "${docker_mount}" || \
    if [ $? -ne 0 ]; then
      echo "$0 ${FUNCNAME[0]}(): cannot umount '${docker_mount}'"
    fi
  fi

  sleep5

  for dm in $(dmsetup ls | awk '/docker/ { print $1 }'); do
    echo "$0 ${FUNCNAME[0]}(): dmsetup remove '${dm}'"
    dmsetup remove "${dm}" >&2 || \
    if [ $? -ne 0 ]; then
      echo "$0 ${FUNCNAME[0]}(): dmsetup remove '${dm}' failed"
      exit 1
    fi
  done

  sleep5

  mount | grep -q "/dev/docker/docker"
  if [ $? -eq 0 ]; then
    echo "$0 ${FUNCNAME[0]}(): umount -f /dev/docker/docker"
    umount -f /dev/docker/docker
    if [ $? -ne 0 ]; then
      echo "$0 ${FUNCNAME[0]}(): cannot umount '/dev/docker/docker'"
    fi
  fi

  echo "$0 ${FUNCNAME[0]}(): rm -rf /dev/docker/docker /dev/docker ${docker_mount}"
  rm -rf /dev/docker/docker /dev/docker "${docker_mount}"

  echo "$0 ${FUNCNAME[0]}(): disabling and removing docker volume group..." >&2
  for device in "$@"; do
    [ -e "${device}" ] || \
      continue

    vg="$(pvs ${device} --noheadings -o vg_name | sed -e 's/^[ ]*//')"
    if [[ "${vg}" ]]; then
      echo "$0 ${FUNCNAME[0]}(): vgchange -a n '${vg}'"
      vgchange -a n "${vg}"
      if [ $? -ne 0 ]; then
        echo "$0 ${FUNCNAME[0]}(): vgchange -a n '${vg}' failed"
        exit 1
      fi

      sleep5

      echo "$0 ${FUNCNAME[0]}(): vgremove -f '${vg}'"
      vgremove -f "${vg}"
      if [ $? -ne 0 ]; then
        echo "$0 ${FUNCNAME[0]}(): vgremove -f '${vg}' failed"
        exit 1
      fi
    fi
  done

  for lvm in $(lvs --noheadings -o lv_name | grep -i docker | sed -e 's/^[ ]*//'); do
    echo "$0 ${FUNCNAME[0]}(): lvremove -f ${lvm}"
    lvremove -f "${lvm}"
    if [ $? -ne 0 ]; then
      echo "$0 ${FUNCNAME[0]}(): lvremove -a n '${lvm}' failed"
      exit 1
    fi
  done

  vgdisplay | grep -qw docker
  if [ $? -eq 0 ]; then
    echo "$0 ${FUNCNAME[0]}(): vgchange -a n docker"
    vgchange -a n docker
    if [ $? -ne 0 ]; then
      echo "$0 ${FUNCNAME[0]}(): vgchange -a n 'docker' failed"
      exit 1
    fi

    echo "$0 ${FUNCNAME[0]}(): vgremove docker -f"
    vgremove docker -f
    if [ $? -ne 0 ]; then
      echo "$0 ${FUNCNAME[0]}(): vgremove 'docker' -f failed"
      exit 1
    fi
  fi

  echo "$0 ${FUNCNAME[0]}(): wiping partition tables..." >&2
  for device in "$@"; do
    mount | grep -qw "${device}"
    if [ $? -eq 0 ]; then
      umount -f "${device}"
      if [ $? -ne 0 ]; then
        echo "$0 ${FUNCNAME[0]}(): cannot umount '${device}'"
      fi
    fi

    echo "$0 ${FUNCNAME[0]}(): pvremove --force '${device}'"
    yes | pvremove --force ${device}
    if [ $? -ne	0 ]; then
      echo "$0 ${FUNCNAME[0]}(): pvremove --force '${device}' failed"
      exit 1
    fi

    dd if=/dev/zero of=${device} count=1
     echo "$0 ${FUNCNAME[0]}(): mkfs -t ext4 -q '${device}'"
    yes | mkfs -t ext4 -q "${device}"
    if [ $? -ne	0 ]; then
      echo "$0 ${FUNCNAME[0]}(): mkfs -t ext4 -q '${device}' failed"
      exit 1
    fi

    echo "$0 ${FUNCNAME[0]}(): sfdisk -R '${device}'"
    sfdisk -R "${device}"
    if [ $? -ne	0 ]; then
      echo "$0 ${FUNCNAME[0]}(): sfdisk -R '${device}' failed"
      exit 1
    fi

    sleep5
    echo "$0 ${FUNCNAME[0]}(): pvcreate '${device}'"
    yes | pvcreate ${device}
    if [ $? -ne	0 ]; then
      echo "$0 ${FUNCNAME[0]}(): pvcreate '${device}' failed"
      exit 1
    fi
  done
} >&2

gather_devices() {
  BLOCK_DEVS_QUERY="curl -sS http://169.254.169.254/latest/meta-data/block-device-mapping/"
  EPHEMERAL_BLOCK_DEVS=$(${BLOCK_DEVS_QUERY} | grep ephemeral | tr '\n' ' ')
  ELASTIC_BLOCK_DEVS=$(${BLOCK_DEVS_QUERY} | grep ebs | tr '\n' ' ')

  [[ "${EPHEMERAL_BLOCK_DEVS}" ]] && \
    echo "EPH BLOCK DEVS = [${EPHEMERAL_BLOCK_DEVS}]" >&2

  [[ "${ELASTIC_BLOCK_DEVS}" ]] && \
    echo "ELASTIC BLOCK DEVS = [${ELASTIC_BLOCK_DEVS}]" >&2

  echo "$0 ${FUNCNAME[0]}(): gathering information about attached storage devices..." >&2
  EPHEMERAL_DEVS=$(filter_block_devs ${EPHEMERAL_BLOCK_DEVS})
  ELASTIC_DEVS=$(filter_block_devs ${ELASTIC_BLOCK_DEVS})

  [[ "${EPHEMERAL_DEVS}" ]] && \
    echo "EPH DEVS = [${EPHEMERAL_DEVS}]" >&2

  [[ "${ELASTIC_DEVS}" ]] && \
    echo "ELASTIC DEVS = [${ELASTIC_DEVS}]" >&2

  if [ "$EPHEMERAL_DEVS" = "" ] && [ "$ELASTIC_DEVS" = "" ]; then
    echo "$0 ${FUNCNAME[0]}(): you don't have any instance/ephemeral storage set up. Please make sure you do this while creating the EC2 instance! Exiting now." >&2 | logger -s
    exit 1
  fi

  DEVS=""
  if [ "$EPHEMERAL_DEVS" = "" ]; then
    echo "$0 ${FUNCNAME[0]}(): no instance/ephemeral storage but EBS volumes found: going to use EBS volumes." >&2
    DEVS=${ELASTIC_DEVS}
  else
    echo "$0 ${FUNCNAME[0]}(): instance/ephemeral storage found: going to use them." >&2
    DEVS=${EPHEMERAL_DEVS}
  fi

  echo "$0 ${FUNCNAME[0]}(): we found these devices: '${DEVS}'" >&2
  echo ${DEVS}
}

prepare_docker() {
  pool="pool"
  name="docker"
  dev="/dev/${pool}/${name}"

  echo "$0 ${FUNCNAME[0]}(): removing '${docker_mount}' from '${fstab}'"
  sed -i -e "\@${docker_mount}@d" "${fstab}"

  echo "$0 ${FUNCNAME[0]}(): vgcreate '${pool}' '$@'"
  yes | vgcreate ${pool} $@
  if [ $? -ne 0 ]; then
    echo "$0 ${FUNCNAME[0]}(): vgcreate '${pool}' failed"
    exit 1
  fi

  echo "$0 ${FUNCNAME[0]}(): lvcreate --wipesignatures y -l +100%FREE -T -n '${name}' '${pool}'"
  lvcreate --wipesignatures y -l +100%FREE -T -n "${name}" "${pool}"
  if [ $? -ne 0 ]; then
    echo "$0 ${FUNCNAME[0]}(): lvcreate '${name}' '${pool}' failed"
    exit 1
  fi

  echo "$0 ${FUNCNAME[0]}(): mkfs -t ext4 -N 10000000 '${dev}'"
  mkfs -t ext4 -N 10000000 "${dev}"
  if [ $? -ne 0 ]; then
    echo "$0 ${FUNCNAME[0]}(): mkfs -t ext4 -N 10000000 '${dev}' failed"
    exit 1
  fi

  [ ! -d "${docker_mount}" ] && \
    mkdir -p "${docker_mount}"

  # Add 'noauto' to the Docker entry in /etc/fstab to disable systemd from automatically mounting the entry.
  echo "${dev} ${docker_mount} ext4 defaults,noatime,nobarrier,nofail,noauto 0 2" >> "${fstab}"

  if [ "${mountyesno}" -eq 1 ]; then
    echo "$0 ${FUNCNAME[0]}(): mount '${dev}' '${docker_mount}'"
    "${mountdocker}"
    if [ $? -ne 0 ]; then
      echo "$0 ${FUNCNAME[0]}(): '${mountdocker}' failed"
      exit 1
    fi
  fi
} >&2

main() {
  if [ "${EUID}" -ne 0 ]; then
    echo "$0 ${FUNCNAME[0]}(): need root"
    exit 1
  fi

  if [ -z "$1" ]; then
    echo "$0 ${FUNCNAME[0]}(): will mount after setup"
    mountyesno=1
  fi

  if [ ! -x "${mountdocker}" ]; then
	echo "$0 ${FUNCNAME[0]}(): cannot find '${mountdocker}' (hint: run 'install.sh')"
	exit 1
  fi

  rpm -qi lvm2 >/dev/null
  if [ $? -ne 0 ]; then
    echo "$0 ${FUNCNAME[0]}(): lvm2-2 rpm not installed, installing now:"
    yum install -y lvm2 || \
	exit 1
  fi

  systemctl disable docker >/dev/null 2>&1

  echo "$0 ${FUNCNAME[0]}(): systemctl status docker"
  systemctl status docker >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo "$0 ${FUNCNAME[0]}(): docker is still active, stopping:"
    systemctl stop docker

    systemctl status docker >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "$0 ${FUNCNAME[0]}(): docker is STILL active, force killing"

      systemctl stop docker || \
        exit 1
    fi
  fi

  mount | grep -q "${docker_mount}"
  if [ $? -eq 0 ]; then
    umount -f "${docker_mount}"
    if [ $? -ne 0 ]; then
      echo "$0 ${FUNCNAME[0]}(): cannot umount '${docker_mount}'"
    fi
  fi

  echo "$0 ${FUNCNAME[0]}(): recreate-docker-storage() unmounting ephemeral drives..."
  unmount_ephs

  sleep5
  echo "$0 ${FUNCNAME[0]}(): recreate-docker-storage() gathering block devices:"
  gather_devices
  DEVS=$(gather_devices)
  echo "$0 ${FUNCNAME[0]}(): recreate-docker-storage() sanitising block devices..."
  sanitise_blockdevices ${DEVS}

  sleep5
  echo "$0 ${FUNCNAME[0]}(): recreate-docker-storage() removing docker storage..."
  remove_docker_and_wipe_devices ${DEVS}

  sleep5
  echo "$0 ${FUNCNAME[0]}(): recreate-docker-storage() preparing docker storage"
  prepare_docker ${DEVS}

  echo "$0 ${FUNCNAME[0]}(): finished"
}

main

exit 0
