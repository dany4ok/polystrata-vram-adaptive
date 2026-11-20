# PolyStrata — on-demand adaptive VRAM setup

Scripts and configs for a local PolyStrata / llama.cpp-style server that:

- **does not keep the model in VRAM when it is not used** (`lazy_load`, short idle unload);
- **uses the full GPU when a review request arrives** (no `--no-gpu-experts`);
- **moves to RAM + SSD when another application actually needs VRAM** (games, ComfyUI, anything else) — decided from **free VRAM only**, not from process names.

No process-name heuristics: opening VS Code, a browser, or any GPU-accelerated app can no longer be mistaken for a game.

## How the mode is chosen

The guard reads `nvidia-smi --query-gpu=memory.free` every 2 seconds:

| Free VRAM | Mode | Config |
|---|---|---|
| `< 11 GB` for ~8 s (and model not loaded) | RAM/SSD — 0 experts in VRAM | `strata-minicpmv-q4_k_m-cpu.json` |
| `> 13 GB` for ~12 s | Fast GPU — full capacity on demand | `strata-minicpmv-q4_k_m-review.json` |
| between 11 and 13 GB | keep the current mode | — |

The 2 GB gap between thresholds prevents flapping. While the model itself is loaded in fast mode it occupies ~12 GB, so free VRAM is not a valid signal and the guard does not switch; the model unloads after 20 s idle and the measurement becomes meaningful again. A switch is always deferred while a request is running, so an in-flight task is never killed.

## Files

| File | Role |
|---|---|
| `run-minicpmv-q4_k_m-auto.bat` | Launcher. Starts the guard in a visible console; **no browser**. Closing the window stops the server. |
| `serve/vram-guard.ps1` | Guard: VRAM-only mode selection, config switching, stale-port cleanup, console status. |
| `strata-minicpmv-q4_k_m-review.json` | Fast config: full GPU, `lazy_load`, `idle_unload_s=20`, `min_free_vram_mib=5000`. |
| `strata-minicpmv-q4_k_m-cpu.json` | RAM/SSD config: `--no-gpu-experts`, `--vram-reserve-mib 13000`, `vision.gpu=false`, `lazy_load`, `idle_unload_s=20`. |

## Installation

1. Copy the four files into the Poly-strata installation (keep `vram-guard.ps1` in `serve\`).
2. Edit the absolute paths in both `.json` files (`exe`, `model`, `mmproj`, `expert-profile`, `tokenizer`, `log`, `lib_dirs`) and in the `.bat` (Python and `serve\server.py`).
3. Create a desktop shortcut to the `.bat`.
4. Leave the original `run-minicpmv-q4_k_m.bat` and its config untouched.

## Settings

| Setting | Value | Why |
|---|---|---|
| `lazy_load: true` | both configs | Server starts without the model; VRAM is free immediately |
| `idle_unload_s: 20` | both configs | Model leaves VRAM quickly so the guard gets a clean VRAM reading |
| `min_free_vram_mib: 5000` | review config | Safety net if a switch has not happened yet: refuse to load rather than starve the other app |
| `--no-gpu-experts` | RAM/SSD config only | All 10 240 experts stay in RAM/SSD; 0 in VRAM |
| `--vram-reserve-mib 13000` | RAM/SSD config only | Leaves ~13 GB VRAM for the other app |
| `FastToGameMs = 11000` | guard | Below this, another app owns the GPU → RAM/SSD mode |
| `GameToFastMs = 13000` | guard | Above this, the GPU is free again → fast mode |
| `FastToGamePolls = 4` / `GameToFastPolls = 6` | guard | ~8 s / ~12 s hysteresis; avoids flapping |
| Deferred switching | guard | Uses `Test-Busy` + `$pending`; a running task is never interrupted |

## Adapting to another model

1. Start from that model's working Poly-strata config.
2. Make a `-review.json` copy and add `lazy_load: true`, `idle_unload_s: 20`, `min_free_vram_mib`.
3. Make a `-cpu.json` copy and add `--no-gpu-experts`, `--vram-reserve-mib <almost all VRAM>`, `vision.gpu: false`, `lazy_load`, `idle_unload_s: 20`.
4. In `vram-guard.ps1`, point `$FastCfg` and `$GameCfg` at the new files.
5. Adjust `FastToGameMs` / `GameToFastMs` for the card's total VRAM (roughly total minus the model's GPU footprint minus a safety margin).

> This engine (**strata-poly**) has no `-ngl`, no `--vram-elastic`, and no pure-CPU mode. Weights cannot be moved live between VRAM and RAM; mode changes require a server restart. The guard does that automatically.

## Troubleshooting

- **`port 8080 is already in use`** — `Free-Port` removes stale servers on every start.
- **Other app still slow** — check the guard log for `trecere in modul joc` and the engine log for `0 of 10240 routed experts in VRAM`. If the app uses less than ~5 GB VRAM, the model legitimately fits alongside it.
- **`the GPU is in use by another program`** — a request arrived during the ~8 s detection window; it will be retried and succeed after the switch. Lower `min_free_vram_mib` only if you accept a temporary VRAM squeeze.
- **Empty answer to "hello"** — MiniCPM-V 4.7 is a reasoning model and sometimes ends its turn inside the `` block (PolyStrata issue #1053). `reasoning_close_retry` is opt-in; larger `max_tokens` or low effort helps. Unrelated to this adaptation.

## What was NOT changed

The original `run-minicpmv-q4_k_m.bat` and `strata-minicpmv-q4_k_m.json` are untouched.

## Verification

Tested live: startup with model unloaded, full-GPU load on request, auto-unload, RAM/SSD mode with 0 experts in VRAM, and bidirectional VRAM-driven switching. Independent review: ✓ Verified.
