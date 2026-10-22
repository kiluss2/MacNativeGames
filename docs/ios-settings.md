# iPhone / iPad: build, sign, settings menu

How to build the iPhone/iPad version of Tears of the Kingdom 1.4.3, sign it with an Apple ID (a free account works
too), install it, use the settings menu, add mods and copy saves between devices.

Until it is merged upstream, this lives on the `ios-settings-menu` branch of
[kiluss2/MacNativeGames](https://github.com/kiluss2/MacNativeGames/tree/ios-settings-menu).

Tested on an iPad Pro 11" (M4, iPadOS 27) and an iPhone 15 Pro (iOS 27).

## 1. Requirements

- An Apple silicon Mac, macOS 26 or later, **Xcode 26 or later** (the full app, with the iOS SDK and the Metal
  toolchain).
- Tools: `brew install opus libvpx python@3.14 xcodegen cmake ninja`
- The Metal toolchain (to compile shaders ahead of time): `xcodebuild -downloadComponent MetalToolchain`
- The base game 1.0.0 (`0100F2C0115B6000`, XCI or NSP), the 1.4.3 update (NSP/NSZ) and your own `prod.keys`.
- About **60 GB** free for the first iOS build.
- An Apple ID signed in under **Xcode → Settings → Accounts** (a free account is enough).

## 2. Build

```bash
git clone -b ios-settings-menu https://github.com/kiluss2/MacNativeGames
cd MacNativeGames
TOTK_IOS_OUTPUT_MAX=1920x1080 TOTK_RENDER_RES=1280x720 TOTK_IOS_BUNDLE_ID=com.yourname.totk \
  python3.14 build_app.py ~/Games/totk.xci --update ~/Games/1.4.3.nsp -k ~/keys/prod.keys \
  --platform ios -o ~/Games/TOTK.ipa
```

All three environment variables are needed for the whole menu to work:

| Variable | Effect |
|---|---|
| `TOTK_IOS_OUTPUT_MAX=1920x1080` | Embeds the output patch in the iOS code, so Resolution can be set to 720p, 900p or 1080p. At most 1920x1080: the game's heaps are already sized for it, so no game data needs changing. |
| `TOTK_RENDER_RES=1280x720` | Embeds the 3D scene resolution patch, so Render scale works. The actual size is picked by the iPhone/iPad at each launch. |
| `TOTK_IOS_BUNDLE_ID=com.yourname.totk` | The app's bundle ID. Use one of your own: a bundle ID can be registered by only one team. |

The first build takes a few hours (it compiles shaders and pipelines for iOS). Later builds reuse the `TOTK_build`
folder (next to the game file, or where `--work` points), so they take about 5 minutes. The unsigned app is
`TOTK_build/totk/build/ios-payload/Payload/TOTK.app` (also packed as `TOTK.ipa`).

`--no-shader-reminder` skips installing the Mac agent that offers to send new shaders.

## 3. Signing

### Why the signing matters

The game needs the **Increased Memory Limit** entitlement (`com.apple.developer.kernel.increased-memory-limit`). On
iOS 27 it only takes effect when the **provisioning profile** grants it. Signed with a profile that does not (a
wildcard `com.*` profile, iLoader, SideStore…), the game stops at startup with:

```text
[totk] FAIL: reserve guest stack, heap and alias regions
```

The reliable way is to let **Xcode create the profile** (automatic signing): Xcode sees that the app asks for the
entitlement and puts it in the profile. A free account (Personal Team) works too, but its profiles last **7 days**.

### 3.1. Make the profile with a template app in Xcode

1. Xcode → File → New → Project → iOS **App**. Set the **Bundle Identifier** to the `TOTK_IOS_BUNDLE_ID` used for the
   build and pick your **Team**.
2. **Signing & Capabilities** tab → keep **Automatically manage signing** → **+ Capability** → **Increased Memory
   Limit**.
3. Connect the iPhone/iPad, pick it as the run destination and press **Run** once. Xcode registers the device with the
   team and creates the profile. For one profile covering several devices, Run on each of them in turn.
4. Take the profile from the built template app (Product → Show Build Folder in Finder →
   `Build/Products/Debug-iphoneos/<Name>.app/embedded.mobileprovision`). Check that it has the entitlement and the
   device:

```bash
security cms -D -i embedded.mobileprovision > profile.plist
/usr/libexec/PlistBuddy -c 'Print :Entitlements' -c 'Print :ProvisionedDevices' -c 'Print :ExpirationDate' profile.plist
```

It must show `com.apple.developer.kernel.increased-memory-limit = true` and the device's UDID
(`xcrun devicectl list devices` lists UDIDs).

### 3.2. Sign the game

`security find-identity -v -p codesigning` lists the signing certificates (`Apple Development: …`). Replace `TEAMID`,
`com.yourname.totk` and the certificate name with your own:

```bash
cp -cR TOTK_build/totk/build/ios-payload/Payload/TOTK.app ./TOTK.app
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
```

Signing takes about 2 minutes (17 GB).

### 3.3. (Optional) Home screen name and icon

Do this **before** signing (any change inside `TOTK.app` after signing breaks the signature):

```bash
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Totk' TOTK.app/Info.plist
# The game's icon (build_app.py extracted it from the game data):
sips -s format png TOTK_build/totk/build/AppIcon.icns --out icon.png
sips -z 120 120 icon.png --out 'TOTK.app/AppIcon60x60@2x.png'
sips -z 180 180 icon.png --out 'TOTK.app/AppIcon60x60@3x.png'
sips -z 152 152 icon.png --out 'TOTK.app/AppIcon76x76@2x~ipad.png'
sips -z 167 167 icon.png --out 'TOTK.app/AppIcon83.5x83.5@2x~ipad.png'
P=TOTK.app/Info.plist; B=/usr/libexec/PlistBuddy
$B -c 'Add :CFBundleIcons dict' -c 'Add :CFBundleIcons:CFBundlePrimaryIcon dict' \
   -c 'Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array' \
   -c 'Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon60x60' $P
$B -c 'Add :CFBundleIcons~ipad dict' -c 'Add :CFBundleIcons~ipad:CFBundlePrimaryIcon dict' \
   -c 'Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles array' \
   -c 'Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon60x60' \
   -c 'Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles:1 string AppIcon76x76' \
   -c 'Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles:2 string AppIcon83.5x83.5' $P
```

## 4. Install

```bash
xcrun devicectl device install app --device <UDID> TOTK.app
```

- A USB 2.0 cable (the one that comes with an iPhone) takes about 10 minutes for 17 GB; a 10 Gb/s or faster cable
  about 2–4 minutes. To see the link speed: `system_profiler SPUSBHostDataType | grep -A3 -iE 'iphone|ipad'`.
- The first time with a certificate: on the device go to **Settings → General → VPN & Device Management**, pick the
  certificate → **Trust** (needs a network connection). The device also needs **Developer Mode** on.
- Installing over an app with the same bundle ID keeps saves, mods and settings.
- Free profiles expire after 7 days: Run the template app in Xcode again for a new profile, sign again (3.2) and
  install over the old app.

On the first launch the game verifies its data (about 15 seconds). The first sessions stutter more: the device builds
pipelines for its own GPU and stores them in the pipeline archive in the background. Leaving the game at the title
screen for a while makes later sessions smoother. The archive is tied to the GPU, so it cannot be copied to a device
with a different chip.

## 5. Settings menu (the ⚙︎ button at the top centre)

Each item has an **ⓘ About this setting** entry with an in-game explanation. Choices are kept for the next launch.

| Item | Choices | Takes effect |
|---|---|---|
| Frame rate limit | 30 / 40 / **60** / Unlimited | at once |
| Resolution | **720p** (Switch handheld) / 900p / 1080p (Switch docked) | next launch |
| Render scale | 50% / 67% / 75% / **100%** (with the actual size) | next launch |
| Performance overlay | Off / FPS / **FPS + resolution** / FPS + resolution + CPU, GPU, RAM | at once |
| GPU keep-alive (testing) | **On** / Off | next launch |
| Translation thread (testing) | **Off** / On | next launch |

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
  30 FPS. One run each so far and not yet measured in real play; if Off stutters more, turn it back On. The game's
  log (`Documents/log.txt`) records the iOS thermal state (`thermal state` lines at start and on each change, `温控` in
  the present summary every 300 frames: 0 nominal … 3 critical), so a hot phone can be told from a slow thread.
- **Translation thread (testing):** `TOTK_ASYNC_REPLAY=1`. Turning the game's commands into Metal work then runs on a
  thread of its own while the game logic of the next frame runs, instead of after it. Aimed at smoother frames when the
  CPU is the limit, not at heat, and it uses more memory. Off is the upstream default; On is not yet measured on the
  iPhone.

Measurements and the test plan for the two testing options: [ios-performance-notes.md](ios-performance-notes.md).

Suggested: iPhone 720p / 100% / 60 FPS; iPad M4 1080p / 67% / 40–60 FPS, or 1080p / 100% / 30–40 FPS.

Technical note: in handheld mode the game scales the 3D scene by canvas width / 1280 (measured on the iPad: 1600x900 on
a 1600x900 canvas became 2000x1120 and ran out of texture memory), so `render_res_publish` divides that factor out on
iOS.

## 6. Mods (for example a translation)

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

## 7. Copying saves between devices

Saves are in the app's `Documents/save`. Nothing syncs them: copy **one way**, from the device played last, and back up
first.

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

## 8. Contributing shaders

When the game meets a shader the shared list lacks, it writes it to `Documents/shader-list-contribution.txt`. The Mac
agent (`games/totk/ios/tools/shader_contrib_watch.py`, installed by the iOS build) checks connected devices (cable or
same Wi‑Fi) every 10 minutes and, for every 500 new shaders, asks once in a dialog on the Mac whether to send them as a
GitHub issue. To remove it: `python3 games/totk/ios/tools/shader_contrib_watch.py uninstall`.
