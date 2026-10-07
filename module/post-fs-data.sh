#!/bin/sh
# post-fs-data.sh / metamount.sh
# this script is part of mountify
# No warranty.
# No rights reserved.
# This is free software; you can redistribute it and/or modify it under the terms of The Unlicense.
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH
# variables
MODDIR="/data/adb/modules/mountify"
PERSISTENT_DIR="/data/adb/mountify"
# config defaults
mountify_mounts=2
FAKE_MOUNT_NAME="mountify"
stealth_lowerdir=1
compact_mounts=1
mountify_verbose=0
mountify_stop_start=0
FS_TYPE_ALIAS="overlay"
MOUNT_DEVICE_NAME="auto"
mountify_custom_umount=0
test_decoy_mount=0
DECOY_MOUNT_FOLDER="/oem"
mountify_expert_mode=0
use_ext4_sparse=0
spoof_sparse=0
FAKE_APEX_NAME="com.android.mntservice"
sparse_size="2048"
enable_lkm_nuke=0
lkm_filename="nuke.ko"
# read config
# strip CR so configs edited with Windows line endings still work
if [ -f "$PERSISTENT_DIR/config.sh" ]; then
	_cfg_tmp="/dev/mountify_config.$$"
	busybox tr -d '\r' < "$PERSISTENT_DIR/config.sh" > "$_cfg_tmp" 2>/dev/null
	. "$_cfg_tmp" 2>/dev/null
	rm -f "$_cfg_tmp"
fi
# resolve MOUNT_DEVICE_NAME
# "auto" picks the root manager's name so zygisk providers / ksud kernel umount can unmount
if [ "$MOUNT_DEVICE_NAME" = "auto" ]; then
	if [ "$KSU" = "true" ]; then
		MOUNT_DEVICE_NAME="KSU"
	elif [ "$APATCH" = "true" ]; then
		MOUNT_DEVICE_NAME="APatch"
	else
		MOUNT_DEVICE_NAME="magisk"
	fi
fi

# set prefix
# this is to handle it properly on kernelsu's metamodule mode
# we move this as metamount.sh on customize
DMESG_PREFIX="mountify/post-fs-data"
if [ -f "$MODDIR/metamount.sh" ]; then
	DMESG_PREFIX="mountify/metamount"
fi

# kmsg logging is gated behind mountify_verbose
# off by default so mountify leaves no traces in the kernel log
logmsg() {
	[ "$mountify_verbose" = "1" ] || return 0
	echo "$DMESG_PREFIX: $*" >> /dev/kmsg
}

# update module.prop description, sed-safe against & | \ in module names
set_description() {
	_desc_escaped=$(printf '%s' "$1" | sed 's/[&|\\]/\\&/g')
	sed -i "s|^description=.*|$_desc_escaped|g" "$MODDIR/module.prop"
}

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
	set_description "description=mode: disabled 💀"
	exit 0
fi

# find MNT_FOLDER
[ -w "/mnt" ] && MNT_FOLDER="/mnt"
# keep the (/mnt/vendor is mounted) check here! we dont want to write shit on it if its mounted!
[ -w "/mnt/vendor" ] && ! busybox grep -q " /mnt/vendor " "/proc/mounts" && MNT_FOLDER="/mnt/vendor"
if [ -z "$MNT_FOLDER" ] || [ ! -d "$MNT_FOLDER" ] || [ ! -w "$MNT_FOLDER" ]; then
	set_description "description=mode: error (no staging dir)"
	exit 1
fi

# single instance run
# on ksu's metamodule mode, it seems post-fs-data runs twice
# acquired after config validation so a failed first run doesn't hold the lock
MOUNTIFY_LOCK="/dev/.daemon_lock"
if ! mkdir "$MOUNTIFY_LOCK" 2>/dev/null; then
	logmsg "already ran!"
	exit 1
fi

# add simple anti bootloop logic
BOOTCOUNT=0
[ -f "$MODDIR/count.sh" ] && . "$MODDIR/count.sh"

BOOTCOUNT=$(( BOOTCOUNT + 1 ))

if [ ! -f "$PERSISTENT_DIR/explicit_I_want_a_bootloop" ] && [ "$BOOTCOUNT" -gt 1 ]; then
	touch "$MODDIR/disable"
	rm "$MODDIR/count.sh"
	set_description "description=anti-bootloop triggered. module disabled. enable to activate."
	exit 1
else
	echo "BOOTCOUNT=1" > "$MODDIR/count.sh"
fi

# grab start time
logmsg "start!"

# create logging folder
# lives under /data/adb so nothing lands in world readable /dev
LOG_FOLDER="$PERSISTENT_DIR/logs"
mkdir -p "$LOG_FOLDER"
chmod 700 "$LOG_FOLDER" 2>/dev/null
# fresh logs on every run
rm -f "$LOG_FOLDER/before" "$LOG_FOLDER/after" "$LOG_FOLDER/modules" "$LOG_FOLDER/mountify_mount_list"
# log before
cat /proc/mounts > "$LOG_FOLDER/before"

# module mount section
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

# check if fake alias exists, if fail use overlay
if ! grep "nodev" /proc/filesystems | grep -q "$FS_TYPE_ALIAS" > /dev/null 2>&1; then
	FS_TYPE_ALIAS="overlay"
fi

# staging area selection (stealth_lowerdir)
# stage module files into an empty decoy partition dir so mountinfo
# lowerdir never contains the fake folder name
STAGE_DIR="$MNT_FOLDER/$FAKE_MOUNT_NAME"
STAGE_MODE="fake"
stage_decoy_candidates="/oem
/patch_hw
/second_stage_resources
/postinstall"

if [ "$stealth_lowerdir" = "1" ] && [ "$use_ext4_sparse" != "1" ] && [ ! -f "$MODDIR/no_tmpfs_xattr" ]; then
	for dir in $stage_decoy_candidates; do
		if [ -d "$dir" ] && [ -w "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ] &&
			! busybox grep -q " $dir " /proc/mounts &&
			busybox mount -t tmpfs tmpfs "$dir" 2>/dev/null; then
			STAGE_DIR="$dir"
			STAGE_MODE="decoy"
			logmsg "staging at decoy $STAGE_DIR"
			break
		fi
	done
fi

# legacy decoy mount test (topmost empty layer)
# only for fake staging, a decoy staging dir already leads the lowerdir chain
decoy_mount_enabled=""
if [ "$STAGE_MODE" = "fake" ] && [ "$test_decoy_mount" = "1" ] && [ ! -f "$MODDIR/no_tmpfs_xattr" ]; then
	decoy_folder_candidates="/oem
/second_stage_resources
/patch_hw
/postinstall
/system_dlkm
/oem_dlkm
/acct
"
	# test for decoy mount
	# it needs to be a blank folder
	for dir in $decoy_folder_candidates; do
		if [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null | wc -l)" -eq 0 ]; then
			DECOY_MOUNT_FOLDER="$dir"
			logmsg "decoy folder $DECOY_MOUNT_FOLDER"
			decoy_mount_enabled="1"
			break
		fi
	done
fi

# functions

# controlled depth ($targets fuckery)
controlled_depth() {
	if [ -z "$1" ] || [ -z "$2" ]; then return ; fi
	for DIR in $(ls -d "$STAGE_DIR/$1"/*/ 2>/dev/null | sed "s|^$STAGE_DIR||; s|^/||; s|/$||"); do
		# skip mount targets that do not exist
		[ -d "$2$DIR" ] || continue
		if [ "$decoy_mount_enabled" = "1" ] && [ -w "$DECOY_MOUNT_FOLDER" ]; then
			mkdir -p "$DECOY_MOUNT_FOLDER$2$DIR"
			busybox mount -t "$FS_TYPE_ALIAS" -o "lowerdir=$DECOY_MOUNT_FOLDER$2$DIR:$STAGE_DIR/$DIR:$2$DIR" "$MOUNT_DEVICE_NAME" "$2$DIR" && echo "$2$DIR" >> "$LOG_FOLDER/mountify_mount_list"
		else
			busybox mount -t "$FS_TYPE_ALIAS" -o "lowerdir=$STAGE_DIR/$DIR:$2$DIR" "$MOUNT_DEVICE_NAME" "$2$DIR" && echo "$2$DIR" >> "$LOG_FOLDER/mountify_mount_list"
		fi
	done
}

# handle single depth (/system/bin, /system/etc, et. al)
single_depth() {
	for DIR in $(ls -d "$STAGE_DIR"/*/ 2>/dev/null | sed "s|^$STAGE_DIR||; s|^/||; s|/$||"); do
		# partition dirs are handled by controlled_depth at the root
		printf '%s\n' "$targets" | busybox grep -qx "$DIR" && continue
		# skip mount targets that do not exist
		[ -d "/system/$DIR" ] || continue
		if [ "$decoy_mount_enabled" = "1" ] && [ -w "$DECOY_MOUNT_FOLDER" ]; then
			mkdir -p "$DECOY_MOUNT_FOLDER/system/$DIR"
			busybox mount -t "$FS_TYPE_ALIAS" -o "lowerdir=$DECOY_MOUNT_FOLDER/system/$DIR:$STAGE_DIR/$DIR:/system/$DIR" "$MOUNT_DEVICE_NAME" "/system/$DIR" && echo "/system/$DIR" >> "$LOG_FOLDER/mountify_mount_list"
		else
			busybox mount -t "$FS_TYPE_ALIAS" -o "lowerdir=$STAGE_DIR/$DIR:/system/$DIR" "$MOUNT_DEVICE_NAME" "/system/$DIR" && echo "/system/$DIR" >> "$LOG_FOLDER/mountify_mount_list"
		fi
	done
}

# handle getfattr, it is sometimes not symlinked on /system/bin yet toybox has it
# I fucking hope magisk's busybox ships it sometime
if /system/bin/getfattr -d /system/bin > /dev/null 2>&1; then
	getfattr() { /system/bin/getfattr "$@"; }
else
	getfattr() { /system/bin/toybox getfattr "$@"; }
fi

mountify_copy() {
	# return for missing args
	if [ -z "$1" ]; then
		# echo "$(basename "$0" ) module_id fake_folder_name"
		logmsg "missing arguments, fuck off"
		return
	fi

	MODULE_ID="$1"

	# return for certain modules
	# De-bloater uses dummy text, not whiteouts, which does not really work
	if [ "$MODULE_ID" = "De-bloater" ]; then
		logmsg "module with name $MODULE_ID is blacklisted"
		return
	fi

	# test for various stuff
	# you dont want to global mount hosts file
	# (a hosts file itself is dropped from the copy further down instead of skipping the whole module)
	TARGET_DIR="/data/adb/modules/$MODULE_ID"
	if [ ! -d "$TARGET_DIR/system" ] || [ -f "$TARGET_DIR/disable" ] || [ -f "$TARGET_DIR/remove" ] ||
		[ -f "$TARGET_DIR/skip_mountify" ]; then
		logmsg "module with name $MODULE_ID not meant to be mounted"
		return
	fi

	# lets just add another clause for ksu/ap metamodule mode
	# this way its easier to maintain
	# on metamodule mode, we can actually respect skip_mount
	if [ -f "$MODDIR/metamount.sh" ] && [ -f "$TARGET_DIR/skip_mount" ]; then
		logmsg "module with name $MODULE_ID has skip_mount"
		return
	fi

	logmsg "processing $MODULE_ID"

	# if NOT on metamodule mode, we must make sure to skip_mount the module we plan to mount
	if [ ! -f "$MODDIR/metamount.sh" ] && [ ! -f "$TARGET_DIR/skip_mount" ]; then
		touch "$TARGET_DIR/skip_mount"
		# log modules that got skip_mounted
		# those get released on uninstall or when mountify_mounts=0
		busybox grep -qx "$MODULE_ID" "$PERSISTENT_DIR/skipped_modules" 2>/dev/null || echo "$MODULE_ID" >> "$PERSISTENT_DIR/skipped_modules"
	fi

	# we can copy over contents of system folder only
	BASE_DIR="/data/adb/modules/$MODULE_ID/system"

	# nothing to do on empty modules
	[ -n "$(ls -A "$BASE_DIR" 2>/dev/null)" ] || return 0

	# copy over our files, archive
	# busybox cp -c keeps the security context so we don't have to walk symlinks
	if ! ( cd "$STAGE_DIR" && busybox cp -afc "$BASE_DIR"/* "$STAGE_DIR/" ) 2>/dev/null; then
		# fallback: plain copy, then mirror selinux contexts without following symlinks
		# (find -L would walk the real trees that module symlinks point to)
		# else we get "u:object_r:tmpfs:s0"
		if ! ( cd "$STAGE_DIR" && cp -af "$BASE_DIR"/* "$STAGE_DIR/" ); then
			logmsg "copy failed for $MODULE_ID"
			return
		fi
		busybox find "$BASE_DIR" | sed "s|^$BASE_DIR||" | while IFS= read -r rel; do
			[ -e "$BASE_DIR$rel" ] || [ -L "$BASE_DIR$rel" ] || continue
			busybox chcon -h --reference="$BASE_DIR$rel" "$STAGE_DIR$rel" 2>/dev/null
		done
	fi

	# a module shipping a hosts file must not clobber the global one
	if [ -f "$BASE_DIR/etc/hosts" ]; then
		rm -f "$STAGE_DIR/etc/hosts"
	fi

	# catch opaque dirs, requires getfattr
	for dir in $( busybox find "$BASE_DIR" -type d ) ; do
		if getfattr -d "$dir" | grep -q "trusted.overlay.opaque" ; then
			opaque_dir="$STAGE_DIR${dir#$BASE_DIR}"
			busybox setfattr -n trusted.overlay.opaque -v y "$opaque_dir" 2>/dev/null
		fi
	done

	# if it reached here, module probably copied, log it
	echo "$MODULE_ID" >> "$LOG_FOLDER/modules"
}

if [ "$STAGE_MODE" = "fake" ]; then
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

	# lets also mount our own /mnt folder
	# so hierarchy becomes
	# stage1 /mnt or /mnt/vendor always tmpfs
	# stage2 /mnt/fake_folder_name or /mnt/vendor/fake_folder_name is either tmpfs or ext4
	if [ -d "$MNT_FOLDER" ]; then
		logmsg "stage1: mounting $(realpath "$MNT_FOLDER")"

		# mount and test, if it fails fuck it, we bail
		if ! busybox mount -t tmpfs tmpfs "$(realpath "$MNT_FOLDER")"; then
			logmsg "mounting $MNT_FOLDER fail! bail out!"
			exit 1
		fi

	fi

	# create it
	mkdir -p "$MNT_FOLDER/$FAKE_MOUNT_NAME"
	if [ ! -f "$MODDIR/no_tmpfs_xattr" ] && [ ! "$use_ext4_sparse" = "1" ]; then
		logmsg "stage2/tmpfs: mounting $(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"
		busybox mount -t tmpfs tmpfs "$(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"
	fi
	touch "$MNT_FOLDER/$FAKE_MOUNT_NAME/placeholder"

	# then make sure its there
	if [ ! -d "$MNT_FOLDER/$FAKE_MOUNT_NAME" ]; then
		# weird if it happens
		logmsg "failed creating folder with fake_folder_name $FAKE_MOUNT_NAME !"
		exit 1
	fi

	if [ "$decoy_mount_enabled" = "1" ] && [ -d "$DECOY_MOUNT_FOLDER" ] && [ "$(ls -A "$DECOY_MOUNT_FOLDER" 2>/dev/null | wc -l)" -eq 0 ]; then
		logmsg "mounting $DECOY_MOUNT_FOLDER"
		mount -t tmpfs tmpfs "$DECOY_MOUNT_FOLDER"
	fi
fi

if [ "$STAGE_MODE" = "fake" ] && { [ -f "$MODDIR/no_tmpfs_xattr" ] || [ "$use_ext4_sparse" = "1" ]; }; then
	# create 2GB sparse
	busybox dd if=/dev/zero of="$MNT_FOLDER/mountify-ext4" bs=1M count=0 seek="$sparse_size"
	/system/bin/mkfs.ext4 -O ^has_journal "$MNT_FOLDER/mountify-ext4"

	# https://github.com/tiann/KernelSU/pull/3019
	# this way only sparse mode on ksu gets the rule
	[ "$KSU" = "true" ] && busybox chcon "u:object_r:ksu_file:s0" "$MNT_FOLDER/mountify-ext4"

	logmsg "stage2/ext4: mounting $(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"
	busybox mount -o loop,rw,noatime,nodiratime "$MNT_FOLDER/mountify-ext4" "$MNT_FOLDER/$FAKE_MOUNT_NAME"
fi

# if manual mode and modules.txt has contents
if [ "$mountify_mounts" = 1 ]; then
	# manual mode
	# an empty list mounts nothing, inline comments are allowed
	if [ -f "$PERSISTENT_DIR/modules.txt" ]; then
		for line in $( sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PERSISTENT_DIR/modules.txt" ); do
			module_id=$( printf '%s' "$line" | awk '{print $1}' )
			[ -n "$module_id" ] && mountify_copy "$module_id"
		done
	fi
else
	# auto mode
	for module in /data/adb/modules/*/system; do
		[ -d "$module" ] || continue
		module_id="$(echo $module | cut -d / -f 5 )"
		mountify_copy "$module_id"
	done
fi

if [ "$STAGE_MODE" = "fake" ] && { [ -f "$MODDIR/no_tmpfs_xattr" ] || [ "$use_ext4_sparse" = "1" ]; }; then
	# unmount and remount ext4 image as ro
	busybox umount -l "$MNT_FOLDER/$FAKE_MOUNT_NAME"

	logmsg "stage2/ext4: remounting $(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"

	if [ "$spoof_sparse" = "1" ] && [ -w "/apex" ] && [ ! -e "/apex/$FAKE_APEX_NAME" ]; then
		# here we copy how android does it
		mkdir -p "/apex/$FAKE_APEX_NAME@1"
		busybox mount -o loop,ro,dirsync,seclabel,nodev,noatime "$MNT_FOLDER/mountify-ext4" "/apex/$FAKE_APEX_NAME@1"
		mkdir -p "/apex/$FAKE_APEX_NAME" # then prepare the original for it
		busybox mount --bind,ro "/apex/$FAKE_APEX_NAME@1" "/apex/$FAKE_APEX_NAME"
		rm -rf "$MNT_FOLDER/$FAKE_MOUNT_NAME"
		busybox ln -sf "/apex/$FAKE_APEX_NAME" "$MNT_FOLDER/$FAKE_MOUNT_NAME"
	else
		busybox mount -o loop,ro,noatime,nodiratime "$MNT_FOLDER/mountify-ext4" "$MNT_FOLDER/$FAKE_MOUNT_NAME"
	fi

fi

# mount
logmsg "mount phase"

# compact mode: single overlay for /system
# only when the stage root is a plain /system mirror:
# no partition dirs staged (those mount at the root) and nothing mounted under /system
compact_ok=0
if [ "$compact_mounts" = "1" ] && [ -d "$STAGE_DIR" ] && [ -n "$(ls -A "$STAGE_DIR" 2>/dev/null)" ]; then
	compact_ok=1
	for t in $targets; do
		if [ -d "$STAGE_DIR/$t" ]; then
			compact_ok=0
			break
		fi
	done
	if [ "$compact_ok" = 1 ] && cut -d' ' -f2 /proc/mounts | busybox grep -q '^/system/'; then
		compact_ok=0
	fi
fi

compact_done=0
if [ "$compact_ok" = 1 ]; then
	logmsg "compact: single overlay for /system"
	if busybox mount -t "$FS_TYPE_ALIAS" -o "lowerdir=$STAGE_DIR:/system" "$MOUNT_DEVICE_NAME" "/system"; then
		# placeholder is fake stage bookkeeping, keep it out of the merged view
		rm -f "$STAGE_DIR/placeholder"
		echo "/system" >> "$LOG_FOLDER/mountify_mount_list"
		compact_done=1
	fi
fi

# handle single depth (/system/bin, /system/etc, et. al)
if [ "$compact_done" != 1 ]; then
	single_depth
fi

# handle this stance when /product is a symlink to /system/product
for folder in $targets ; do
	if [ -L "/$folder" ] && [ ! -L "/system/$folder" ]; then
		# legacy, so we mount at /system
		controlled_depth "$folder" "/system/"
	else
		# modern, so we mount at root
		controlled_depth "$folder" "/"
	fi
done

if [ "$decoy_mount_enabled" = "1" ] && [ -d "$DECOY_MOUNT_FOLDER" ]; then
	logmsg "unmounting $DECOY_MOUNT_FOLDER"
	busybox umount -l "$DECOY_MOUNT_FOLDER"
fi

# insmod compat - system provided insmod most of the times is betterer
if command -v /system/bin/insmod > /dev/null 2>&1; then
	insmod() { /system/bin/insmod "$@"; }
else
	insmod() { busybox insmod "$@"; }
fi

# check if this ksud can nuke ext4 sysfs
# re-detected at boot so it keeps working across ksud updates
ksud_can_nuke() {
	[ -f "$MODDIR/ksud_has_nuke_ext4" ] && return 0
	[ "$KSU" = "true" ] || return 1
	/data/adb/ksud kernel 2>&1 | busybox grep -q "nuke-ext4-sysfs"
}

# pick an lkm that matches this kernel/android
resolve_lkm() {
	# keep an explicit user choice when the file exists
	if [ "$lkm_filename" != "nuke.ko" ] && [ -f "$MODDIR/lkm/$lkm_filename" ]; then
		return 0
	fi
	krel=$(busybox uname -r | cut -d. -f1-2)
	arel=$(getprop ro.build.version.release | cut -d. -f1)
	chosen=""
	if [ "$krel" = "4.14" ] && [ -f "$MODDIR/lkm/nuke-android-4.14.ko" ]; then
		chosen="nuke-android-4.14.ko"
	elif [ -n "$krel" ] && [ -n "$arel" ]; then
		if [ -f "$MODDIR/lkm/nuke-android${arel}-${krel}.ko" ]; then
			chosen="nuke-android${arel}-${krel}.ko"
		else
			# same kernel, newest android that does not exceed this device
			best=0
			for f in "$MODDIR"/lkm/nuke-android*-"$krel".ko; do
				[ -f "$f" ] || continue
				a=$(basename "$f" | sed "s/^nuke-android\([0-9][0-9]*\)-.*/\1/")
				case "$a" in
					''|*[!0-9]*) continue ;;
				esac
				if [ "$a" -le "$arel" ] && [ "$a" -gt "$best" ]; then
					best=$a
					chosen=$(basename "$f")
				fi
			done
		fi
	fi
	[ -n "$chosen" ] || return 1
	lkm_filename="$chosen"
	return 0
}

# verify the lkm against the shipped checksums
verify_lkm() {
	_ko="$MODDIR/lkm/$lkm_filename"
	[ -f "$_ko" ] || return 1
	expected=$(busybox awk -v f="$lkm_filename" '$2 == f {print $1}' "$MODDIR/lkm/list.txt")
	[ -n "$expected" ] || return 1
	actual=$(busybox sha256sum "$_ko" | cut -d' ' -f1)
	[ "$expected" = "$actual" ]
}

# nuke ext4 sysfs
# this unregisters an ext4 node used on ext4 mode (duh)
# this way theres no nodes are lingering on /proc/fs
if [ "$enable_lkm_nuke" = 1 ] && [ "$spoof_sparse" = "0" ] && ! ksud_can_nuke &&
	{ [ -f "$MODDIR/no_tmpfs_xattr" ] || [ "$use_ext4_sparse" = "1" ]; }; then

	if resolve_lkm && verify_lkm; then
		mnt="$(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"
		kptr_set=$(cat /proc/sys/kernel/kptr_restrict)
		echo 1 > /proc/sys/kernel/kptr_restrict
		ptr_address=$(grep " ext4_unregister_sysfs$" /proc/kallsyms | awk {'print "0x"$1'})
		logmsg "stage2/ext4: loading LKM $lkm_filename with mount_point=$mnt symaddr=$ptr_address"
		if insmod "$MODDIR/lkm/$lkm_filename" mount_point="$mnt" symaddr="$ptr_address" > /dev/null 2>&1; then
			logmsg "stage2/ext4: LKM loaded"
		else
			logmsg "stage2/ext4: LKM load failed!"
		fi
		echo $kptr_set > /proc/sys/kernel/kptr_restrict
	else
		logmsg "stage2/ext4: LKM skipped (selection/verification failed for $lkm_filename)"
	fi

fi

# ksud kernel nuke-ext4-sysfs
# uses official ksud interface
if [ "$spoof_sparse" = "0" ] &&
	{ [ -f "$MODDIR/no_tmpfs_xattr" ] || [ "$use_ext4_sparse" = "1" ]; } &&
	ksud_can_nuke; then

	mnt="$(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"
	logmsg "stage2/ext4: ksud kernel nuke-ext4-sysfs $mnt"
	/data/adb/ksud kernel nuke-ext4-sysfs "$mnt" > /dev/null 2>&1 || logmsg "stage2/ext4: ksud nuke failed!"

fi

# we can commonize umount instead
# its the same for tmpfs and ext4 anyway
if [ "$STAGE_MODE" = "decoy" ]; then
	logmsg "stage/decoy: unmounting $STAGE_DIR"
	busybox umount -l "$STAGE_DIR"
elif [ "$spoof_sparse" = "0" ]; then
	logmsg "stage2: unmounting $(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"
	busybox umount -l "$(realpath "$MNT_FOLDER/$FAKE_MOUNT_NAME")"
fi

# delete the sparse
if [ -f "$MODDIR/no_tmpfs_xattr" ] || [ "$use_ext4_sparse" = "1" ]; then
	[ -f "$MNT_FOLDER/mountify-ext4" ] && rm "$MNT_FOLDER/mountify-ext4"
fi

# unmount stage1
if [ "$STAGE_MODE" = "fake" ]; then
	logmsg "stage1: unmounting $(realpath "$MNT_FOLDER")"
	busybox umount -l "$MNT_FOLDER"
fi

# handle operating mode
case $mountify_mounts in
	1) mode="manual 🤓" ;;
	2) mode="auto 🤖" ;;
	*) mode="auto 🤖" ;;
esac

if [ "$use_ext4_sparse" = "1" ] || [ -f "$MODDIR/no_tmpfs_xattr" ]; then
	mode="$mode | fstype: ext4 🛠️"
else
	mode="$mode | fstype: tmpfs 🦾"
fi

# generate description accordingly
string="description=mode: $mode | no modules mounted"
if [ -f "$LOG_FOLDER/modules" ]; then
	module_list=$( for module in $(cat "$LOG_FOLDER/modules" ) ; do printf '%s ' "$module" ; done )
	string="description=mode: $mode | modules: $module_list "
fi

# only update when generated string is different
desc_current=$(grep "^description=" "$MODDIR/module.prop")
if [ "$desc_current" != "$string" ]; then
	set_description "$string"
fi

# log after
cat /proc/mounts > "$LOG_FOLDER/after"
logmsg "finished!"

# EOF
