# Changelog

## v1.1.1 — 2026-11-21

- VRAM pressure now **overrides** the hot-time guarantee: the model is released ~5 s after pressure is detected, even if it was loaded moments ago. `MinHotSeconds` removed.
- New `PressurePolls = 5` (was `FastToGamePolls = 8` for the loaded-model path): measured switch **5.1 s** after a 900 MiB CUDA allocation.
- With no pressure there is no idle timer at all (`idle_unload_s: 0`), so the model stays in VRAM indefinitely.
- A real game initially did not trigger a switch because the old 5-minute minimum was still in force; that gate is gone.

## v1.1.0 — 2026-11-21

- **No idle timer in fast mode:** `idle_unload_s` 20 -> 0. The model loads on request and stays in VRAM until another application needs the memory.
- **Minimum hot time:** new guard parameter `MinHotSeconds = 300`. VRAM pressure cannot move the model out during the first 5 minutes after a load; a running request refreshes the timer.
- **Pressure detection without process names:** on Windows WDDM, `nvidia-smi` cannot report VRAM per process, so the fast config now reserves ~4 GB (`--vram-reserve-mib 4000`) and the guard watches for free VRAM dropping below `PressureFreeMib = 1500` while loaded (~8 s sustained). Normal idle free VRAM is ~2.4 GB, so there are no false alarms.
- The RAM/SSD config keeps `idle_unload_s: 20` so free VRAM rises again and the guard can switch back to fast mode after the other app releases the GPU.
- Launcher comments and README updated for the new criterion.

## v1.0.9 — 2026-11-20

- `PollSeconds` 2 -> 1 with `FastToGamePolls` 4 -> 8 and `GameToFastPolls` 6 -> 12: same ~8 s / ~12 s switch timing, finer-grained detection.
- One `/health` request per poll now supplies both server-up and model-loaded state (was two requests).
- Log rotation: guard log and engine logs are archived to `.old-<timestamp>.log` when they exceed 5 MB.

## v1.0.8 — 2026-11-20

- Orphaned engine processes are now cleaned up even when their parent server died: `Get-OurEnginePids` also matches our model-file tag.

## v1.0.7 — 2026-11-20

- Aligned `min_free_vram_mib` (5000 → 11000) with the guard's `FastToGameMs` threshold, removing the window where the server tried to load with too little VRAM.
- A deferred switch now re-checks free VRAM before being applied, so a stale target is corrected.
- Cleanup is scoped: only servers started with our configs and their child `strata-poly`/`strata-vision` processes are stopped; `Stop-Server` also verifies the process name.

## v1.0.6 — 2026-11-20

- `--max-context` reduced 131072 → 65536 in both configs: smaller KV cache, less memory, faster load.
- `--conversation-cache-mib` changed from `auto` to 1024: avoids parking several GB of RAM.
- Added `fit_max_tokens: true` because with a 65536-token context, OpenCode sends `max_tokens=65536`; without this flag the server rejects the request with 400.

## v1.0.5 — 2026-11-20

- Idle unload set back to 20 seconds in both configs (was 180 s): VRAM is released quickly after inactivity so the guard can react fast when a game opens.

## v1.0.4 — 2026-11-20

- **Idle unload set to 3 minutes (180 s)** in both configs (was 20 s): fewer cold starts, model stays ready longer.
- **Fixed a false "another app owns VRAM" switch during model loading**: `/health` reports `loaded=false` while the engine is still starting, so the guard now also checks whether `strata-poly`/`strata-vision` exists before trusting a low VRAM reading. Previously, a low reading during loading caused an unnecessary switch to RAM/SSD mode right in the middle of a load.

## v1.0.3 — 2026-11-20

Major redesign of mode detection.

- **Removed all process-name / GPU-process heuristics.** The guard no longer looks at `nvidia-smi` process lists at all — no `$NeverGame` whitelist, no false "VS Code / Phone Link / browser is a game" detections.
- **Mode is now decided only from free VRAM**, with hysteresis: `< 11 GB` for ~8 s → RAM/SSD mode; `> 13 GB` for ~12 s → fast GPU mode; between the two thresholds the current mode is kept.
- While the model itself is loaded in fast mode, the VRAM reading is ignored (the model occupies ~12 GB); it unloads after 20 s idle so the next reading is meaningful.
- `idle_unload_s` reduced from 60 to 20 in both configs so the guard gets a clean VRAM signal sooner.
- Mode switches remain deferred while a request is running (`Test-Busy` + `$pending`), so no task is ever interrupted.

## v1.0.2 — 2026-11-20

- **Fixed another false game detection**: `Code.exe` (VS Code) and other GPU-accelerated editors/IDEs are now excluded, so opening an editor no longer toggles between game and fast mode.
- **Added a low-VRAM fallback**: when the model is not loaded and another GPU app (e.g. ComfyUI) leaves less than 6 GB free for ~8 s, the guard switches to RAM/SSD mode. Requests are answered instead of failing with `the GPU is in use by another program`.
- Combined with the existing VRAM sanity check, the guard now adapts in both directions based on actual VRAM availability.

## v1.0.1 — 2026-11-20

Bug-fix release.

- **Fixed false game detection** at startup: `PhoneExperienceHost.exe` (Windows Phone Link) and other Windows/NVIDIA background processes are now excluded from game detection.
- **Added a system-path filter**: executables under `C:\Windows` or the NVIDIA driver folder can no longer be mistaken for a game.
- **Added a VRAM sanity check**: in game mode, if more than 10 GB of VRAM stays free for ~12 s, the guard switches back to fast GPU mode on its own — even if a process is still (incorrectly) flagged as a game.
- **Orphan cleanup**: leftover PolyStrata server processes that no longer listen on port 8080 are now removed on start.

## v1.0.0 — 2026-11-20

First documented release of the on-demand adaptive VRAM setup for PolyStrata / MiniCPM-V 4.7.

### Features

- **On-demand loading** (`lazy_load: true`): the server starts without the model, so VRAM is free immediately (~14.8 GB free on an RTX 5070 Ti).
- **Full GPU capacity when called**: a request loads the model with no `--no-gpu-experts`, using the whole GPU; measured cold start ~15 s.
- **Automatic unload** (`idle_unload_s: 60`): the model leaves VRAM 60 s after the last request; verified to return to ~14.9 GB free.
- **Game mode**: `nvidia-smi` process detection switches the server to a config with `--no-gpu-experts` and `--vram-reserve-mib 13000`. All 10 240 experts stay in RAM/SSD (0 in VRAM), so the game keeps its VRAM while the model remains callable.
- **Never interrupt a task**: config switches are deferred until the current request finishes. An in-flight review is never killed.
- **Stale-port cleanup**: old Python servers left on port 8080 are removed before each start.
- **No browser** on launch; status and server output are printed to the console.
- **VRAM safety net**: `min_free_vram_mib: 5000` refuses to load if free VRAM is too low (fallback if game detection fails).
- **Conservative status check**: if `/status` cannot be read, the guard assumes a task is running and does not switch.
- **Re-check before deferred switch**: game state is re-evaluated right before applying a postponed switch, so a stale mode is never applied.

### Notes

- This engine (`strata-poly`) cannot move weights live between VRAM and RAM; mode changes require a server restart. The guard handles that automatically.
- The original launcher and config are untouched; the adaptation is fully separate.
- See `README.md` for installation, settings and how to adapt it to another model.
