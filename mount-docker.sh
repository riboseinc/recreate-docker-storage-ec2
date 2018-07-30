#!/bin/bash
#
# mount-docker.sh by <ebo@>
#
# This script mounts the Docker disk.
#
# The recreate-docker-storage-ec2.sh script adds the Docker disk and mountpoint to /etc/fstab.
# This script looks in /etc/fstab and uses that info to perform the mount.

set -uo pipefail

readonly __progname="$(basename "$0")"

errx() {
	echo -e "${__progname}: $*" >&2

	exit 1
}

main() {
	[ "${EUID}" -ne 0 ] && \
		errx "need root"

	local -r fstab="/etc/fstab"
	[ ! -f "${fstab}" ] && \
		errx "cannot open '${fstab}'"

	grep -q docker "${fstab}" || \
		errx "there is no docker mountpoint present in '${fstab}'"

	local -r mountpoint="$(awk '/docker/ { print $2 }' "${fstab}")"
	local -r device="$(awk '/docker/ { print $1 }' "${fstab}")"

	# check if the disk already mounted
	# we perform two checks:
	# 1) see if the mountpoint is present in the output of lsblk
	# 2) see if the mountpoint is present in the output of df
	#    and verify if the disk (/dev/mapper/xxx) is the actual
	#    disk that is configured in /etc/fstab (/dev/pool/xxxx)

	lsblk | grep -q "${mountpoint}" && \
		return 0

	local -r lv="$(lvdisplay "${device}" | awk '/LV Name/ { print $3 }')"
	local -r vg="$(lvdisplay "${device}" | awk '/VG Name/ { print $3 }')"

	[[ -z "${lv}" ]] && \
		errx "device '${device}' is not part of any logical volume"

	[[ -z "${vg}" ]] && \
		errx "device '${device}' is not part of any volume group"

	df -h | grep "/dev/${vg}/${lv}" | grep -q "${mountpoint}" && \
		return 0

	echo "${__progname}: mount '${device}' '${mountpoint}'"
	mount "${device}" "${mountpoint}" || \
		errx "mount failed"

	return 0
}

main

exit $?
