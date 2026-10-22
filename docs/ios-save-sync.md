# Syncing saves between iPhone, iPad and Mac (proposal)

Status as of 2026-10-22: a proposal, nothing implemented. Today saves are copied by hand
([ios-settings.md, section 7](ios-settings.md#7-copying-saves-between-devices)).

## Where the saves are

| Device | Profile folder | Saves |
|---|---|---|
| Mac | `~/Library/Application Support/MacNativeGames/TOTK/profile` | `save/<uid>/` in it |
| iPhone, iPad | the app's `Documents/save` (also in Files › On My iPhone › the app, since the app shares its Documents) | `save/<uid>/` in it |

- `<uid>` comes from `account.uid` in the profile folder (runtime/account.c), random on each device unless copied. A
  sync should copy the contents of `save/<uid>/` (the `slot_*` folders, `option.sav`, `album`, `storage`) into the
  local `<uid>` folder, so the ids need not match.
- Every device must run the same game version (1.4.3 now). An older version may not read a newer save.
- The game writes through runtime/fs_host.c: writes mark the save dirty, `commit()` syncs the files to disk and clears
  it, and `runtime_fs_save_busy()` stays true while a write is open and for 3 s after. Copy out only when it is false.

## Options

| | Works away from the Mac | Changes | Limits |
|---|---|---|---|
| **A. Mac agent** | No | A Mac script only; no app rebuild | Only while the devices are on the Mac's Wi‑Fi or cable and the Mac is awake |
| **B. Folder in iCloud Drive, synced by the app** | Yes, with internet | The iOS app and the Mac app; rebuild and reinstall | iCloud may lag by minutes; files not downloaded yet must be waited for |
| C. iCloud container (CloudKit or ubiquity) | Yes | The signing team must add iCloud to the App ID and remake the profile; the Mac app signed by the same team | Ties the feature to one team; a free Personal Team cannot use it |
| Manual, Files app | Yes | None | By hand; close the game first |

Rules for A and B: the newest save wins, the save it replaces is backed up first, and a change on both sides since the
last sync is never overwritten. Playing on two devices at the same time loses one side's progress.

## B (recommended)

- **Choosing the folder:** a settings-menu entry opens `UIDocumentPickerViewController` for a folder, such as
  iCloud Drive › TOTK Saves, and keeps a security-scoped bookmark. This needs no iCloud entitlement, so the current
  profiles and a free Personal Team work. The Mac app is not sandboxed and reads the same folder directly
  (`~/Library/Mobile Documents/com~apple~CloudDocs/TOTK Saves`), or `TOTK_SAVE_SYNC_DIR`.
- **In the folder:** `current/` (the contents of `save/<uid>/`), `manifest.json` (device name, game version, time
  written, a counter that each write raises, and each file's size and SHA-256), `backups/<time>-<device>/`.
- **At start, before the save is mounted** (`init` in fs_host.c): read the manifest under `NSFileCoordinator`. If it
  is newer than the last sync this device made and the version matches, copy the local save to
  `<profile>/save-backups/<time>/`, then copy `current/` in. iCloud may hold placeholders not downloaded yet:
  `startDownloadingUbiquitousItemAtURL:` and wait a few seconds with a message, or start with the local save and
  say so.
- **After a save:** once `runtime_fs_save_busy()` is false after a commit, copy the save to a temporary folder beside
  `current/`, swap it in and write the manifest. Do the same when the app goes to the background (inside
  `beginBackgroundTaskWithExpirationHandler:`).
- **Both changed:** local changes after the last sync and a manifest counter that moved mean two devices played. Keep
  both and ask at the next start, showing each side's device and time.

## A (Mac as the hub)

- A LaunchAgent every 10 minutes, installed the way `games/totk/ios/tools/shader_contrib_watch.py install` installs
  its own.
- `xcrun devicectl list devices` for the devices in reach; `device info processes` to skip a device with the game
  running; `device info files` (`--domain-type appDataContainer --subdirectory Documents/save`) for modification
  times; `device copy from` / `copy to` for the files.
- A hub copy on the Mac (`~/Library/Application Support/MacNativeGames/TOTK/save-hub/`) keeps the newest save, so a
  device that comes back later gets it; the Mac's own profile is one more member.
