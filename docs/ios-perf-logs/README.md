# iPhone game logs (TotK 1.4.3)

Raw `Documents/log.txt` files behind [ios-performance-notes.md](../ios-performance-notes.md). This folder holds logs
only; leave it out when proposing the code upstream.

The app's container paths are replaced with `<data container>` and `<app bundle>`; nothing else is changed. The logs
hold no game data. Each start replaces `log.txt` on the device, so every file is one run.

## 2026-10-22, iPhone 15 Pro (iOS 27), bundle `com.kiluss.totk`

All runs: builds of that day (each file has the switches added by then), 720p, render scale 100%, a Việt hoá RomFS
mod loaded.

| File | Run | Settings |
|---|---|---|
| `1-first-start-60fps.log` | First start after install, about 1,500 frames | no frame-rate cap (60 FPS), keep-alive on |
| `2-play-20min.log` | 20 minutes of real play: notes section 1 (clock falls after ~2 minutes) | 30 FPS cap, performance overlay on (`2-play-20min-settings.txt`), keep-alive on |
| `3-idle-keepalive-off.log` | 22 minutes standing in the open world after 8 minutes of rest: notes section 2, run A | 30 FPS cap, `TOTK_GPU_KEEPALIVE=0` |
| `4-idle-keepalive-on.log` | The same, run B, another spot | 30 FPS cap, keep-alive on, `TOTK_AUTOLOAD=1` |
| `5-check-keepalive-switch.log` | Short check of the build with the GPU keep-alive (testing) switch | default (on) |
| `6-check-thermal-logging.log` | Short check of the thermal logging build (`thermal state` lines, `温控 0`) | default |
| `7-check-translation-thread-on.log` | Short check with Translation thread (testing) On: boots into the world at 30 FPS; the app went to the background at about 52 s, so it says nothing about long play | `TOTK_ASYNC_REPLAY=1` |
| `8-play-19min-keepalive-off.log` | About 19 minutes of real play with the keep-alive off: notes section 2b (test plan step 1; clock holds at ~2.7 GHz, thermal fair at 7.2 min, serious at 10.2 min) | 30 FPS cap, performance overlay on, keep-alive off from the menu (`8-play-19min-keepalive-off-settings.txt`), translation thread off |

The lines to read are listed in the notes (`翻译细项`, `计时`, `上屏`, `[长帧]`, `游戏设出图间隔`, `thermal state`).
For example, the average clock per 300 frames:

```bash
grep -oE "翻译细项 至帧 [0-9]+|平均主频 [0-9.]+ GHz" 2-play-20min.log | paste - -
```
