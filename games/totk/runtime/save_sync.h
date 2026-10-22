#pragma once
#include <stddef.h>

/* Save sync through a shared folder (docs/ios-save-sync.md): the Mac, iPhone and iPad keep one copy of the save in a
   folder they all reach, normally in iCloud Drive (shared with another Apple ID when needed). Nothing runs while the game
   is closed: each device syncs when the game starts (save_sync_pull, before the save is mounted), after each save the
   game commits (save_sync_watch) and when it quits or goes to the background (save_sync_flush).

   The folder holds manifest.json (device, time, game version, a counter every upload raises, and each file's size and
   SHA-256), current/ (the files of save/<uid>/), account.uid (for a device that has none yet), backups/ (the last 5
   replaced uploads) and conflicts/ (uploads that would have overwritten another device's newer save). A profile keeps
   save-sync.json (the counter and digest of its last sync) and save-sync-backups/ (the last 10 local saves a download
   replaced). The newest save wins; a save changed on both sides since the last sync is never overwritten silently. */

enum { SAVE_SYNC_ERROR = -1, SAVE_SYNC_NOTHING = 0, SAVE_SYNC_PULLED, SAVE_SYNC_PUSHED, SAVE_SYNC_CONFLICT, SAVE_SYNC_SKIPPED };

typedef struct { char device[96], written[40], version[16]; long long counter; } save_sync_remote;

/* profile: the folder with account.uid and save/<uid>/ (TOTK_PROFILE_DIR); dir: the sync folder; device: a name for this
   device. force: in a conflict, take the folder's save (pull) or this device's (push). *cancel, when set before the
   local save is replaced, stops the pull without changing it (the game started without waiting). msg gets one line. */
int save_sync_pull(const char *profile, const char *dir, const char *device, int force, save_sync_remote *remote,
                   volatile int *cancel, char *msg, size_t n);
int save_sync_push(const char *profile, const char *dir, const char *device, int force, char *msg, size_t n);

/* In the game: a thread that uploads after each committed save, once the game is done writing (runtime_fs_save_busy). */
void save_sync_watch(const char *profile, const char *dir, const char *device);
/* Upload now if the save changed (quit, background); waits up to timeout_s for a save in progress. 0 if no sync is set. */
int save_sync_flush(double timeout_s);
/* runtime/fs_host.c: a save was committed. */
void save_sync_note_commit(void);

/* Mac: iPhones and iPads with the game, on the cable or the same network, synced with the folder through devicectl
   (Xcode) once, in the background; a device with the game running is left alone. */
void save_sync_nearby_start(const char *dir);
