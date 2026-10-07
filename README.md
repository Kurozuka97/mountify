# Mountify Next

#### Globally mounted modules via OverlayFS.

Mountify Next is a fork of [backslashxx/mountify](https://github.com/backslashxx/mountify), maintained by Kurozuka97.

- acts as a KernelSU [metamodule](https://kernelsu.org/guide/metamodule.html)
- works on APatch and Magisk too
- **CONFIG_OVERLAY_FS=y** is required 
- **CONFIG_TMPFS_XATTR=y** is highly encouraged
- tries to mimic an OEM mount, like /mnt/vendor/my_bigball
- for module devs, you can also use [this standalone script](https://github.com/Kurozuka97/mountify/tree/standalone-script)

## Methodology
### tmpfs mode 
#### - tmpfs backed
1. `touch /data/adb/modules/module_id/skip_mount`
2. copies contents of `/data/adb/modules/module_id` to `/mnt/vendor/fake_folder_name`
3. mirrors SELinux context of every file from `/data/adb/modules/module_id` to `/mnt/vendor/fake_folder_name`
4. loops 2 and 3 for all modules
5. overlays `/mnt/vendor/fake_folder_name/system/bin` to `/system/bin` and other folders

### ext4 sparse mode 
#### - ext4-sparse-on-tmpfs backed
1. `touch /data/adb/modules/module_id/skip_mount`
2. create an ext4 sparse image, mount it on `/mnt/vendor/fake_folder_name`
3. copies contents of `/data/adb/modules/module_id` to `/mnt/vendor/fake_folder_name`
4. mirrors SELinux context of every file from `/data/adb/modules/module_id` to `/mnt/vendor/fake_folder_name`
5. loops 3 and 4 for all modules
6. unmounts and remounts sparse image to `/mnt/vendor/fake_folder_name`
7. overlays `/mnt/vendor/fake_folder_name/system/bin` to `/system/bin` and other folders

## Why?
- Magic mount drastically increases mount count, making detection possible (zimperium)
- OverlayFS mounting with ext4 image upperdir is detectable due to it creating device nodes on /proc/fs, while yes ext4 /data as overlay source is possible, this is rare nowadays.
- F2FS /data as overlay source fails with native casefolding (ovl_dentry_weird), so only sdcardfs users can use /data as overlay source.
- Frankly, I dont see a way to this module mounting situation, this shit is more of a shitty band-aid

### but ext4 sparse mode creates ext4 nodes!
- this is added to accomodate something like GPU drivers
- this causes detections but YMMV.
- this is not my problem, this is a fallback, not the main recommendation.
- and yes this is basically how Official KernelSU used to do it.
- if you're on GKI 5.10+, theres an experimental LKM that nukes these nodes.
- if you're on KernelSU 22105+ this is automatically handled.

## Usage
- user-friendly config editing is available on the WebUI
- otherwise you can modify /data/adb/mountify/config.sh

### General
- by default, mountify mounts all modules with a system folder. `mountify_mounts=2`
- to mount specific modules only, edit config.sh, `mountify_mounts=1` then modify modules.txt to list modules you want mounted
  - an empty list in manual mode mounts nothing (it does NOT fall back to auto mode)

```
module_id
Adreno_Gpu_Driver
DisplayFeatures
ViPER4Android-RE-Fork
mountify_whiteouts
```
- `FAKE_MOUNT_NAME="mountify"` to set a custom fake folder name
- `mountify_stop_start=1` to restart android at service (needed for certain modules)
- `mountify_mounts=0` releases all `skip_mount` markers mountify created, so previously
  managed modules go back to your root manager's normal handling on next boot

#### tmpfs specific
- `test_decoy_mount=1` to enable testing for decoy mounts on tmpfs mode

#### ext4 specific
- `use_ext4_sparse=1` to force using ext4 mode if your setup is tmpfs_xattr capable
- `spoof_sparse=1` to try spoof sparse mount as an android service
- `FAKE_APEX_NAME="com.android.mntservice"` to customize that android service spoofed name
- `sparse_size="2048"` to set your sparse size (in MB) to whatever you want
- `enable_lkm_nuke=1` to try load an experimental LKM.
  - `lkm_filename` selects the LKM; if the file doesn't exist, mountify picks the
    matching prebuilt for your kernel/android version from `lkm/list.txt`
  - LKM prebuilts are sha256-verified against `lkm/list.txt` before loading
- `lkm_filename="nuke.ko"` to define LKM's filename. When left at the default
  (or the file is missing), mountify auto-selects the module matching your
  kernel and Android version and verifies it against the shipped sha256.

### Stealth
- `stealth_lowerdir=1` stages module files into a decoy directory (e.g. `/oem`)
  when an empty one is available, so mountinfo `lowerdir=` never contains your
  fake folder name. Falls back to the fake folder when no decoy dir exists.
- `compact_mounts=1` mounts `/system` with a **single** overlay instead of one
  mount per subdirectory, when it is safe to do so (no partition dirs in the
  staged tree, no existing mounts under `/system`). This keeps the mount count
  as low as possible.
- `mountify_verbose=0` suppresses all mountify kmsg logging (default).
  Set to `1` when debugging.
- `MOUNT_DEVICE_NAME` defaults to `auto`: it resolves to `KSU`, `APatch` or
  `magisk` for your root manager. Mounts tagged with your manager's name can be
  unmounted from Zygisk denylist / in-kernel umount — for denylisted apps the
  mounts disappear entirely, which is the strongest hiding available.
  Set it explicitly (e.g. `MOUNT_DEVICE_NAME="overlay"`) to override.
  Configs from older releases that still say `MOUNT_DEVICE_NAME="overlay"` keep
  that behavior — change the value to `auto` to get the manager-name resolution.
- what is still visible without an unmount provider: `/proc/self/mountinfo`
  shows overlay mounts and `statfs()` on them reports the overlayfs magic.
  Pair mountify with a Zygisk denylist unmount provider (below) to close this.

### Need Unmount?
- use either NeoZygisk, ReZygisk, Zygisk Assistant, Zygisk Next
- on Zygisk Next, set Denylist Policy to "Enforced" or "Unmount Only"
- `MOUNT_DEVICE_NAME` auto-resolves to your manager's name, so unmount
  providers work out of the box. To force it manually, edit config.sh
   - `MOUNT_DEVICE_NAME="APatch"` if you're on APatch
   - `MOUNT_DEVICE_NAME="KSU"` if you're on KernelSU forks
   - `MOUNT_DEVICE_NAME="magisk"` if you're on Magisk
- `mountify_custom_umount=0` modify this value to enable known in-kernel umount methods.
   - NOTE: zygisk provider umount is still better, this is here as a second choice.

#### I need mountify to skip mounting my module!
- `skip_mount` is respected on metamodule mode (KSU / APatch)
- however on Magisk make sure to use `skip_mountify` instead
- mountify checks these on /data/adb/modules/module_name

### Advanced / Debugging
- remove `metamodule=true` from module.prop before installing to force non-metamodule mode
- create `/data/adb/mountify/explicit_I_want_a_bootloop` to disable anti-bootloop protection
- set `mountify_expert_mode=1` to force expert mode (disables safety checks)
- set `mountify_verbose=1` to re-enable kmsg logging
- create `/data/adb/mountify/explicit_I_want_symlink` to force symlink mode before installing
  - unsupported and deprecated, meant for legacy devices
- sh whiteout_gen.sh to generate a whiteout module (deprecated but its still there)

## Limitations / Recommendations
- fails with [De-Bloater](https://github.com/sunilpaulmathew/De-Bloater), as it [uses dummy text, NOT proper whiteouts](https://github.com/sunilpaulmathew/De-Bloater/blob/cadd523f0ad8208eab31e7db51f855b89ed56ffe/app/src/main/java/com/sunilpaulmathew/debloater/utils/Utils.java#L112)
- I recommend [System App Nuker](https://github.com/ChiseWaguri/systemapp_nuker/releases) instead. It uses proper whiteouts.
- disabling mountify via your manager (the `disable` flag) cannot clean up
  `skip_mount` markers by itself — set `mountify_mounts=0` and reboot once if
  you want other modules handed back to your manager

## Maintainers
- [Kurozuka97](https://github.com/Kurozuka97) — Mountify Next (this fork)
- xx, [KOWX712](https://github.com/KOWX712) — original Mountify

## License
- module is on [The Unlicense](https://github.com/Kurozuka97/mountify/blob/master/LICENSE)
- LKM is on [GPLv2](https://github.com/Kurozuka97/mountify/blob/master/nuke_ext4_lkm/LICENSE)
- WebUI is on [MIT](https://github.com/Kurozuka97/mountify/blob/master/webui/LICENSE)

## Support / Warranty
- None, none at all. I am handing you a sharp knife, it is not on me if you stab yourself with it.

## Links
[Download](https://github.com/Kurozuka97/mountify/releases)

