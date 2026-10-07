# Mountify Next
Globally mounted modules and whiteouts via OverlayFS.

## Changelog
# 205
Fork of mountify 204 (backslashxx). Same module id, paths and config keys — drop-in update.

### Rebrand
- renamed to **Mountify Next**, maintained by Kurozuka97 (upstream: xx, KOWX712)
- update/release URLs, README, WebUI and locales now point to this fork
- `version=v2.0.5`, `versionCode=205`

### Stealth (new, all enabled by default)
- `stealth_lowerdir=1`: stages module files into an empty decoy partition dir
  (`/oem`, `/patch_hw`, `/second_stage_resources`, `/postinstall`) so
  `/proc/*/mountinfo` lowerdir never contains the fake folder name;
  falls back to the fake folder when no decoy dir is available
- `compact_mounts=1`: mounts `/system` with a **single** overlay instead of one
  mount per subdirectory when safe (no partition dirs staged, no existing mounts
  under `/system`) — keeps the mount count as low as possible
- `mountify_verbose=0`: all mountify kmsg logging is suppressed so nothing lands
  in the kernel log; set to `1` while debugging
- logs moved from world-readable `/dev/mountify_logs` to `/data/adb/mountify/logs`
  (chmod 700), kept after boot when `mountify_verbose=1`
- single-instance lock renamed to a bland `/dev/.daemon_lock`
- `MOUNT_DEVICE_NAME` now defaults to `auto`: resolves to your root manager's
  name (`KSU` / `APatch` / `magisk`) so Zygisk denylist / ksud kernel umount
  work out of the box. Existing configs that say `overlay` keep that behavior.

### Fixes
- manual mode: comment-only list now mounts nothing (previously fell back to
  auto and mounted *every* module); inline comments allowed; empty list mounts
  nothing
- `system/etc/hosts` no longer skips the whole module — only the hosts file is
  dropped from the copy
- module description update is sed-escaped (`&`/`|` in module names can't
  corrupt module.prop); fixed a `printf` format-string bug in the builder
- SELinux context mirroring no longer follows module symlinks into real trees
  (`find -L` dropped, `chcon -h`), fast path via `cp -afc`
- nonexistent mount targets are skipped; all partition dirs (not just
  odm/product/system_ext/vendor) are excluded from single-depth mounts
- `skip_mount` markers created by mountify are released when
  `mountify_mounts=0` and on uninstall; symlink mode recorded them in the wrong
  path so they were never cleaned before
- config sourcing is CRLF-safe with per-script defaults (Windows-edited configs
  no longer break boot scripts)
- single-instance lock is acquired atomically after validation (no double-run
  race, no stale lock on early failure)
- ksud `nuke-ext4-sysfs` support is re-detected at boot instead of install time
  (keeps working across ksud updates)
- LKM: auto-selects the `nuke-android*.ko` matching your kernel/Android version
  (the old default `nuke.ko` never existed), verifies sha256 against
  `lkm/list.txt` before loading, and logs load failures
- uninstall.sh guards a missing `skipped_modules` file

### WebUI
- config values are sanitized before writing: quotes/`$`/backticks/newlines
  stripped (with a toast), `&`/`|` escaped — no more broken or injected writes
- no more NaN values written back, values containing `=` are kept intact,
  config symlink created with `ln -sfn`
- module selector no longer hides modules that ship a hosts file

### Install
- missing config keys are merged into existing persistent configs on update
  (the new options show up in the WebUI)
- dropped the unused `resize2fs` requirement for ext4 fallback mode
- aborts cleanly when no writable staging folder (`/mnt`, `/mnt/vendor`) exists

### CI
- new lint workflow: shellcheck (errors), update.json ↔ module.prop version
  sync, CHANGELOG heading check, config keys ↔ WebUI metadata sync

### Full Changelog
- [Commit history](https://github.com/Kurozuka97/mountify/commits/master/)
