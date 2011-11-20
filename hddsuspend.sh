#!/bin/sh
####
# Copyright (C) 2011 by Jakob Westhoff <jakob@westhoffswelt.de>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
####
#
#/ HDDSuspend 0.1 (c) Jakob Westhoff
#/ Usage: hddsuspend [option [...]] <device> [...]
#/
#/ Options:
#/   --timeout: The amount of time a hdd may be inactive in order to be send to
#/              sleep. The value in provided in minutes. (Default: 30)
#/
#/   --storage: Directory to be used for storing different information to
#/              transported from each run to another. (Default:
#/              /var/run/hddsuspend)
#/
#/   --diskstats: File to be used to retrieve diskstats information at regular
#/                intervals (Default: /proc/diskstats)
#/
#/ This utillity should be called by cron once every minute to ensure a usable
#/ resolution of inactivity information
set -e
set -o nounset

#
# About
# -----
#
# HDDSuspend is a little helper to allow disks to suspend after a given
# interval of no-operation. Unfortunately the `-S` option does not work with
# all of SATA devices. Therefore I created this little script, with utilizes
# `/proc/diskstats` as well as the cron deamon to manually call `hdparam -y` on
# the associated device after a given interval of inactivity.

## `show_usage`
#
# Display usage information of this utility extracted from the this files lines
# marked with '#/' and exit with errorcode 2. The idea for this is from Ryan
# Tomayko <tomayko.com/about>.
show_usage() {
    grep '^#/' <"${0}" | cut -c4-
    exit 2
}

## extract_diskstat_for_device <device>
#
# Extract the diskstat information for the given device.
# The device should be specified in the format `/dev/somedevice`.
# First the diskstat output will be checked against the full device name. If
# this does not yield any results only the `somedevice` part will be searched
# for.
extract_diskstat_for_device() {
    extracted_diskstat="$(cat "${diskstats_file}"|awk "{ if (\$3 == \"${1}\") print \$0 }")"
    if [ ! -z "${extracted_diskstat}" ]; then
        echo "${extracted_diskstat}"
        return
    fi

    # Only use the devicename and try again. Error out, if this wouldn't yield
    # any result
    if [ "${1}" = "${1##*/}" ]; then
        echo "No diskstat entry for device '${1}' could be found." >&2
        exit 3
    fi

    extract_diskstat_for_device "${1##*/}"
}

## sanitize_filename <string>
#
# Sanitize an arbitrary string to be used as a filename. Eventhough this is not
# needed on mos filesystems, to be safe everything else than `[A-Za-z0-9_-]`
# will be replaced with `_`.
sanitize_filename() {
    echo "${1}"|sed -e 's@[^A-Za-z0-9_-]@_@g'
}

## write_status_file <filename> <last_checked> <last_active> <diskstat>
#
# Write the given information to the provided statusfile formatting the data in
# a way that it can be sourced to be read in again
write_status_file() {
    echo "device_last_checked=\"${2}\"" >"${1}"
    echo "device_last_active=\"${3}\"" >>"${1}"
    echo "device_last_diskstat=\"${4}\"" >>"${1}"
}


# Parse the given commandline and set the needed option variables extracted
# from it. If the given arguments are incomplete or invalid usage will be
# displayed and the script will be exited.
#
# If there wasn't supplied any argument, or `--help or -h` has been
# supplied bail out.
if [ "$#" -eq 0 ] || expr -- " $* " : '.* \(--help\|-h\) ' >/dev/null; then
    show_usage
fi

# Parse all the options until no more of them can be found
while [ "$#" -gt 0 ]; do
    case "$1" in
        "--timeout")
            shift;
            hdd_timeout="${1:-}"
        ;;
        "--storage")
            shift;
            storage_directory="${1:-}"
        ;;
        "--diskstats")
            shift;
            diskstats_file="${1:-}"
        ;;
        *)
            break
        ;;
    esac
    [ "$#" -gt 0 ] && shift
done

: ${hdd_timeout:=30}
: ${storage_directory:=/var/run/hddsuspend}
: ${diskstats_file:=/proc/diskstats}

# Make sure the storage directory exists and is set to 300 for security reasons
if [ ! -d "${storage_directory}" ]; then
    mkdir "${storage_directory}"
    chmod 0300 "${storage_directory}"
fi

if [ "$(stat -c "%a" "${storage_directory}")" != "300" ]; then
    echo "The storage directory '${storage_directory}' must be set to access rights 300 for security reasons" >&2
    exit 127
fi

# Bail out if no device is left after option parsing
[ "$#" -eq 0 ] && show_usage

# Remember the current timestamp as we need it multiple times and don't want to
# call date all the time
now="$(date "+%s")"

# Loop through all the given devices to extract and store the newest
# information about them.
for device in "$@"; do
    # Make sure we have at least an empty storage file for each device
    device_storage="${storage_directory}/$(sanitize_filename "${device}").status"
    if [ ! -f "$device_storage}" ]; then
        touch "${device_storage}"
    fi

    # Load all stored information about the device
    . "${device_storage}"
    : ${device_last_checked:=0}
    : ${device_last_active:=${now}}
    : ${device_last_diskstat:=NO STATS}

    # Check if there has been activity since the last check
    device_current_diskstat=$(extract_diskstat_for_device "${device}")
    if [ "${device_current_diskstat}" != "${device_last_diskstat}" ]; then
        device_last_active="${now}"
        device_last_diskstat="${device_current_diskstat}"
    fi

    # Update the last_checked timestamp for statistical reasons
    device_last_checked="${now}"

    # Write all the new data to the status file for the next run
    write_status_file "${device_storage}" "${device_last_checked}" "${device_last_active}" "${device_last_diskstat}"

    # Determine whether the current device should go to sleep. If this is the
    # case send it to sleep using `hdparm -y` if it isn't already sleeping
    if [ "${now}" -ge "$(( ${device_last_active} + ( ${hdd_timeout} * 60 ) ))" ]; then
        # Check if the device is really active, otherwise no operation is
        # needed
        if hdparm -C "${device}"|grep -q 'active/idle'; then
            hdparm -y "${device}"
        fi
    fi
done
