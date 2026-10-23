# iPhone / iPad: settings menu, mods and saves

What this branch adds to upstream's iPhone/iPad build of Tears of the Kingdom 1.4.3: an in-game settings menu, slimmer
touch controls, mods, save sync and copying saves between devices. Building, signing and installing are upstream's
([README](../README.md#build-the-app)); this page covers only what differs.

Until it is merged upstream, this lives on the `ios-settings-menu` branch of
[kiluss2/MacNativeGames](https://github.com/kiluss2/MacNativeGames/tree/ios-settings-menu).

Tested on an iPad Pro 11" (M4, iPadOS 27) and an iPhone 15 Pro (iOS 27).

## 1. Build

Upstream's iOS build with two more variables, which the Resolution and Render scale items need:

```bash
git clone -b ios-settings-menu https://github.com/kiluss2/MacNativeGames
cd MacNativeGames
TOTK_IOS_OUTPUT_MAX=1920x1080 TOTK_RENDER_RES=1280x720 \
  python3.14 build_app.py ~/Games/totk.xci --update ~/Games/1.4.3.nsp -k ~/keys/prod.keys \
  --platform ios -o ~/Games/TOTK.ipa
```

| Variable | Effect |
|---|---|
| `TOTK_IOS_OUTPUT_MAX=1920x1080` | Embeds the output patch in the iOS code, so Resolution can be set to 720p, 900p or 1080p. At most 1920x1080: the game's heaps are already sized for it, so no game data needs changing. |
| `TOTK_RENDER_RES=1280x720` | Embeds the 3D scene resolution patch, so Render scale works. The actual size is picked by the iPhone/iPad at each launch. |

Upstream's `--ios-game-data documents` (the game image kept in Documents and copied once) has not been tried with
this branch yet.

## 2. Sign and install

Upstream's `games/totk/ios/tools/install_device.py` signs with your own Xcode team and installs over the cable (README,
[iPhone and iPad](../README.md#iphone-and-ipad)); `--bundle-id com.yourname.totk` picks the bundle ID.

The game needs the **Increased Memory Limit** entitlement (`com.apple.developer.kernel.increased-memory-limit`), and on
iOS 27 it only takes effect when the provisioning profile grants it. Signed with a profile that does not (a wildcard
`com.*` profile, iLoader, SideStore…), the game stops at startup with:

```text
[totk] FAIL: reserve guest stack, heap and alias regions
```

### With a profile you already have

For a profile Xcode on this Mac does not make (another team's certificate, one profile for several devices): check that
the profile has the entitlement and the device, then set the bundle ID, sign and install. Replace `TEAMID`,
`com.yourname.totk` and the certificate name (`security find-identity -v -p codesigning`) with your own:

```bash
security cms -D -i embedded.mobileprovision > profile.plist
/usr/libexec/PlistBuddy -c 'Print :Entitlements' -c 'Print :ProvisionedDevices' -c 'Print :ExpirationDate' profile.plist
cp -cR TOTK_build/totk/build/ios-payload/Payload/TOTK.app ./TOTK.app
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.yourname.totk' TOTK.app/Info.plist
cp embedded.mobileprovision TOTK.app/embedded.mobileprovision
cat > entitlements.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>application-identifier</key><string>TEAMID.com.yourname.totk</string>
	<key>com.apple.developer.team-identifier</key><string>TEAMID</string>
	<key>com.apple.developer.kernel.increased-memory-limit</key><true/>
	<key>get-task-allow</key><true/>
	<key>keychain-access-groups</key><array><string>TEAMID.com.yourname.totk</string></array>
</dict></plist>
EOF
codesign -f -s "Apple Development: you@example.com (XXXXXXXXXX)" --entitlements entitlements.plist --generate-entitlement-der TOTK.app
codesign --verify --strict TOTK.app && codesign -d --entitlements - TOTK.app | grep -A1 memory
xcrun devicectl device install app --device <UDID> TOTK.app
```

- Signing takes about 2 minutes (17 GB). Installing over a USB 2.0 cable (the one that comes with an iPhone) takes
  about 10 minutes, over a 10 Gb/s or faster cable about 2–4 minutes
  (`system_profiler SPUSBHostDataType | grep -A3 -iE 'iphone|ipad'` shows the link speed).
- The first time with a certificate: on the device go to **Settings → General → VPN & Device Management**, pick the
  certificate → **Trust** (needs a network connection). The device also needs **Developer Mode** on.
- Installing over an app with the same bundle ID keeps saves, mods and settings.

## 3. Settings menu (the ⚙︎ button at the top centre)

The ⚙︎ sits between − and + and hides 4 seconds after it was last used. Tap that spot once to show it, then tap it
again to open the menu.

The touch controls also cover less of the picture than upstream's: a stick is drawn only while a finger holds it
(touching anywhere on a half still makes a stick there), buttons are drawn at 38 points while still taking touches
over their old 46, pressed buttons light up, and 3 seconds after the last finger lifts the whole layer fades to about
a third; the next touch brings it back at once.

Each item has an **ⓘ About this setting** entry with an in-game explanation. Choices are kept for the next launch.

| Item | Choices | Takes effect |
|---|---|---|
| Save sync | **Off** / a folder in iCloud Drive ([ios-save-sync.md](ios-save-sync.md)) | next launch |
| Frame rate limit | 30 / 40 / **60** / Unlimited | at once |
| Resolution | **720p** (Switch handheld) / 900p / 1080p (Switch docked) | next launch |
| Render scale | 50% / 67% / 75% / **100%** (with the actual size) | next launch |
| Performance overlay | Off / FPS / **FPS + resolution** / FPS + resolution + CPU, GPU, RAM | at once |
| GPU keep-alive (testing) | On / Off (**Off** on iPhone, **On** on iPad) | next launch |
| Translation thread (testing) | **Off** / On | next launch |
| Screen refresh (testing) | **Full** / Match the frame rate limit | next launch |

- **Frame rate limit:** on a 120 Hz screen (iPad Pro, iPhone Pro) without a limit the game draws 120 frames a second
  and runs very hot. The game runs at the right speed at every limit.
- **Resolution** is the size of the finished picture (the 3D scene plus the HUD, text and map). **Render scale** is the
  size of the 3D scene relative to Resolution, on each axis: 1080p at 67% draws the scene at 1280x720 (less than half
  the pixels) while text and HUD stay sharp at 1080p. The 3D scene is where most of the GPU time goes.
- **The full overlay** adds a line at the bottom right: average use of the performance (P) and efficiency (E) cores,
  the busiest thread (T), the GPU time the game uses, and the memory the game holds with what iOS still allows it
  (`left`); iOS closes the game when `left` reaches 0.
- **GPU keep-alive (testing):** between frames the game keeps the GPU busy with filler work so it does not lower its
  clock (`TOTK_GPU_KEEPALIVE`, tuned on an M4 Mac). iPhone 15 Pro at a 30 FPS cap, left idle 22 minutes per run: with
  it on, the submit thread fell to 1.1 GHz; with it off, it stayed at 2.4 GHz, and the GPU ran slower but still kept
  30 FPS. In about 18 minutes of real play with it off the clock stayed at 2.7 GHz (1.5 with it on), frames over 50 ms
  halved and the present p99 fell from 55 to 47 ms, so it is **off by default on the iPhone**. The iPad keeps it on
  until it is measured there (it was tuned on an M4 Mac). A choice made in the menu is kept either way. The game's
  log (`Documents/log.txt`) records the iOS thermal state (`thermal state` lines at start and on each change, `温控` in
  the present summary every 300 frames: 0 nominal … 3 critical), so a hot phone can be told from a slow thread.
- **Translation thread (testing):** `TOTK_ASYNC_REPLAY=1`. Turning the game's commands into Metal work then runs on a
  thread of its own while the game logic of the next frame runs, instead of after it. Aimed at smoother frames when the
  CPU is the limit, not at heat, and it uses more memory. Off is the upstream default; On is not yet measured on the
  iPhone.
- **Screen refresh (testing):** with a frame rate limit, Full keeps the screen at its own rate (120 Hz on ProMotion), so
  a late frame shows at the next refresh a few milliseconds later. Match the frame rate limit (`TOTK_LINK_MATCH_CAP=1`)
  refreshes only as often as the limit (30, 40 or 60 times a second), which may save battery; a late frame then waits a
  whole refresh (33 ms at 30). No effect with Unlimited or a limit the screen's rate is not a multiple of. Not measured
  yet. The log records the battery (`battery` lines: level, charging, Low Power Mode) for comparing the two.

Measurements and the test plan for the testing options: [ios-performance-notes.md](ios-performance-notes.md).

Suggested: iPhone 720p / 100% / 60 FPS; iPad M4 1080p / 67% / 40–60 FPS, or 1080p / 100% / 30–40 FPS.

Technical note: in handheld mode the game scales the 3D scene by canvas width / 1280 (measured on the iPad: 1600x900 on
a 1600x900 canvas became 2000x1120 and ran out of texture memory), so `render_res_publish` divides that factor out on
iOS.

## 4. Mods (for example a translation)

The iOS version on this branch reads RomFS mods from the app's **`Documents/mods`** folder, with the same rules as the
Mac version ([mods.md](mods.md)): only files listed in `manifest.tsv` are used.

1. Prepare the mod and make `manifest.tsv` on the Mac as in [mods.md](mods.md) (with a Mac app of the same version,
   1.4.3).
2. Copy it to the device (one command per file, keeping the RomFS paths):

```bash
xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer --domain-identifier com.yourname.totk \
  --source manifest.tsv --destination Documents/mods/manifest.tsv
```

The **Files** app also works: **On My iPhone/iPad → (app name) → mods**. The game's log (`Documents/log.txt`) has a
`Documents/mods checked, N files` line when the mod is loaded.

Version 1.4.3 uses the text file `Mals/USen.Product.142.sarc.zs` and the table
`System/Resource/ResourceSizeTable.Product.143.Nin_NX_NVN.rsizetable.zs`. Mods made for 1.4.2 usually ship a `.142`
table: update the entries of the replaced files in the original `.143` table (keeping the larger size) and name it
`.143`; otherwise a file larger than the original can crash the game.

## 5. Copying saves between devices

Saves are in the app's `Documents/save`. Nothing syncs them: copy **one way**, from the device played last, and back up
first. Automatic sync between iPhone, iPad and Mac through a folder in iCloud Drive: settings menu › Save sync, see
[ios-save-sync.md](ios-save-sync.md).

```bash
# list the files
xcrun devicectl device info files --device <source UDID> --domain-type appDataContainer \
  --domain-identifier com.yourname.totk --subdirectory Documents/save
# copy each file to the Mac and then to the other device, keeping the paths, for example:
xcrun devicectl device copy from --device <source UDID> --domain-type appDataContainer --domain-identifier com.yourname.totk \
  --source Documents/save/save/<id>/slot_00/progress.sav --destination backup/save/<id>/slot_00/progress.sav
xcrun devicectl device copy to --device <target UDID> --domain-type appDataContainer --domain-identifier com.yourname.totk \
  --source backup/save/<id>/slot_00/progress.sav --destination Documents/save/save/<id>/slot_00/progress.sav
```

Copy `account.uid` and the whole `save/<id>/` folder (the `slot_*` folders, `option.sav`, `album`). With the same
`account.uid` on both devices the game opens that save folder.

## 6. Contributing shaders

As upstream (README, [Let's maintain the shader list together](../README.md#lets-maintain-the-shader-list-together-no-more-stutter)):
the iPhone/iPad notes the shaders and render pipelines the shared list lacks, and the Mac that built the app gathers
them into `<clone>/shader-list-contribution/` and asks before sending. A build with `--no-shader-reminder` leaves that
Mac agent out; `python3.14 games/totk/ios/tools/shader_contrib_watch.py install --store "$PWD/shader-list-contribution"`
adds it later.
