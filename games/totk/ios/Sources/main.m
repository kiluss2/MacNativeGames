#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <QuartzCore/CAMetalLayer.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>
#include "runtime.h"
#include "dmsh_chain.h"
#import "touch_pad.h"

int totk_host_main(int argc, char **argv);
void runtime_ios_attach_layer(CAMetalLayer *layer, UIView *host);
static char *host_argv[3];
static NSString *g_no_game_data;   // set when there is no RomFS image to play from (didFinishLaunching)
static void *run_host(void *unused) { (void)unused; return (void *)(intptr_t)totk_host_main(3, host_argv); }
/* The desktop keyboard-overlay shortcut has no counterpart on iOS. */
void runtime_shortcut_help_toggle(void) {}
/* The settings menu (the gear at the top centre), kept in the user defaults:
   - frame-rate cap (gfx/nvn/hle_nvn.c; 0 = none): a 120 Hz iPad otherwise renders 120 frames a second and runs hot.
     Applied at start as TOTK_FPS_CAP, at run time directly;
   - resolution: the game's output canvas, 16:9, 720p (the handheld canvas) up to 1080p (the docked one, which the
     game's heaps are sized for). TOTK_OUTPUT_RES and the drawable height (TOTK_IOS_DRAWABLE_H) at start; needs code
     exported with the output patch (TOTK_IOS_OUTPUT_MAX=1920x1080 for the build, runtime/game_patches_v143.c);
   - render scale: the 3D scene as a share of the resolution on each axis, TOTK_RENDER_RES at start (needs the
     render-resolution patch: TOTK_RENDER_RES set for the build). Both take effect at the next launch;
   - overlay (gfx/nvn/fps_overlay.c): off, the FPS alone, FPS with the picture and render sizes, or also the load line
     (CPU, GPU, memory). Applied at start and at run time. */
void nvn_set_fps_cap(int fps);
void fps_overlay_set_hud_mode(int mode);   /* gfx/nvn/fps_overlay.h: HUD_MODE_OFF 0, ALL 1, MINIMAL 2, FPS 3 */
enum { kHudOff = 0, kHudAll = 1, kHudSizes = 2, kHudFps = 3 };
static NSString *const kFpsCapKey = @"TOTKFpsCap", *const kOutputHeightKey = @"TOTKOutputHeight", *const kRenderScaleKey = @"TOTKRenderScale",
                *const kHudKey = @"TOTKHud";
static int saved_setting(NSString *key, int fallback) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? v.intValue : fallback;
}
static int saved_fps_cap(void) { return saved_setting(kFpsCapKey, 60); }
static int saved_output_height(void) { return saved_setting(kOutputHeightKey, 720); }
static int saved_render_scale(void) { return saved_setting(kRenderScaleKey, 100); }   /* percent; 67 means two thirds */
static int saved_hud(void) { return saved_setting(kHudKey, kHudSizes); }
static int width_16_9(int h) { return (h * 16 + 8) / 9; }
/* The scene size for an output height and a render scale, rounded to even pixels (67% is exactly 2/3: 1080p -> 720p). */
static void render_size(int out_h, int pct, int *w, int *h) {
    int num = pct == 67 ? 2 : pct, den = pct == 67 ? 3 : 100;
    *h = (out_h * num / den + 1) & ~1; *w = (width_16_9(out_h) * num / den + 1) & ~1;
}

@interface TOTKMetalView : UIView @end
@implementation TOTKMetalView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

@interface TOTKGameController : UIViewController @property(nonatomic,strong) TOTKMetalView *gameView; @end
@implementation TOTKGameController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.gameView = [[TOTKMetalView alloc] initWithFrame:self.view.bounds];
    self.gameView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.gameView];
    runtime_ios_attach_layer((CAMetalLayer *)self.gameView.layer, self.gameView);
    TOTKTouchPad *pad=[[TOTKTouchPad alloc] initWithFrame:self.view.bounds];pad.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.view addSubview:pad];
    // Settings: a faint gear at the top centre, between − and +, above the touch pad so its touches never reach the game.
    UIButton *gear = [UIButton buttonWithType:UIButtonTypeSystem];
    [gear setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
    gear.tintColor = [UIColor colorWithWhite:1 alpha:.32]; gear.translatesAutoresizingMaskIntoConstraints = NO;
    __weak TOTKGameController *weakSelf = self;
    gear.menu = [UIMenu menuWithChildren:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^done)(NSArray<UIMenuElement *> *)) {
        TOTKGameController *me = weakSelf; done(me ? [me settingsMenu] : @[]);   // rebuilt on every open, so the checkmarks are current
    }]]];
    gear.showsMenuAsPrimaryAction = YES;
    [self.view addSubview:gear];
    [NSLayoutConstraint activateConstraints:@[[gear.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [gear.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        [gear.widthAnchor constraintEqualToConstant:44], [gear.heightAnchor constraintEqualToConstant:44]]];
}
/* One submenu: a checkmarked choice among values, stored under key; changed runs after the new value is saved. info, when
   given, adds an "About" item below the choices that shows the explanation. */
static UIMenu *choice_menu(NSString *title, NSString *subtitle, NSString *key, int current, NSArray<NSNumber *> *values,
                           NSArray<NSString *> *labels, void (^changed)(int), void (^info)(void)) {
    NSMutableArray<UIAction *> *items = [NSMutableArray array];
    for (NSUInteger i = 0; i < values.count; i++) {
        int v = values[i].intValue;
        UIAction *a = [UIAction actionWithTitle:labels[i] image:nil identifier:nil handler:^(UIAction *action) {
            (void)action; [NSUserDefaults.standardUserDefaults setInteger:v forKey:key]; if (changed) changed(v);
        }];
        a.state = v == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:a];
    }
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray arrayWithObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil
                                                                                  options:UIMenuOptionsDisplayInline children:items]];
    if (info) [children addObject:[UIAction actionWithTitle:@"About this setting" image:[UIImage systemImageNamed:@"info.circle"]
                                                 identifier:nil handler:^(UIAction *action) { (void)action; info(); }]];
    UIMenu *m = [UIMenu menuWithTitle:title image:nil identifier:nil options:0 children:children];
    m.subtitle = subtitle;
    return m;
}
- (NSArray<UIMenuElement *> *)settingsMenu {
    int fps = saved_fps_cap(), out = saved_output_height(), pct = saved_render_scale(), hud = saved_hud(), rw, rh;
    render_size(out, pct, &rw, &rh);
    NSMutableArray<NSString *> *scaleLabels = [NSMutableArray array];
    for (NSNumber *p in @[@50, @67, @75, @100]) { int w, h; render_size(out, p.intValue, &w, &h); [scaleLabels addObject:[NSString stringWithFormat:@"%@%% (%dx%d)", p, w, h]]; }
    __weak TOTKGameController *weakSelf = self;
    void (^restart)(int) = ^(int v) { (void)v; [weakSelf askRestart]; };
    return @[
        choice_menu(@"Frame rate limit", fps ? [NSString stringWithFormat:@"%d FPS", fps] : @"Unlimited", kFpsCapKey, fps,
                    @[@30, @40, @60, @0], @[@"30 FPS", @"40 FPS", @"60 FPS", @"Unlimited"], ^(int v) { nvn_set_fps_cap(v); },
                    ^{ [weakSelf explain:@"Frame rate limit" text:@"The most frames the game draws each second. This iPad's screen shows up to 120, so without a "
                        "limit the game renders 120 and the GPU never rests. 60 is smooth and much cooler; 40 and 30 are cooler still and save battery. "
                        "The game runs at the right speed at every limit. Takes effect at once."]; }),
        choice_menu(@"Resolution", [NSString stringWithFormat:@"%dx%d, next launch", width_16_9(out), out], kOutputHeightKey, out,
                    @[@720, @900, @1080], @[@"720p (1280x720, Switch handheld)", @"900p (1600x900)", @"1080p (1920x1080, Switch docked)"], restart,
                    ^{ [weakSelf explain:@"Resolution" text:@"The size of the finished picture: the 3D scene with the hearts, map, text and menus drawn on "
                        "top. A higher resolution makes text and menus sharper and the whole picture clearer. The screen then scales it to fit. "
                        "720p is what the Switch shows in handheld mode, 1080p what it shows on a TV. Takes effect the next time the game starts."]; }),
        choice_menu(@"Render scale", [NSString stringWithFormat:@"%d%% (%dx%d), next launch", pct, rw, rh], kRenderScaleKey, pct,
                    @[@50, @67, @75, @100], scaleLabels, restart,
                    ^{ [weakSelf explain:@"Render scale" text:@"How big the 3D world (land, Link, enemies, effects) is drawn, as a share of the resolution "
                        "on each side; the hearts, map and text always use the full resolution. This is where most of the GPU work goes: 67% draws "
                        "less than half the pixels of 100% (1080p at 67% draws the world at 720p), so the iPad stays cooler, while the 3D looks a "
                        "little softer. Takes effect the next time the game starts."]; }),
        choice_menu(@"Performance overlay", @[@"Off", @"FPS + resolution + load", @"FPS + resolution", @"FPS"][hud % 4], kHudKey, hud,
                    @[@(kHudOff), @(kHudFps), @(kHudSizes), @(kHudAll)], @[@"Off", @"FPS", @"FPS + resolution", @"FPS + resolution + CPU, GPU, RAM"],
                    ^(int v) { fps_overlay_set_hud_mode(v); },
                    ^{ [weakSelf explain:@"Performance overlay" text:@"Numbers in the corners of the picture. FPS: frames drawn each second. "
                        "Resolution: the picture size, and the 3D scene size after \"render\" when it differs. Load (bottom right): the average "
                        "use of the performance (P) and efficiency (E) CPU cores, the busiest thread (T), the GPU time the game uses, and the memory "
                        "the game holds with what iOS still allows it (\"left\"); iOS closes the game when that reaches zero."]; }),
    ];
}
- (void)explain:(NSString *)title text:(NSString *)text {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)askRestart {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Restart to apply"
        message:@"Resolution and render scale change when the game starts again. Save your game before quitting." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Quit now" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { (void)x; exit(0); }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL started; if (started) return; started = YES;
    if (g_no_game_data) {
        UILabel *say = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        say.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        say.text = g_no_game_data; say.textColor = UIColor.whiteColor; say.numberOfLines = 0; say.textAlignment = NSTextAlignmentCenter;
        [self.view addSubview:say];
        return;
    }
    /* Playback category (PR #97): plays with the ring / silent switch off and routes to the speaker. Without an active
       session the game's CoreAudio output stays on a null sink on iOS 27 ("no device sink in use"); activating it in
       didFinishLaunching blocked the main thread before the log file was opened. Interruptions: audio_observe. */
    AVAudioSession *audio = AVAudioSession.sharedInstance;
    NSError *catErr = nil, *actErr = nil;
    [audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&catErr];
    BOOL activated = [audio setActive:YES error:&actErr];
    fprintf(stderr, "[totk-audio] audio session category=%s active=%d route=%s err=%s%s\n",
            audio.category.UTF8String ?: "?", (int)activated, audio.currentRoute.outputs.firstObject.portType.UTF8String ?: "?",
            catErr ? catErr.localizedDescription.UTF8String : "none", actErr ? actErr.localizedDescription.UTF8String : "");
    pthread_attr_t attr; pthread_attr_init(&attr); pthread_attr_setstacksize(&attr, 64u << 20);
    pthread_t thread; pthread_create(&thread, &attr, run_host, NULL);
    pthread_detach(thread); pthread_attr_destroy(&attr);
}
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

/* iOS 27 ends apps linked against its SDK that keep the window in the app delegate (UIKit traps in
   _UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption at launch), so the window belongs to a window scene. */
@interface TOTKSceneDelegate : UIResponder <UIWindowSceneDelegate> @property(nonatomic,strong) UIWindow *window; @end
@implementation TOTKSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [TOTKGameController new]; [self.window makeKeyAndVisible];
}
@end

/* Game audio after interruptions (from nxnative b301431). A call, Siri or an alarm takes the audio session and the
   system stops the game's output unit; a media services reset invalidates it. Nothing started it again, so the game
   stayed silent. When an interruption ends the session is made active again and the output started
   (runtime_audio_output_restart); a reset rebuilds the output. Becoming active does the same, for an interruption
   whose "ended" never came. Becoming active also turns the idle timer off again. */
static BOOL g_audio_interrupted;
static void audio_resume(int recreate, const char *why) {
    NSError *err = nil;
    if (![AVAudioSession.sharedInstance setActive:YES error:&err]) fprintf(stderr,"[totk-audio] audio session not active again (%s): %s\n",why,err.localizedDescription.UTF8String);
    g_audio_interrupted = NO; runtime_audio_output_restart(recreate);
}
static void audio_observe(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter; NSOperationQueue *main = NSOperationQueue.mainQueue;
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        fprintf(stderr,"[totk-audio] audio session interruption %s\n",type == AVAudioSessionInterruptionTypeBegan ? "began" : "ended");
        if (type == AVAudioSessionInterruptionTypeBegan) g_audio_interrupted = YES; else audio_resume(0,"interruption ended");
    }];
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        (void)n; fprintf(stderr,"[totk-audio] media services were reset\n"); audio_resume(1,"media services reset");
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        (void)n; UIApplication.sharedApplication.idleTimerDisabled = YES;
        if (g_audio_interrupted) audio_resume(0,"became active during an interruption");
    }];
}

@interface TOTKApp : UIResponder <UIApplicationDelegate> @end
@implementation TOTKApp
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)application; (void)options;
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    c.delegateClass = TOTKSceneDelegate.class; return c;
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)options;
    // Controller input does not reset the idle timer; auto-lock would suspend the game mid-play or mid shader import.
    application.idleTimerDisabled = YES;
    audio_observe();
    /* The Mac launcher passes the preferred language as TOTK_LOCALE (PR #97); "zh-Hans-CN" maps to zh-Hans in services.c. */
    NSString *preferred = NSLocale.preferredLanguages.firstObject;
    if (preferred.length) setenv("TOTK_LOCALE", preferred.UTF8String, 1);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *res = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"GameData"];
    for (NSString *name in @[@"save", @"temp", @"shader-cache", @"game-slot", @"mods"]) [fm createDirectoryAtPath:[docs stringByAppendingPathComponent:name] withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *log = [docs stringByAppendingPathComponent:@"log.txt"];
    if (freopen(log.fileSystemRepresentation,"w",stderr)) setvbuf(stderr,NULL,_IOLBF,0);
    setenv("TOTK_ROMFS",[res stringByAppendingPathComponent:@"romfs"].fileSystemRepresentation,1);
    /* The 17 GB image may live in Documents/GameData instead of the app (romfs.bin or romfs.bin.000, ...; ios/tools/
       install_device.py --game-data puts it there): a new build then installs without it, and reinstalling keeps it.
       Excluded from iCloud backups. The runtime still hashes it once against the build's pin (TOTK_ROMFS_PROOF_DIR). */
    NSString *gameData = [docs stringByAppendingPathComponent:@"GameData"];
    BOOL image = [fm fileExistsAtPath:[gameData stringByAppendingPathComponent:@"romfs.bin"]] ||
                 [fm fileExistsAtPath:[gameData stringByAppendingPathComponent:@"romfs.bin.000"]];
    NSString *mark = [NSString stringWithContentsOfFile:[gameData stringByAppendingPathComponent:@"romfs.sha256"] encoding:NSUTF8StringEncoding error:nil];
    BOOL copying = mark && [mark stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length != 64;   // install_device.py writes the hash last
    if (image && !copying) {
        [[NSURL fileURLWithPath:gameData isDirectory:YES] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        setenv("TOTK_ROMFS_DATA",gameData.fileSystemRepresentation,1);
    } else if (![fm fileExistsAtPath:[res stringByAppendingPathComponent:@"romfs/romfs.bin"]]) {
        /* No image to play from: said on the screen instead of the game ending at once (runtime_fail exits). */
        BOOL zh = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
        NSString *app = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"TOTK";   // the Files app's folder name
        g_no_game_data = copying || image
            ? [NSString stringWithFormat:(zh ? @"游戏数据还在复制到“文件 › 我的 iPhone › %@ › GameData”，复制完再打开游戏。"
                                             : @"The game data is still being copied to Files › On My iPhone › %@ › GameData. Open the game again when it is done."), app]
            : [NSString stringWithFormat:(zh ? @"没有游戏数据。请在 Mac 上用 ios/tools/install_device.py --game-data 把它复制到“文件 › 我的 iPhone › %@ › GameData”。"
                                             : @"No game data. On the Mac, copy it to Files › On My iPhone › %@ › GameData with ios/tools/install_device.py --game-data."), app];
        fprintf(stderr, "[totk] no game image: %s\n", g_no_game_data.UTF8String);
    }
    setenv("TOTK_OPERATION_MODE","handheld",1);
    // Game language: the Settings app (Settings.bundle › TOTK_LANG) stores the choice in our defaults; empty means the
    // system language, which is what the runtime already follows. iOS 27 does not honour Info.plist LSEnvironment, so
    // the value must be applied here. overwrite=0 keeps devicectl --environment-variables winning when testing from the Mac.
    NSString *lang = [NSUserDefaults.standardUserDefaults stringForKey:@"TOTK_LANG"];
    if (lang.length>0&&lang.length<8) setenv("TOTK_LANG",lang.UTF8String,0);
    setenv("TOTK_ROMFS_PATCHES",[res stringByAppendingPathComponent:@"romfs-patches"].fileSystemRepresentation,1);
    setenv("TOTK_ROMFS_PATCHES_OUT",[res stringByAppendingPathComponent:@"romfs-patches-out"].fileSystemRepresentation,1);
    setenv("TOTK_SHARED_FONTS",[res stringByAppendingPathComponent:@"shared-fonts"].fileSystemRepresentation,1);
    setenv("TOTK_SHADER_SEED_DIR",[res stringByAppendingPathComponent:@"shader-seed"].fileSystemRepresentation,1);
    /* One folder per translation chain, as on the Mac: the runtime refuses translations of another chain, and the seed
       import keeps files that are already there. Builds before the v5 chain (2026-10-20) kept them directly in
       shader-cache; those, and other chains' folders, are only cache and are removed in the background. */
    NSString *cacheRoot = [docs stringByAppendingPathComponent:@"shader-cache"], *chainDir = @"rt-" DMSH_CHAIN;
    NSString *cache = [cacheRoot stringByAppendingPathComponent:chainDir];
    /* Test launches (devicectl --environment-variables '{"TOTK_SHADER_CACHE":"cache-test/1"}') can name another folder
       in Documents, e.g. an empty one to time a first start; it lies outside shader-cache, so the cleanup leaves it. */
    const char *testCache = getenv("TOTK_SHADER_CACHE");
    if (testCache && *testCache && !strstr(testCache, "..")) cache = [docs stringByAppendingPathComponent:@(testCache)];
    [fm createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("TOTK_SHADER_CACHE",cache.fileSystemRepresentation,1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSFileManager *files = [NSFileManager new]; NSUInteger removed = 0;
        for (NSString *name in [files contentsOfDirectoryAtPath:cacheRoot error:nil] ?: @[]) {
            if ([name isEqualToString:chainDir]) continue;
            if ([files removeItemAtPath:[cacheRoot stringByAppendingPathComponent:name] error:nil]) removed++;
        }
        if (removed) fprintf(stderr,"[shader-cache] removed %lu entries of earlier translation chains\n",(unsigned long)removed);
    });
    // Shaders the shared list lacks (totk_shader_contrib.h), in the Files app for players who want to send them; only the Mac asks.
    setenv("TOTK_SHADER_CONTRIB",[docs stringByAppendingPathComponent:@"shader-list-contribution.txt"].fileSystemRepresentation,1);
    setenv("DM_NVN_SHMAP",[res stringByAppendingPathComponent:@"shader-seed/shader_map.tsv"].fileSystemRepresentation,1);
    setenv("DM_MSL_DIR",[res stringByAppendingPathComponent:@"shader-seed"].fileSystemRepresentation,1);
    /* Player mods (runtime/romfs.c), as on the Mac: Documents/mods/manifest.tsv, when present (Files app). */
    setenv("TOTK_ROMFS_MODS",[docs stringByAppendingPathComponent:@"mods"].fileSystemRepresentation,0);
    setenv("TOTK_FPS_CAP",[NSString stringWithFormat:@"%d",saved_fps_cap()].UTF8String,0);
    { int out = saved_output_height(), rw, rh; render_size(out, saved_render_scale(), &rw, &rh);
      setenv("TOTK_OUTPUT_RES",[NSString stringWithFormat:@"%dx%d",width_16_9(out),out].UTF8String,0);
      setenv("TOTK_IOS_DRAWABLE_H",[NSString stringWithFormat:@"%d",out].UTF8String,0);
      setenv("TOTK_RENDER_RES",[NSString stringWithFormat:@"%dx%d",rw,rh].UTF8String,0); }
    fps_overlay_set_hud_mode(saved_hud());
    NSString *font = [res stringByAppendingPathComponent:@"font"]; setenv("TOTK_FONT_DIR",font.fileSystemRepresentation,1);
    // Same player environment as the Mac launcher (app/launcher.m); the bundle is read-only, so state goes to Documents.
    setenv("TOTK_PROFILE_DIR",[docs stringByAppendingPathComponent:@"save"].fileSystemRepresentation,1);
    setenv("TOTK_GAME_SLOT_DIR",[docs stringByAppendingPathComponent:@"game-slot"].fileSystemRepresentation,1);
    setenv("TOTK_ROMFS_PROOF_DIR",docs.fileSystemRepresentation,1);   // hash the 17 GB RomFS once, not on every launch
    for (NSString *name in @[@"TOTK_GPU_ALLOW_SUBMIT",@"TOTK_GPU_WIDEN",@"TOTK_GPU_BLOCKRT",@"TOTK_GPU_MIDCLEAR"]) setenv(name.UTF8String,"1",1);
    setenv("TOTK_SLOT_OWNER","user",0); setenv("TOTK_SLOT_PURPOSE","player",0);
    unsetenv("TOTK_AUTOLOAD");
    chdir(docs.fileSystemRepresentation);
    host_argv[0] = strdup("TOTK"); host_argv[1] = strdup(res.fileSystemRepresentation); host_argv[2] = strdup("boot");
    return YES;   // the window is made when the window scene connects (TOTKSceneDelegate)
}
@end

int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TOTKApp.class)); } }
