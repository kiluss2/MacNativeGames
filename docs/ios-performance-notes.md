# iPhone performance notes (1.4.3)

Measurements on an iPhone 15 Pro (iOS 27) and what they led to: the two **(testing)** options in the settings menu
([ios-settings.md](ios-settings.md)) and thermal state in the log. Status as of 2026-10-22. The raw logs of every run
below are on branch [`ios-perf-logs`](https://github.com/kiluss2/MacNativeGames/tree/ios-perf-logs) (logs only).

All numbers come from the game's own log, `Documents/log.txt` in the app container
(`xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier <bundle id>
--source Documents/log.txt --destination log.txt`). The lines used:

| Log line | What it gives (per 300 frames) |
|---|---|
| `翻译细项 至帧 N` | cycles per frame on the thread that replays submits, its CPU time, and their ratio, the average clock (`平均主频`) |
| `计时 至帧 N` | frame time, submit + present time and GPU time (p50 / p95 / max) |
| `上屏 至帧 N` | present p99, memory footprint, thermal state (`温控`; -1 before the logging below) |
| `[长帧]` | each frame over the budget: submit + present, GPU, new pipelines and shader libraries |
| `游戏设出图间隔 a → b` | the game's own frame-rate controller changing the present interval (2 = 30 FPS, 3 = 20 FPS) |
| `thermal state` | the iOS thermal state at start and on each change, with seconds since start |

## 1. A 20-minute play session (keep-alive on, the default)

720p, render scale 100%, 30 FPS cap, about 17 minutes of logged frames.

- **The CPU clock collapses after about 2 minutes.** The replay thread does about 20 M cycles per frame throughout.
  In the first 2 minutes that took 6 ms at 3.4–3.6 GHz. From minute 3 on, about two thirds of the 300-frame windows
  ran at 1.1–1.6 GHz and most others at 1.8–2.4 GHz (one at 3.2), and the same work took 12–24 ms. GPU time went from 9 ms to 13–22 ms in the heavier stretches.
- **466 frames over budget.** 93 met new pipelines or shader libraries (13.9 s compiling on the submit thread, 55 of them
  over 100 ms). Of the other 373: 161 with submit + present over 25 ms, 33 GPU-bound, 179 with both short (the time
  went to the game's own CPU work).
- **Memory is not the limit here:** footprint 3.3–3.6 GiB with about 2.5 GiB left.
- The device's `pso_user.tsv` grew from 3,570 to 3,809 rows, warmed on later starts.

The log could not tell heat from scheduling: the thermal state was always -1, and one load sample showed the
performance cores at 0% and the efficiency cores at 87%.

## 2. Idle A/B: GPU keep-alive off and on

GPU keep-alive (`TOTK_GPU_KEEPALIVE`, gfx/nvn/nvn_mtl.m) keeps the GPU busy with ~1 ms spin kernels between frames,
so it does not lower its clock; it was tuned on an M4 Mac. In session 1 it ran 10–15 kernels per frame.

Two runs launched with `devicectl` (A with `TOTK_GPU_KEEPALIVE=0`, B with `TOTK_AUTOLOAD=1`), 30 FPS cap, the phone
left standing in the open world for 22 minutes each, after 8 minutes of rest each.

| Last 5 minutes | A: keep-alive off | B: keep-alive on |
|---|---|---|
| Work per frame (replay thread) | 30.4 M cycles | 18.9 M cycles |
| Average clock | 2.44 GHz | **1.09 GHz** |
| CPU time per frame | 12.5 ms | 17.3 ms |
| GPU time per frame (p50) | ~29 ms (GPU 85–90% busy) | ~14 ms, plus ~12 spin kernels |
| Clock over the run | 3.65 GHz at start, easing to 2.4 (one window at 1.9) | 3.15 at start, **1.5 at minute 2**, 1.09 at the end |
| Frames over 50 ms after the first 2 minutes | 24 | 115 (most in one burst when the work rose to 30–35 M cycles) |
| Frame interval p99 (mean of windows) | 37.9 ms | 39.7 ms |

- With keep-alive off the CPU held twice the clock while doing about 60% more work per frame; with it on it fell the
  way it did in session 1.
- With it off the GPU ran slowly enough to fill ~29 of the 33 ms. That is efficient while it keeps up; a heavier scene
  needs it to raise its clock in time.
- In A the game's controller set the 20 FPS interval 612 times (B: 12) without a matching rise in frame intervals. To
  watch in play.
- **Limits:** one run each, different spots (A's had more CPU work; GPU work not comparable), idle rather than play.

## 2b. Real play: keep-alive off (test plan step 1)

The same settings as session 1 (720p, 100%, 30 FPS cap), about 19 minutes of real play with keep-alive off and the
translation thread off. From minute 3 on, against session 1 (keep-alive on):

| | Session 1: on | Step 1: off |
|---|---|---|
| Average clock (replay thread), median of windows | 1.49 GHz | **2.72 GHz** |
| Windows under 1.7 GHz | 66% | **5%** |
| Work per frame / replay CPU time | 22.1 M cycles / 14.7 ms | 25.4 M cycles / **8.4 ms** |
| Submit + present p50 / p95 | 14.1 / 23.3 ms | **8.5 / 10.2 ms** |
| GPU p50 / p95 | 13.3 / 17.6 ms | 28.3 / 30.5 ms (GPU 84–88% busy) |
| Frames over budget per 1,000 frames | 17.7 | **12.8** |
| Frames over 50 ms | 319 | **154** |
| Over budget without compiles: submit > 25 ms / GPU > 25 ms | 183 / 75 | 33 / 141 |
| Present p99 (mean of windows) | 55.0 ms | **46.5 ms** |
| 20 FPS interval set by the game | 125 | 186 |
| Footprint | 3.4–3.7 GiB | 3.5–3.7 GiB |
| Thermal state | not logged (-1) | nominal → fair at 7.2 min → serious at 10.2 min, to the end |

- Off, the CPU keeps its clock through the whole session, and the clock stayed at 2.5–3.4 GHz while the phone was at
  serious, so session 1's collapse is not heat alone: it follows the keep-alive. Long stutters halved.
- The GPU runs slower and fills ~28 of the 33 ms; GPU-bound long frames rose (75 → 141), the trade-off section 2
  expected for heavier scenes.
- Heat cannot be compared: session 1 has no thermal state. The phone still reaches serious at 10 minutes with it off,
  so 720p / 100% / 30 FPS is warm on an iPhone 15 Pro either way. By the physics, dropping the spin kernels saves GPU
  power while the faster CPU spends more, so the net is probably cooler or the same.
- Decision: keep-alive **off by default on the iPhone**; the iPad keeps it on until measured.

## 3. What changed (branch `ios-settings-menu`)

- **GPU keep-alive (testing)**, menu, default Off on the iPhone and On on the iPad (since 2b); the other choice sets
  `TOTK_GPU_KEEPALIVE` at the next launch.
- **Thermal state in the log:** `dm_thermal_now()` had only its weak -1 default on iOS. The iOS front end now returns
  `NSProcessInfo.thermalState` (0 nominal, 1 fair, 2 serious, 3 critical) and logs each change.
- **Translation thread (testing)**, menu, default Off: On sets `TOTK_ASYNC_REPLAY=1`. Comments in gfx/nvn/hle_nvn.c call
  the translation thread the iPhone default, but nothing set it on iOS, so submits are replayed on the game's render
  thread after the frame's game logic. On, the replay runs on its own thread while the game works on the next frame.
  Aimed at the stutters where game logic and replay add up; it does not reduce heat and keeps extra command copies
  (more memory).

Ruled out: the render thread's real-time budget. It is already adaptive (p90 of its CPU time × 1.25, at most 0.9 of the
period), so it follows the measured time and is not under-declared.

To watch with the translation thread On: that thread declares a fixed half period (`set_time_constraint_comp_x`,
16.7 ms at 30 FPS). Once the clock fell in session 1 the replay took 12–24 ms per frame, and the comments there note
that a thread exceeding its declaration gets demoted. If On shows the clock collapse, make that budget adaptive like
the render thread's.

## 4. Test plan

Same settings as session 1 (720p, 100%, 30 FPS cap), about 20 minutes of real play each, the phone at rest for a few
minutes before each run. Copy `Documents/log.txt` after each run, before the game starts again (a new start replaces it).

1. **Keep-alive Off, translation thread Off.** Against session 1: average clock, thermal state, frames over budget,
   20 FPS switches, GPU time in heavy scenes. Done: section 2b.
2. **Translation thread On** (keep-alive as decided by step 1). Watch for wrong pictures or a crash. Against step 1:
   frames over budget split as in section 1, frame interval p99, footprint.

## 5. Open items not covered here

- Pipelines met in play are not added to the pipeline archive on the iPhone (upstream 30a1b93); the 93 pipeline
  stutters of session 1 are that.
- Sharing pipelines between players: [kiluss2/MacNativeGames#1](https://github.com/kiluss2/MacNativeGames/issues/1).
