#!/bin/sh
# post-fs-data.sh
# this script is part of mountify (symlink ver)
# No warranty.
# No rights reserved.
# This is free software; you can redistribute it and/or modify it under the terms of The Unlicense.
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH
MODDIR="/data/adb/modules/mountify"

# config defaults
mountify_mounts=2
mountify_expert_mode=0
MOUNT_DEVICE_NAME="overlay"
FS_TYPE_ALIAS="overlay"
FAKE_MOUNT_NAME="mountify"
mountify_verbose=0
PERSISTENT_DIR="/data/adb/mountify"
# read config
# strip CR so configs edited with Windows line endings still work
if [ -f "$PERSISTENT_DIR/config.sh" ]; then
	_cfg_tmp="/dev/mountify_config.$$"
	busybox tr -d '\r' < "$PERSISTENT_DIR/config.sh" > "$_cfg_tmp" 2>/dev/null
	. "$_cfg_tmp" 2>/dev/null
	rm -f "$_cfg_tmp"
fi

# resolve MOUNT_DEVICE_NAME
if [ "$MOUNT_DEVICE_NAME" = "auto" ]; then
	if [ "$KSU" = "true" ]; then
		MOUNT_DEVICE_NAME="KSU"
	elif [ "$APATCH" = "true" ]; then
		MOUNT_DEVICE_NAME="APatch"
	else
		MOUNT_DEVICE_NAME="magisk"
	fi
fi

# release skip_mount markers that mountify itself created
release_skip_mounts() {
	[ -f "$PERSISTENT_DIR/skipped_modules" ] || return 0
	while IFS= read -r _mod; do
		[ -n "$_mod" ] && rm -f "/data/adb/modules/$_mod/skip_mount"
	done < "$PERSISTENT_DIR/skipped_modules"
	rm -f "$PERSISTENT_DIR/skipped_modules"
}

# exit if disabled
if [ "$mountify_mounts" = 0 ]; then
	release_skip_mounts
	exit 0
fi

# add simple anti bootloop logic
BOOTCOUNT=0
[ -f "$MODDIR/count.sh" ] && . "$MODDIR/count.sh"

BOOTCOUNT=$(( BOOTCOUNT + 1))

if [ $BOOTCOUNT -gt 1 ]; then
	touch $MODDIR/disable
	rm "$MODDIR/count.sh"
	string="description=anti-bootloop triggered. module disabled. enable to activate."
	sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
	exit 1
else
	echo "BOOTCOUNT=1" > "$MODDIR/count.sh"
fi

# this is a fast lookup for a writable dir
# these tends to be always available
[ -w "/mnt" ] && MNT_FOLDER="/mnt"
[ -w "/mnt/vendor" ] && ! busybox grep -q " /mnt/vendor " "/proc/mounts" && MNT_FOLDER="/mnt/vendor"

# create logging folder
LOG_FOLDER="$PERSISTENT_DIR/logs"
mkdir -p "$LOG_FOLDER"
chmod 700 "$LOG_FOLDER" 2>/dev/null
# fresh logs on every run
rm -f "$LOG_FOLDER/before" "$LOG_FOLDER/after" "$LOG_FOLDER/modules" "$LOG_FOLDER/mountify_mount_list"
# log before 
cat /proc/mounts > "$LOG_FOLDER/before"

IFS="
"
targets="odm
product
system_ext
vendor
apex
mi_ext
my_bigball
my_carrier
my_company
my_engineering
my_heytap
my_manifest
my_preload
my_product
my_region
my_reserve
my_stock
oem
optics
prism"

# set prefix
# this is to handle it properly on kernelsu's metamodule mode
# we move this as metamount.sh on customize
DMESG_PREFIX="mountify/post-fs-data"
if [ -f "$MODDIR/metamount.sh" ]; then
	DMESG_PREFIX="mountify/metamount"
fi

# kmsg logging is gated behind mountify_verbose
logmsg() {
	[ "$mountify_verbose" = "1" ] || return 0
	echo "$DMESG_PREFIX: $*" >> /dev/kmsg
}

# check if fake alias exists, if fail use overlay
if ! grep "nodev" /proc/filesystems | grep -q "$FS_TYPE_ALIAS" > /dev/null 2>&1; then
	FS_TYPE_ALIAS="overlay"
fi

# functions
controlled_depth() {
	if [ -z "$1" ] || [ -z "$2" ]; then return ; fi
	mount_success=0
	for DIR in $(ls -d $1/*/ | sed 's/.$//' ); do
		busybox mount -t "$FS_TYPE_ALIAS" -o "lowerdir=$(pwd)/$DIR:$2$DIR" "$MOUNT_DEVICE_NAME" "$2$DIR" && mount_success=1
	done
	[ "$mount_success" = 1 ] && echo "$2$DIR" >> "$LOG_FOLDER/mountify_mount_list"
}

single_depth() {
	mount_success=0
	for DIR in $( ls -d */ | sed 's/.$//'  | grep -vE "^(odm|product|system_ext|vendor)$" 2>/dev/null ); do
		busybox mount -t "$FS_TYPE_ALIAS" -o "lowerdir=$(pwd)/$DIR:/system/$DIR" "$MOUNT_DEVICE_NAME" "/system/$DIR" && mount_success=1
	done
	[ "$mount_success" = 1 ] && echo "/system/$DIR" >> "$LOG_FOLDER/mountify_mount_list"
}

mountify_symlink() {
if [ -z "$1" ] || [ -z "$2" ]; then
	logmsg "missing arguments, fuck off"
	return
fi

TARGET_DIR="/data/adb/modules/$1"

if [ -f "$TARGET_DIR/disable" ] || [ -f "$TARGET_DIR/remove" ] || [ ! -d "$TARGET_DIR/system" ] ||
	[ -f "$TARGET_DIR/skip_mountify" ] || [ -f "$TARGET_DIR/system/etc/hosts" ]; then
	logmsg "$1 not meant to be mounted"
	return	
fi

if [ -f "$TARGET_DIR/skip_mount" ] && [ -f "$MODDIR/metamount.sh" ]; then
	logmsg "$1 has skip_mount"
	return
fi

logmsg "processing $1"

if [ ! -f "$MODDIR/metamount.sh" ] && [ ! -f "$TARGET_DIR/skip_mount" ]; then
	touch "$TARGET_DIR/skip_mount"
	# log modules that got skip_mounted
	# we can likely clean those at uninstall
	busybox grep -qx "$1" "$PERSISTENT_DIR/skipped_modules" 2>/dev/null || echo "$1" >> "$PERSISTENT_DIR/skipped_modules"
fi

MODULE_BASEDIR="$TARGET_DIR/system"
SUBFOLDER_NAME="$2"
	
# here we create the symlink
busybox ln -sf "$MODULE_BASEDIR" "$MNT_FOLDER/$FAKE_MOUNT_NAME/$SUBFOLDER_NAME"

if [ ! -d "$MNT_FOLDER/$FAKE_MOUNT_NAME/$SUBFOLDER_NAME" ]; then
	return
fi
cd "$MNT_FOLDER/$FAKE_MOUNT_NAME/$SUBFOLDER_NAME"

# single_depth
single_depth
# controlled depth
for folder in $targets ; do 
	# reset cwd due to loop
	cd "$MNT_FOLDER/$FAKE_MOUNT_NAME/$SUBFOLDER_NAME"
	if [ -L "/$folder" ] && [ ! -L "/system/$folder" ]; then
		# legacy, so we mount at /system
		controlled_depth "$folder" "/system/"
	else
		# modern, so we mount at root
		controlled_depth "$folder" "/"
	fi
done

# if it reached here, module probably copied, log it
echo "$1" >> "$LOG_FOLDER/modules"

} # mountify_symlink

# I dont think chaining is possible right away
# logic seems hard as we have to /mnt/vendor/module1/system/app:/mnt/vendor/module2/system/app
# PR welcome if somebody sees a way to do it easily.
# so just spam it for now

# prevent this fuckup since on expert mode this isnt checked
if [ "$FAKE_MOUNT_NAME" = "persist" ]; then
	logmsg "folder name named $FAKE_MOUNT_NAME is not allowed!"
	exit 1
fi

# make sure its not there
if [ ! "$mountify_expert_mode" = 1 ] && [ -d "$MNT_FOLDER/$FAKE_MOUNT_NAME" ]; then
	# anti fuckup
	# this is important as someone might actually use legit folder names
	# and same shit exists on MNT_FOLDER, prevent this issue.
	logmsg "exiting since fake folder name $FAKE_MOUNT_NAME already exists!"
	exit 1
fi

mkdir -p "$MNT_FOLDER/$FAKE_MOUNT_NAME"

# create our own tmpfs
mount -t tmpfs tmpfs "$MNT_FOLDER/$FAKE_MOUNT_NAME"

count=0
if [ "$mountify_mounts" = 1 ]; then
	if [ -f "$PERSISTENT_DIR/modules.txt" ]; then
		for line in $( sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PERSISTENT_DIR/modules.txt" ); do
			module_id=$( printf '%s' "$line" | awk '{print $1}' )
			[ -z "$module_id" ] && continue
			mountify_symlink "$module_id" "0000$count"
			count=$(( count + 1 ))
		done
	fi
else
	# auto mode
	for module in /data/adb/modules/*/system; do 
		module_id="$(echo $module | cut -d / -f 5 )"
		mountify_symlink "$module_id" "0000$count"
		count=$(( count + 1 ))
	done
fi

# unmout our own tmpfs
umount -l "$MNT_FOLDER/$FAKE_MOUNT_NAME"

# log after
cat /proc/mounts > "$LOG_FOLDER/after"
touch "$LOG_FOLDER/mountify_symlink"
logmsg "finished!"

# EOF
