#!/bin/sh
# boot-completed.sh
# this script is part of mountify
# No warranty.
# No rights reserved.
# This is free software; you can redistribute it and/or modify it under the terms of The Unlicense.
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH
MODDIR="/data/adb/modules/mountify"
# config defaults
mountify_verbose=0
# read config
# strip CR so configs edited with Windows line endings still work
PERSISTENT_DIR="/data/adb/mountify"
if [ -f "$PERSISTENT_DIR/config.sh" ]; then
	_cfg_tmp="/dev/mountify_config.$$"
	busybox tr -d '\r' < "$PERSISTENT_DIR/config.sh" > "$_cfg_tmp" 2>/dev/null
	. "$_cfg_tmp" 2>/dev/null
	rm -f "$_cfg_tmp"
fi

LOG_FOLDER="$PERSISTENT_DIR/logs"

# kmsg logging is gated behind mountify_verbose
logmsg() {
	[ "$mountify_verbose" = "1" ] || return 0
	echo "mountify/boot-completed: $*" >> /dev/kmsg
}

# reset bootcount (anti-bootloop routine)
echo "BOOTCOUNT=0" > "$MODDIR/count.sh"

# remove mountify single instance lock
MOUNTIFY_LOCK="/dev/.daemon_lock"
if [ -d "$MOUNTIFY_LOCK" ] || [ -f "$MOUNTIFY_LOCK" ]; then
	logmsg "lifting single instance lock"
	rm -rf "$MOUNTIFY_LOCK"
fi

# clean log folder
# kept around when mountify_verbose=1 so it can be inspected after boot
if [ "$mountify_verbose" != "1" ]; then
	[ -d "$LOG_FOLDER" ] && rm -rf "$LOG_FOLDER"
fi

# EOF
