#!/bin/sh
# uninstall.sh
# this script is part of mountify
# No warranty.
# No rights reserved.
# This is free software; you can redistribute it and/or modify it under the terms of The Unlicense.
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH

# remove skip_mount on modules we skip_mounted
if [ -f "/data/adb/mountify/skipped_modules" ]; then
	for module in $(cat "/data/adb/mountify/skipped_modules"); do
		[ -n "$module" ] || continue
		rm -f "/data/adb/modules/$module/skip_mount"
	done
fi

# delete config directory
[ -d "/data/adb/mountify/" ] && rm -rf "/data/adb/mountify/"

# EOF
