# Syncing saves between iPhone, iPad and Mac

Status as of 2026-10-22: implemented on branch `ios-settings-menu` (runtime/save_sync.m), scenario-tested on the Mac
and the nearby-device pass tried with an iPhone 15 Pro; not yet tested end to end through iCloud on the devices.
Copying by hand still works: [ios-settings.md, section 5](ios-settings.md#5-copying-saves-between-devices).

## Setting it up

1. In the Files app (or Finder), make a folder in iCloud Drive: **iCloud Drive › TOTK Saves**.
2. **Mac:** nothing to set. When that folder exists the game uses it (`TOTK_SAVE_SYNC_DIR=<folder>` picks another,
   `TOTK_SAVE_SYNC_DIR=0` turns it off).
3. **iPhone / iPad:** settings menu (⚙︎) › **Save sync** › **Choose a folder in iCloud Drive…**, pick TOTK Saves, then
   restart the game.
4. **A device on another Apple ID:** on a device that owns the folder, Files › TOTK Saves › Share › **Collaborate**,
   *Can make changes*, invite that Apple ID. On the other device, accept, then pick the folder from **Shared** in step 3.
   Its storage counts against the owner's iCloud.

The first device that starts with the folder empty uploads its save; every other device then loads it.

## When it syncs

Nothing runs while the game is closed: no agent, no timer.

| When | iPhone / iPad | Mac |
|---|---|---|
| The game starts | before the game thread starts (`syncThenStart`, ios/Sources/main.m), with "Syncing the save…" | in the launcher before `execv` (app/launcher.m) |
| A save is committed | a thread wakes on `commit()` (runtime/fs_host.c → `save_sync_note_commit`), waits until `runtime_fs_save_busy()` is false and uploads | the same, in the game |
| Quit / background | `sceneDidEnterBackground` uploads inside a background task | the window close waits for the save, then uploads |
| Nearby devices | — | once per game start, in the background: every iPhone or iPad on the cable or the same network with the game installed and not running is synced through `devicectl` (needs Xcode; `TOTK_SAVE_SYNC_NEARBY=0` turns it off) |

The download at start waits 20 s at most. If iCloud is slower, the game starts with the local save and the download is
cancelled before it changes anything; the next save then uploads (or is kept as a conflict, below).

## What is in the folder

| | |
|---|---|
| `manifest.json` | folder id, device, time, game version, a counter every upload raises, the save's digest and each file's size and SHA-256 |
| `current/` | the files of `save/<uid>/`: `slot_*`, `option.sav`, `album`, `storage` |
| `account.uid` | the first uploader's account id, taken by a device that has none yet |
| `backups/` | the last 5 replaced uploads |
| `conflicts/` | uploads that would have overwritten another device's newer save |

Each profile keeps `save-sync.json` (the folder id, counter and digest of its last sync) and `save-sync-backups/` (the
last 10 local saves a download replaced). `<uid>` differs per device; the files go into the local `<uid>` folder.

## Rules

- **Newest wins.** At start the folder's save is loaded when its counter is above this device's last sync and this
  device's save has not changed since then. The local save is backed up first.
- **Both changed** (two devices played since the last sync): nothing is overwritten. At start the game asks which save
  to play, naming the other device and its time; the other one stays as a backup. An upload that finds a newer
  upload from another device goes to `conflicts/` instead.
- **Incomplete upload:** a file whose SHA-256 does not match the manifest (iCloud still bringing it) replaces nothing.
- **Another game version** in the folder: not synced.
- **Another folder:** the state is tied to the folder id, so moving to a new folder starts over cleanly.
- Play on one device at a time. The nearby pass leaves a device with the game running alone.

## Notes from the research

- A folder picked with `UIDocumentPickerViewController` can be kept as a bookmark and opened at the next launch
  ([Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)).
  `.withSecurityScope` is macOS only; on iOS the bookmark is a plain (minimal) one and the resolved URL is opened with
  `startAccessingSecurityScopedResource`. A bookmark does not carry over to another device, so each device picks the
  folder once.
- A coordinated read (`NSFileCoordinator`) of a file iCloud has not downloaded yet downloads it; every read and write of
  the folder goes through it, on the Mac too (Optimize Mac Storage can leave files as placeholders).
- No iCloud entitlement is needed, so a free Personal Team works. An iCloud container (CloudKit or a ubiquity
  container) would need it on the App ID for every signer and the Mac app signed by the same team.
- Shortcuts automations (copy on app open / close) were not used: they run beside the game's own start, cannot make
  iCloud finish first and can overwrite a save.

## Testing

`save_sync_pull` / `save_sync_push` are plain functions over two folders. A scenario test (first upload, a device with
its own uid, a device without an account, conflicts both ways, forced choices, an incomplete upload, a cancelled
download, another game version, moving to a new folder) passed 24 of 24 checks on the Mac.
