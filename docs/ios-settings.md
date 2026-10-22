# iPhone / iPad: build, sign, settings menu (branch `ios-settings-menu`)

Hướng dẫn build bản iPhone/iPad của Tears of the Kingdom 1.4.3 từ nhánh này, ký bằng Apple ID của bạn (kể cả tài khoản
miễn phí), cài lên máy, dùng menu cài đặt, cài mod và chép save giữa các máy.

Đã chạy được trên iPad Pro 11" (M4, iPadOS 27) và iPhone 15 Pro (iOS 27).

## 1. Chuẩn bị

- Mac Apple silicon, macOS 26 trở lên, **Xcode 26 trở lên** (đầy đủ, có iOS SDK và Metal toolchain).
- Công cụ: `brew install opus libvpx python@3.14 xcodegen cmake ninja`
- Metal toolchain (để biên dịch shader sẵn): `xcodebuild -downloadComponent MetalToolchain`
- Game gốc 1.0.0 (`0100F2C0115B6000`, XCI hoặc NSP), bản update 1.4.3 (NSP/NSZ) và `prod.keys` của bạn.
- Trống khoảng **60 GB** cho lần build iOS đầu tiên.
- Apple ID đã đăng nhập trong **Xcode → Settings → Accounts** (miễn phí cũng được).

## 2. Build

```bash
git clone -b ios-settings-menu https://github.com/kiluss2/MacNativeGames
cd MacNativeGames
TOTK_IOS_OUTPUT_MAX=1920x1080 TOTK_RENDER_RES=1280x720 TOTK_IOS_BUNDLE_ID=com.yourname.totk \
  python3.14 build_app.py ~/Games/totk.xci --update ~/Games/1.4.3.nsp -k ~/keys/prod.keys \
  --platform ios -o ~/Games/TOTK.ipa
```

Ba biến môi trường là bắt buộc để menu hoạt động đủ:

| Biến | Tác dụng |
|---|---|
| `TOTK_IOS_OUTPUT_MAX=1920x1080` | Nhúng patch xuất hình vào code iOS, để chọn được Resolution 720p/900p/1080p. Tối đa 1920x1080: bộ nhớ heap của game vốn đủ cho mức này nên không cần sửa thêm dữ liệu. |
| `TOTK_RENDER_RES=1280x720` | Nhúng patch độ phân giải cảnh 3D, để chỉnh được Render scale. Kích thước thật do iPhone/iPad chọn mỗi lần mở game. |
| `TOTK_IOS_BUNDLE_ID=com.yourname.totk` | Bundle ID của app. Đặt một ID của riêng bạn: mỗi Bundle ID chỉ một team đăng ký được. |

Lần đầu mất vài tiếng (biên dịch shader và pipeline cho iOS). Các lần sau dùng lại thư mục `TOTK_build` (cạnh file game,
hoặc nơi `--work` chỉ tới) nên chỉ mất khoảng 5 phút. App chưa ký nằm ở
`TOTK_build/totk/build/ios-payload/Payload/TOTK.app` (và đóng gói thành `TOTK.ipa`).

Muốn không cài agent nhắc gửi shader trên Mac thì thêm `--no-shader-reminder`.

## 3. Ký app

### Vì sao phải ký đúng cách

Game cần quyền **Increased Memory Limit** (`com.apple.developer.kernel.increased-memory-limit`). Trên iOS 27, quyền
này chỉ có tác dụng khi **provisioning profile** cho phép nó. Ký bằng profile không có quyền (profile wildcard
`com.*`, iLoader, SideStore…) thì game dừng ngay lúc khởi động với lỗi:

```text
[totk] FAIL: reserve guest stack, heap and alias regions
```

Cách chắc chắn nhất là để **Xcode tự tạo profile** (automatic signing): Xcode thấy app xin quyền này nên đưa nó vào
profile. Tài khoản miễn phí (Personal Team) cũng được, nhưng profile chỉ dùng **7 ngày**.

### 3.1. Tạo profile bằng một app mẫu trong Xcode

1. Xcode → File → New → Project → iOS **App**. Đặt **Bundle Identifier** đúng bằng `TOTK_IOS_BUNDLE_ID` ở bước build,
   chọn **Team** của bạn.
2. Tab **Signing & Capabilities** → giữ **Automatically manage signing** → **+ Capability** → **Increased Memory Limit**.
3. Cắm iPhone/iPad vào Mac, chọn máy đó làm đích chạy và bấm **Run** một lần. Xcode đăng ký máy vào team và tạo profile.
   Muốn một profile cho nhiều máy thì lần lượt Run trên từng máy.
4. Lấy profile vừa tạo từ app mẫu đã build (Product → Show Build Folder in Finder →
   `Build/Products/Debug-iphoneos/<Tên>.app/embedded.mobileprovision`). Kiểm tra nó có quyền và có máy của bạn:

```bash
security cms -D -i embedded.mobileprovision > profile.plist
/usr/libexec/PlistBuddy -c 'Print :Entitlements' -c 'Print :ProvisionedDevices' -c 'Print :ExpirationDate' profile.plist
```

Phải thấy `com.apple.developer.kernel.increased-memory-limit = true` và UDID của máy
(`xcrun devicectl list devices` để xem UDID).

### 3.2. Ký bản game

Tên chứng chỉ ký (`Apple Development: …`) xem bằng `security find-identity -v -p codesigning`. Thay `TEAMID`,
`com.yourname.totk` và tên chứng chỉ cho đúng của bạn:

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

Ký mất khoảng 2 phút (17 GB).

### 3.3. (Tuỳ chọn) Đổi tên và icon trên màn hình chính

Làm **trước** khi ký (mọi thay đổi trong `TOTK.app` sau khi ký sẽ làm hỏng chữ ký):

```bash
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Totk' TOTK.app/Info.plist
# Icon của game (build_app.py đã lấy từ dữ liệu game của bạn):
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

## 4. Cài lên máy

```bash
xcrun devicectl device install app --device <UDID> TOTK.app
```

- Dây USB 2.0 (dây đi kèm iPhone) mất khoảng 10 phút cho 17 GB; dây 10 Gb/s trở lên khoảng 2–4 phút. Xem tốc độ:
  `system_profiler SPUSBHostDataType | grep -A3 -iE 'iphone|ipad'`.
- Lần đầu với một chứng chỉ: trên máy vào **Cài đặt → Cài đặt chung → Quản lý VPN & thiết bị**, chọn chứng chỉ của
  bạn → **Tin cậy** (cần mạng). Máy cũng phải bật **Developer Mode**.
- Cài đè cùng Bundle ID giữ nguyên save, mod và cài đặt.
- Profile miễn phí hết hạn sau 7 ngày: Run lại app mẫu trong Xcode để lấy profile mới, ký lại (3.2) và cài đè.

Lần mở đầu tiên game kiểm tra dữ liệu (khoảng 15 giây). Những lần chơi đầu sẽ giật hơn: máy phải tự ghép pipeline
cho GPU của nó và lưu vào kho (pipeline archive) ở nền; để game mở ở màn hình tiêu đề một lúc thì những lần sau mượt
hơn. Kho này gắn với chip GPU nên không chép được từ máy này sang máy khác chip.

## 5. Menu cài đặt (nút ⚙︎ giữa cạnh trên)

Mỗi mục có dòng **ⓘ About this setting** giải thích ngay trong game. Lựa chọn được lưu lại cho lần mở sau.

| Mục | Lựa chọn | Có hiệu lực |
|---|---|---|
| Frame rate limit | 30 / 40 / **60** / Unlimited | ngay |
| Resolution | **720p** (Switch cầm tay) / 900p / 1080p (Switch cắm TV) | lần mở sau |
| Render scale | 50% / 67% / 75% / **100%** (kèm kích thước thật) | lần mở sau |
| Performance overlay | Off / FPS / **FPS + resolution** / FPS + resolution + CPU, GPU, RAM | ngay |
| GPU keep-alive (testing) | **On** / Off | lần mở sau |

- **Frame rate limit:** màn hình 120 Hz (iPad Pro, iPhone Pro) mà không giới hạn thì game vẽ 120 hình/giây và rất
  nóng. Tốc độ game vẫn đúng ở mọi mức.
- **Resolution** là kích thước hình game xuất ra (cảnh 3D cộng giao diện, chữ, bản đồ). **Render scale** là kích thước
  cảnh 3D so với Resolution, tính theo mỗi chiều: 1080p ở 67% vẽ cảnh 3D 1280x720 (ít hơn một nửa số điểm ảnh) nhưng
  chữ và giao diện vẫn nét 1080p. Cảnh 3D là phần tốn GPU nhất.
- **Overlay đầy đủ** thêm dòng góc dưới phải: trung bình nhân hiệu năng (P) và tiết kiệm điện (E), luồng bận nhất (T),
  phần GPU game dùng, RAM game đang giữ và phần iOS còn cho (`left`); `left` về 0 thì iOS tắt game.
- **GPU keep-alive (testing):** giữa các khung hình game cho GPU chạy việc độn để GPU không hạ xung
  (`TOTK_GPU_KEEPALIVE`, chỉnh trên Mac M4). Trên iPhone 15 Pro khoá 30 FPS, treo máy 22 phút mỗi lượt: bật thì luồng
  gửi lệnh vẽ tụt còn 1,1 GHz, tắt thì giữ 2,4 GHz; GPU chạy chậm hơn nhưng vẫn kịp 30 FPS. Mới đo 1 lượt mỗi kiểu
  và chưa đo khi chơi thật; nếu tắt mà khựng hơn thì bật lại.

Gợi ý: iPhone 720p / 100% / 60 FPS; iPad M4 1080p / 67% / 40–60 FPS, hoặc 1080p / 100% / 30–40 FPS.

Ghi chú kỹ thuật: khi chơi cầm tay, game phóng cảnh 3D theo tỉ lệ khung / 1280 (đo trên iPad: 1600x900 trên khung
1600x900 ra 2000x1120 và làm hết bộ nhớ texture), nên `render_res_publish` chia bù tỉ lệ này trên iOS.

## 6. Mod (ví dụ Việt hoá)

Bản iOS của nhánh này đọc mod RomFS từ thư mục **`Documents/mods`** của app, cùng quy tắc với bản Mac
([mods.md](mods.md)): chỉ các file có trong `manifest.tsv` mới được dùng.

1. Chuẩn bị mod và tạo `manifest.tsv` trên Mac như [mods.md](mods.md) (dùng app Mac cùng phiên bản 1.4.3).
2. Chép vào máy (mỗi file một lệnh, giữ nguyên đường dẫn RomFS):

```bash
xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer --domain-identifier com.yourname.totk \
  --source manifest.tsv --destination Documents/mods/manifest.tsv
```

Cũng có thể dùng app **Files → On My iPhone/iPad → (tên app) → mods**. Log của game
(`Documents/log.txt`) có dòng `Documents/mods checked, N files` khi mod được nạp.

Bản 1.4.3 dùng file chữ `Mals/USen.Product.142.sarc.zs` và bảng `System/Resource/ResourceSizeTable.Product.143.Nin_NX_NVN.rsizetable.zs`.
Mod làm cho 1.4.2 thường có bảng `.142`: phải sửa các mục của file bị thay trong bảng `.143` gốc (lấy kích thước lớn
hơn) và đặt tên `.143`, nếu không file lớn hơn bản gốc có thể làm game crash.

## 7. Chép save giữa các máy

Save nằm ở `Documents/save` của app. Không có đồng bộ tự động: chép theo **một chiều**, từ máy chơi gần nhất, và sao
lưu trước.

```bash
# xem danh sách file
xcrun devicectl device info files --device <UDID nguồn> --domain-type appDataContainer \
  --domain-identifier com.yourname.totk --subdirectory Documents/save
# chép từng file về Mac rồi sang máy kia, giữ nguyên đường dẫn, ví dụ:
xcrun devicectl device copy from --device <UDID nguồn> --domain-type appDataContainer --domain-identifier com.yourname.totk \
  --source Documents/save/save/<id>/slot_00/progress.sav --destination backup/save/<id>/slot_00/progress.sav
xcrun devicectl device copy to --device <UDID đích> --domain-type appDataContainer --domain-identifier com.yourname.totk \
  --source backup/save/<id>/slot_00/progress.sav --destination Documents/save/save/<id>/slot_00/progress.sav
```

Chép cả `account.uid` và toàn bộ thư mục `save/<id>/` (các `slot_*`, `option.sav`, `album`). Hai máy dùng cùng
`account.uid` thì game mở đúng thư mục save đó.

## 8. Đóng góp shader

Khi gặp shader chưa có trong danh sách chung, game ghi vào `Documents/shader-list-contribution.txt`. Agent trên Mac
(`games/totk/ios/tools/shader_contrib_watch.py`, cài khi build iOS) cứ 10 phút kiểm tra máy đang kết nối (cáp hoặc
cùng Wi‑Fi), và mỗi 500 shader mới thì hỏi một lần bằng hộp thoại trên Mac để gửi lên GitHub issue. Gỡ:
`python3 games/totk/ios/tools/shader_contrib_watch.py uninstall`.
