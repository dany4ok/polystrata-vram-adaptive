# Changelog

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
