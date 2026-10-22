/* Save sync through a shared folder (save_sync.h, docs/ios-save-sync.md). Shared by the Mac launcher (pull before the
   game starts), the game on the Mac and iOS (upload after each save, on quit and in the background) and the Mac's
   nearby-device pass (devicectl). Files in iCloud Drive are read and written under NSFileCoordinator, which also
   downloads a file iCloud has not brought to this device yet. */
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "game_version.h"
#include "save_sync.h"

#define LOG(...) fprintf(stderr, "[save-sync] " __VA_ARGS__)
enum { KEEP_REMOTE_BACKUPS = 5, KEEP_LOCAL_BACKUPS = 10 };

static void say(char *msg, size_t n, NSString *text) { if (msg && n) snprintf(msg, n, "%s", text.UTF8String); LOG("%s\n", text.UTF8String); }
static NSString *stamp(void) {
    NSDateFormatter *f = [NSDateFormatter new]; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyyMMdd-HHmmss"; return [f stringFromDate:NSDate.date];
}
/* <parent>/<stamp>-<tag>, with -2, -3 ... when two backups land in the same second. */
static NSString *unique_child(NSString *parent, NSString *tag) {
    NSString *base = [parent stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", stamp(), tag]], *p = base;
    for (int i = 2; [NSFileManager.defaultManager fileExistsAtPath:p]; i++) p = [base stringByAppendingFormat:@"-%d", i];
    return p;
}
static NSString *now_iso(void) { return [[NSISO8601DateFormatter new] stringFromDate:NSDate.date]; }
static NSString *safe_name(NSString *s) {
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    return [[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"-"];
}
static NSString *sha256_hex(NSData *d) {
    unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *s = [NSMutableString string]; for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", h[i]];
    return s;
}

/* The save folder of a profile: save/<uid>, uid from account.uid (runtime/account.c: lo then hi; fs_host.c prints hi lo). */
static NSString *uid_folder(NSString *profile) {
    NSData *d = [NSData dataWithContentsOfFile:[profile stringByAppendingPathComponent:@"account.uid"]];
    if (d.length != 16) return nil;
    uint64_t v[2]; memcpy(v, d.bytes, 16);
    return [profile stringByAppendingPathComponent:[NSString stringWithFormat:@"save/%016llx%016llx", (unsigned long long)v[1], (unsigned long long)v[0]]];
}
/* path -> {size, sha256} for every regular file below root (hidden files skipped). */
static NSDictionary<NSString *, NSDictionary *> *list_files(NSString *root) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary]; NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *rel in [fm enumeratorAtPath:root]) {
        if ([rel.lastPathComponent hasPrefix:@"."]) continue;
        NSString *p = [root stringByAppendingPathComponent:rel]; BOOL dir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&dir] || dir) continue;
        NSData *d = [NSData dataWithContentsOfFile:p]; if (!d) continue;
        out[rel] = @{@"size": @(d.length), @"sha256": sha256_hex(d)};
    }
    return out;
}
static NSString *digest_of(NSDictionary<NSString *, NSDictionary *> *files) {
    if (!files.count) return @"";
    NSMutableString *s = [NSMutableString string];
    for (NSString *k in [files.allKeys sortedArrayUsingSelector:@selector(compare:)]) [s appendFormat:@"%@\t%@\t%@\n", k, files[k][@"size"], files[k][@"sha256"]];
    return sha256_hex([s dataUsingEncoding:NSUTF8StringEncoding]);
}
static NSDictionary *read_json(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path]; if (!d) return nil;
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; return [j isKindOfClass:NSDictionary.class] ? j : nil;
}
static BOOL write_json(NSString *path, NSDictionary *j) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    return d && [d writeToFile:path atomically:YES];
}
static void prune(NSString *dir, NSUInteger keep) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *names = [[fm contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i + keep < names.count; i++) [fm removeItemAtPath:[dir stringByAppendingPathComponent:names[i]] error:nil];
}
/* A coordinated read of one file of the sync folder (downloads it from iCloud when needed). */
static NSData *coordinated_read(NSString *path) {
    __block NSData *d = nil; NSError *e = nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:[NSURL fileURLWithPath:path] options:0 error:&e
        byAccessor:^(NSURL *u) { d = [NSData dataWithContentsOfURL:u]; }];
    return d;
}
static NSDictionary *read_manifest(NSString *dir) {
    NSData *d = coordinated_read([dir stringByAppendingPathComponent:@"manifest.json"]); if (!d) return nil;
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; return [j isKindOfClass:NSDictionary.class] ? j : nil;
}
static void fill_remote(save_sync_remote *r, NSDictionary *m) {
    if (!r) return; memset(r, 0, sizeof *r);
    snprintf(r->device, sizeof r->device, "%s", [m[@"device"] description].UTF8String ?: "");
    snprintf(r->written, sizeof r->written, "%s", [m[@"written"] description].UTF8String ?: "");
    snprintf(r->version, sizeof r->version, "%s", [m[@"game_version"] description].UTF8String ?: "");
    r->counter = [m[@"counter"] longLongValue];
}
static NSString *state_path(NSString *profile) { return [profile stringByAppendingPathComponent:@"save-sync.json"]; }
static void write_state(NSString *profile, long long counter, NSString *digest, NSString *folder) {
    write_json(state_path(profile), @{@"counter": @(counter), @"digest": digest ?: @"", @"folder": folder ?: @"", @"synced": now_iso()});
}
/* The profile's last sync, only if it was with this folder (the manifest's id): a profile moved to another folder
   starts over instead of comparing counters of two folders. */
static NSDictionary *read_state(NSString *profile, NSDictionary *manifest) {
    NSDictionary *s = read_json(state_path(profile));
    return s && manifest && [s[@"folder"] isEqual:manifest[@"folder"]] ? s : nil;
}

int save_sync_pull(const char *profile_c, const char *dir_c, const char *device_c, int force, save_sync_remote *remote,
                   volatile int *cancel, char *msg, size_t n) {
    @autoreleasepool {
        NSString *profile = @(profile_c), *dir = @(dir_c); NSFileManager *fm = NSFileManager.defaultManager;
        NSDictionary *m = read_manifest(dir);
        if (!m) {
            if (!list_files(uid_folder(profile) ?: @"/nonexistent").count) { say(msg, n, @"sync folder is empty and this device has no save yet"); return SAVE_SYNC_NOTHING; }
            return save_sync_push(profile_c, dir_c, device_c, 0, msg, n);   // the first device fills the folder
        }
        fill_remote(remote, m);
        if (![m[@"game_version"] isEqual:@TOTK_GAME_VERSION]) {
            say(msg, n, [NSString stringWithFormat:@"the folder holds a %@ save, this game is %s: not synced", m[@"game_version"], TOTK_GAME_VERSION]);
            return SAVE_SYNC_SKIPPED;
        }
        /* A device with no account yet takes the folder's, so its save lands where the game will look. */
        NSString *uidPath = [profile stringByAppendingPathComponent:@"account.uid"];
        if (![fm fileExistsAtPath:uidPath]) {
            NSData *u = coordinated_read([dir stringByAppendingPathComponent:@"account.uid"]);
            if (u.length == 16) { [fm createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:nil error:nil]; [u writeToFile:uidPath atomically:YES]; }
        }
        NSString *local = uid_folder(profile);
        if (!local) { say(msg, n, @"no account.uid in the profile or the folder"); return SAVE_SYNC_ERROR; }
        NSString *localDigest = digest_of(list_files(local)), *remoteDigest = m[@"digest"];
        NSDictionary *state = read_state(profile, m);
        long long counter = [m[@"counter"] longLongValue], synced = [state[@"counter"] longLongValue];
        if ([remoteDigest isEqual:localDigest]) { write_state(profile, counter, localDigest, m[@"folder"]); say(msg, n, @"save already matches the folder"); return SAVE_SYNC_NOTHING; }
        if (counter <= synced && !force) { say(msg, n, @"this device's save is the newer one"); return SAVE_SYNC_NOTHING; }
        BOOL changed = state ? ![state[@"digest"] isEqual:localDigest] : localDigest.length > 0;
        if (changed && !force) {
            say(msg, n, [NSString stringWithFormat:@"conflict: the folder has a save from %@ (%@) and this device's save changed too", m[@"device"], m[@"written"]]);
            return SAVE_SYNC_CONFLICT;
        }
        /* Download into a staging folder and check every file against the manifest: an upload iCloud has not finished
           bringing here does not replace anything. */
        NSString *incoming = [profile stringByAppendingPathComponent:@"save-sync-incoming"];
        [fm removeItemAtPath:incoming error:nil];
        NSDictionary *files = m[@"files"];
        for (NSString *rel in files) {
            if (cancel && *cancel) { [fm removeItemAtPath:incoming error:nil]; say(msg, n, @"cancelled"); return SAVE_SYNC_SKIPPED; }
            NSData *d = coordinated_read([[dir stringByAppendingPathComponent:@"current"] stringByAppendingPathComponent:rel]);
            if (!d || ![sha256_hex(d) isEqual:files[rel][@"sha256"]]) {
                [fm removeItemAtPath:incoming error:nil];
                say(msg, n, [NSString stringWithFormat:@"%@ is not complete in the folder yet (iCloud still syncing?): not replaced", rel]);
                return SAVE_SYNC_SKIPPED;
            }
            NSString *to = [incoming stringByAppendingPathComponent:rel];
            [fm createDirectoryAtPath:to.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            if (![d writeToFile:to atomically:YES]) { [fm removeItemAtPath:incoming error:nil]; say(msg, n, @"cannot write the downloaded save"); return SAVE_SYNC_ERROR; }
        }
        if (cancel && *cancel) { [fm removeItemAtPath:incoming error:nil]; say(msg, n, @"cancelled"); return SAVE_SYNC_SKIPPED; }
        NSString *backups = [profile stringByAppendingPathComponent:@"save-sync-backups"];
        [fm createDirectoryAtPath:backups withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm fileExistsAtPath:local] && ![fm moveItemAtPath:local toPath:unique_child(backups, @"before-sync") error:nil]) {
            [fm removeItemAtPath:incoming error:nil]; say(msg, n, @"cannot back up the local save: not replaced"); return SAVE_SYNC_ERROR;
        }
        prune(backups, KEEP_LOCAL_BACKUPS);
        [fm createDirectoryAtPath:local.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![fm moveItemAtPath:incoming toPath:local error:nil]) { say(msg, n, @"cannot move the downloaded save in place"); return SAVE_SYNC_ERROR; }
        write_state(profile, counter, remoteDigest, m[@"folder"]);
        say(msg, n, [NSString stringWithFormat:@"loaded the save from %@ (%@)", m[@"device"], m[@"written"]]);
        return SAVE_SYNC_PULLED;
    }
}

int save_sync_push(const char *profile_c, const char *dir_c, const char *device_c, int force, char *msg, size_t n) {
    @autoreleasepool {
        NSString *profile = @(profile_c), *dir = @(dir_c), *device = @(device_c); NSFileManager *fm = NSFileManager.defaultManager;
        NSString *local = uid_folder(profile);
        NSDictionary *files = local ? list_files(local) : @{};
        if (!files.count) { say(msg, n, @"no local save to upload"); return SAVE_SYNC_NOTHING; }
        NSString *digest = digest_of(files);
        /* Quick check without coordination (the watcher calls this after every save): unchanged since the last sync with
           this folder. */
        NSDictionary *last = read_state(profile, read_json([dir stringByAppendingPathComponent:@"manifest.json"]));
        if (!force && [last[@"digest"] isEqual:digest]) return SAVE_SYNC_NOTHING;
        __block int result = SAVE_SYNC_ERROR; __block NSString *text = @"cannot write to the sync folder";
        NSError *e = nil;
        [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateWritingItemAtURL:[NSURL fileURLWithPath:dir] options:0 error:&e
            byAccessor:^(NSURL *u) {
            (void)u;
            NSDictionary *m = read_json([dir stringByAppendingPathComponent:@"manifest.json"]), *state = read_state(profile, m);
            NSString *folder = m[@"folder"] ?: NSUUID.UUID.UUIDString;   // the first upload names the folder
            long long remote = [m[@"counter"] longLongValue], synced = [state[@"counter"] longLongValue];
            if (m && [m[@"digest"] isEqual:digest]) { write_state(profile, remote, digest, folder); result = SAVE_SYNC_NOTHING; text = @"the folder already has this save"; return; }
            if (m && remote > synced && !force) {
                /* Another device uploaded since this one last synced: keep this save beside it, overwrite nothing. */
                NSString *c = unique_child([dir stringByAppendingPathComponent:@"conflicts"], safe_name(device));
                [fm createDirectoryAtPath:c.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                [fm copyItemAtPath:local toPath:c error:nil];
                write_json([c stringByAppendingPathComponent:@".conflict.json"], @{@"device": device, @"written": now_iso(), @"digest": digest});
                result = SAVE_SYNC_CONFLICT;
                text = [NSString stringWithFormat:@"conflict: %@ uploaded a newer save; this one is kept in conflicts/ and loaded at the next start only if chosen", m[@"device"]];
                return;
            }
            NSString *staging = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@".staging-%@-%d", safe_name(device), getpid()]];
            [fm removeItemAtPath:staging error:nil];
            if (![fm copyItemAtPath:local toPath:staging error:nil]) return;
            NSString *current = [dir stringByAppendingPathComponent:@"current"];
            if ([fm fileExistsAtPath:current]) {
                NSString *b = [dir stringByAppendingPathComponent:@"backups"];
                [fm createDirectoryAtPath:b withIntermediateDirectories:YES attributes:nil error:nil];
                if (![fm moveItemAtPath:current toPath:unique_child(b, safe_name([m[@"device"] description] ?: @"unknown")) error:nil]) { [fm removeItemAtPath:staging error:nil]; return; }
                prune(b, KEEP_REMOTE_BACKUPS);
            }
            if (![fm moveItemAtPath:staging toPath:current error:nil]) return;
            NSString *uid = [dir stringByAppendingPathComponent:@"account.uid"];
            if (![fm fileExistsAtPath:uid]) [fm copyItemAtPath:[profile stringByAppendingPathComponent:@"account.uid"] toPath:uid error:nil];
            long long next = MAX(remote, synced) + 1;
            /* The manifest last: a reader that sees it finds current/ complete (or, while iCloud syncs, checks the hashes). */
            if (!write_json([dir stringByAppendingPathComponent:@"manifest.json"], @{@"format": @1, @"folder": folder, @"device": device, @"written": now_iso(),
                    @"game_version": @TOTK_GAME_VERSION, @"counter": @(next), @"digest": digest, @"files": files})) return;
            write_state(profile, next, digest, folder);
            result = SAVE_SYNC_PUSHED; text = [NSString stringWithFormat:@"uploaded the save (%lu files, upload %lld)", (unsigned long)files.count, next];
        }];
        if (e) text = [NSString stringWithFormat:@"cannot write to the sync folder: %@", e.localizedDescription];
        say(msg, n, text);
        return result;
    }
}

/* ---------- in the game: upload after each committed save ---------- */
/* runtime/fs_host.c's; the launcher and tests link without it. */
__attribute__((weak)) int runtime_fs_save_busy(void) { return 0; }
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER, g_push_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static unsigned long g_commits;
static char *g_profile, *g_dir, *g_device;
static int save_busy(void) { return runtime_fs_save_busy(); }
void save_sync_note_commit(void) { pthread_mutex_lock(&g_mu); g_commits++; pthread_cond_signal(&g_cv); pthread_mutex_unlock(&g_mu); }
static int push_now(void) {
    pthread_mutex_lock(&g_push_mu); char msg[256];
    int r = save_sync_push(g_profile, g_dir, g_device, 0, msg, sizeof msg);
    pthread_mutex_unlock(&g_push_mu); return r;
}
static void *watch(void *arg) {
    (void)arg; pthread_setname_np("totk-save-sync"); unsigned long seen = 0;
    for (;;) {
        pthread_mutex_lock(&g_mu); while (g_commits == seen) pthread_cond_wait(&g_cv, &g_mu); seen = g_commits; pthread_mutex_unlock(&g_mu);
        /* A save is several files committed one after another: wait until the game has been quiet for its 3 s. */
        for (int i = 0; i < 600 && save_busy(); i++) usleep(100000);
        pthread_mutex_lock(&g_mu); int more = g_commits != seen; pthread_mutex_unlock(&g_mu);
        if (!more) push_now();
    }
    return NULL;
}
void save_sync_watch(const char *profile, const char *dir, const char *device) {
    if (g_dir) return;
    g_profile = strdup(profile); g_dir = strdup(dir); g_device = strdup(device);
    pthread_t t; if (!pthread_create(&t, NULL, watch, NULL)) pthread_detach(t);
    LOG("uploads after each save to %s\n", dir);
}
int save_sync_flush(double timeout_s) {
    if (!g_dir) return 0;
    for (double t = 0; t < timeout_s && save_busy(); t += 0.1) usleep(100000);
    return push_now();
}

#if TARGET_OS_OSX
/* ---------- Mac: nearby iPhones and iPads (devicectl) ---------- */
static NSDictionary *devicectl(NSArray<NSString *> *args) {
    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"totk-devicectl-%d-%u.json", getpid(), arc4random()]];
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    t.arguments = [[@[@"devicectl"] arrayByAddingObjectsFromArray:args] arrayByAddingObjectsFromArray:@[@"--quiet", @"--json-output", out]];
    t.standardOutput = NSFileHandle.fileHandleWithNullDevice; t.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:nil]) return nil;
    for (int i = 0; i < 1200 && t.running; i++) usleep(50000);   // a locked or sleeping device can stall a call: 60 s at most
    if (t.running) { [t terminate]; return nil; }
    NSDictionary *j = t.terminationStatus == 0 ? read_json(out) : nil;
    [NSFileManager.defaultManager removeItemAtPath:out error:nil];
    return j[@"result"];
}
static NSArray *container(NSString *dev, NSString *bundle, NSString *verb) {
    return @[@"device", @"copy", verb, @"--device", dev, @"--domain-type", @"appDataContainer", @"--domain-identifier", bundle];
}
static BOOL game_running(NSString *dev, NSString *appPath) {
    NSDictionary *r = devicectl(@[@"device", @"info", @"processes", @"--device", dev]);
    if (!r) return YES;   // cannot tell: leave the device alone
    for (NSDictionary *p in r[@"runningProcesses"]) if ([[p[@"executable"] description] containsString:appPath]) return YES;
    return NO;
}
static void sync_device(NSString *dir, NSString *dev, NSString *name) {
    NSDictionary *apps = devicectl(@[@"device", @"info", @"apps", @"--device", dev]);
    NSString *bundle = nil, *appPath = nil;
    for (NSDictionary *a in apps[@"apps"]) if ([[a[@"bundleIdentifier"] description] hasSuffix:@".totk"]) {
        bundle = a[@"bundleIdentifier"]; appPath = [NSURL URLWithString:a[@"url"]].path; break; }
    if (!bundle) return;
    if (game_running(dev, appPath)) { LOG("%s: the game is running there, left alone\n", name.UTF8String); return; }
    NSDictionary *listing = devicectl(@[@"device", @"info", @"files", @"--device", dev, @"--domain-type", @"appDataContainer",
                                        @"--domain-identifier", bundle, @"--subdirectory", @"Documents/save"]);
    if (!listing) return;
    /* A copy of the device's profile here: account.uid, save-sync.json and save/<uid>/, then the same pull and push as
       on the device itself. */
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"totk-save-sync-" stringByAppendingString:safe_name(dev)]];
    [fm removeItemAtPath:tmp error:nil]; [fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSString *> *rels = [NSMutableArray array];
    for (NSDictionary *f in listing[@"files"]) {
        NSString *rel = f[@"relativePath"];
        if ([f[@"resources"][@"isDirectory"] boolValue]) continue;
        if ([rel isEqual:@"account.uid"] || [rel isEqual:@"save-sync.json"] || [rel hasPrefix:@"save/"]) [rels addObject:rel];
    }
    for (NSString *rel in rels) {
        NSString *to = [tmp stringByAppendingPathComponent:rel];
        [fm createDirectoryAtPath:to.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (!devicectl([container(dev, bundle, @"from") arrayByAddingObjectsFromArray:@[@"--source", [@"Documents/save/" stringByAppendingString:rel], @"--destination", to]])) {
            LOG("%s: cannot copy %s from the device\n", name.UTF8String, rel.UTF8String); return; }
    }
    if (![fm fileExistsAtPath:[tmp stringByAppendingPathComponent:@"account.uid"]]) return;   // the game never started there
    char msg[256];
    int pushed = save_sync_push(tmp.fileSystemRepresentation, dir.fileSystemRepresentation, name.UTF8String, 0, msg, sizeof msg);
    LOG("%s: %s\n", name.UTF8String, msg);
    int pulled = save_sync_pull(tmp.fileSystemRepresentation, dir.fileSystemRepresentation, name.UTF8String, 0, NULL, NULL, msg, sizeof msg);
    LOG("%s: %s\n", name.UTF8String, msg);
    NSMutableArray<NSString *> *back = [NSMutableArray array];
    if (pulled == SAVE_SYNC_PULLED) {
        NSString *local = uid_folder(tmp);
        for (NSString *rel in [fm enumeratorAtPath:local]) { BOOL d = NO; [fm fileExistsAtPath:[local stringByAppendingPathComponent:rel] isDirectory:&d];
            if (!d && ![rel.lastPathComponent hasPrefix:@"."]) [back addObject:[[local substringFromIndex:tmp.length + 1] stringByAppendingPathComponent:rel]]; }
    }
    if ((pushed == SAVE_SYNC_PUSHED || pulled == SAVE_SYNC_PULLED || pulled == SAVE_SYNC_NOTHING) &&
        [fm fileExistsAtPath:[tmp stringByAppendingPathComponent:@"save-sync.json"]]) [back addObject:@"save-sync.json"];
    if (pulled == SAVE_SYNC_PULLED && game_running(dev, appPath)) { LOG("%s: the game started meanwhile, not written\n", name.UTF8String); return; }
    for (NSString *rel in back)
        if (!devicectl([container(dev, bundle, @"to") arrayByAddingObjectsFromArray:@[@"--source", [tmp stringByAppendingPathComponent:rel], @"--destination", [@"Documents/save/" stringByAppendingString:rel]]]))
            LOG("%s: cannot write %s to the device\n", name.UTF8String, rel.UTF8String);
    if (pulled == SAVE_SYNC_PULLED) LOG("%s: save written to the device\n", name.UTF8String);
    [fm removeItemAtPath:tmp error:nil];
}
static void *nearby(void *arg) {
    @autoreleasepool {
        NSString *dir = @((char *)arg); free(arg); pthread_setname_np("totk-save-nearby");
        if (access("/usr/bin/xcrun", X_OK) || !devicectl(@[@"list", @"devices"])) { LOG("nearby devices: devicectl not available (Xcode)\n"); return NULL; }
        NSDictionary *r = devicectl(@[@"list", @"devices"]);
        for (NSDictionary *d in r[@"devices"]) {
            NSDictionary *hw = d[@"hardwareProperties"], *conn = d[@"connectionProperties"];
            NSString *type = hw[@"deviceType"], *transport = conn[@"transportType"];
            if (!([type isEqual:@"iPhone"] || [type isEqual:@"iPad"]) || ![conn[@"pairingState"] isEqual:@"paired"]) continue;
            if (!([transport isEqual:@"wired"] || [transport isEqual:@"localNetwork"])) continue;   // sameMachine: a simulator
            NSString *name = d[@"deviceProperties"][@"name"] ?: type;
            LOG("nearby: %s\n", name.UTF8String);
            sync_device(dir, d[@"identifier"], name);
        }
        LOG("nearby devices done\n");
    }
    return NULL;
}
void save_sync_nearby_start(const char *dir) { pthread_t t; if (!pthread_create(&t, NULL, nearby, strdup(dir))) pthread_detach(t); }
#else
void save_sync_nearby_start(const char *dir) { (void)dir; }
#endif
