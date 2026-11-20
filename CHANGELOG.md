# Changelog

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
