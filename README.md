# PolyStrata — on-demand adaptive VRAM setup

Scripts and configs for a local PolyStrata / llama.cpp-style server that:

- **loads the model into VRAM on the first request and keeps it hot** — there is no idle timer (`idle_unload_s: 0`);
- **keeps it hot as long as there is no VRAM pressure** (no timer at all, so well beyond 5 minutes);
- **releases VRAM ~5 s after pressure appears**, overriding any hot-time guarantee;
- **moves to RAM + SSD when another application actually needs VRAM** (games, ComfyUI, anything else) — decided from **free VRAM only**, not from process names or a timer.

No process-name heuristics: opening VS Code, a browser, or any GPU-accelerated app can no longer be mistaken for a game.

## How the mode is chosen

The guard reads `nvidia-smi --query-gpu=memory.free` every 1 second:

| Free VRAM | Mode | Config |
|---|---|---|
| `< 11 GB` for ~8 s (and model not loaded) | RAM/SSD — 0 experts in VRAM | `strata-minicpmv-q4_k_m-cpu.json` |
| `> 13 GB` for ~12 s | Fast GPU — full capacity on demand | `strata-minicpmv-q4_k_m-review.json` |
| model loaded, `< 1.5 GB` for ~5 s | RAM/SSD — another app took the reserved headroom; hot time is overridden | `strata-minicpmv-q4_k_m-cpu.json` |
| between the thresholds | keep the current mode | — |

The fast config reserves ~4 GB (`--vram-reserve-mib 4000`), so free VRAM stays a meaningful signal **even while the model is loaded**. On Windows WDDM, `nvidia-smi` cannot report VRAM per process (`Not available in WDDM driver model`), so the guard detects another app by the drop in free VRAM instead of by process names. Pressure overrides hot time: as soon as free VRAM stays below the floor for ~5 s, the model is moved out, even if it was just loaded. With no pressure there is no idle timer at all, so it stays in VRAM indefinitely. The 2 GB gap between the unloaded thresholds prevents flapping. A switch is always deferred while a request is running, so an in-flight task is never killed.

## Files

| File | Role |
|---|---|
| `run-minicpmv-q4_k_m-auto.bat` | Launcher. Starts the guard in a visible console; **no browser**. Closing the window stops the server. |
| `serve/vram-guard.ps1` | Guard: VRAM-only mode selection, config switching, stale-port cleanup, console status. |
| `strata-minicpmv-q4_k_m-review.json` | Fast config: full GPU, `lazy_load`, `idle_unload_s=0`, `--vram-reserve-mib 4000`, `min_free_vram_mib=11000`. |
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
| `idle_unload_s: 0` | fast config | No idle timer at all: the model stays loaded until another app needs the VRAM. This is the criterion that replaces the old 20 s timer |
| `idle_unload_s: 20` | RAM/SSD config only | Kept so that after a game-mode request the small CPU model unloads and free VRAM rises enough to switch back to fast mode |
| `--vram-reserve-mib 4000` | fast config | Leaves ~2.4 GB free in practice (the engine overshoots the reserve), giving the guard a headroom to detect another app |
| `min_free_vram_mib: 11000` | review config | Matches the guard's `FastToGameMs`: refuse to load while another app holds VRAM, instead of loading into too little and failing |
| `--max-context: 65536` | both configs | Smaller KV cache (was 131072): less VRAM/RAM, faster load |
| `conversation-cache-mib: 1024` | both configs | Small fixed cache instead of `auto` (which could park several GB of RAM) |
| `fit_max_tokens: true` | both configs | Clamps OpenCode's `max_tokens=65536` to the room left by the 65536-token context instead of rejecting the request with 400 |
| `--no-gpu-experts` | RAM/SSD config only | All 10 240 experts stay in RAM/SSD; 0 in VRAM |
| `--vram-reserve-mib 13000` | RAM/SSD config only | Leaves ~13 GB VRAM for the other app |
| `FastToGameMs = 11000` | guard | Below this, another app owns the GPU → RAM/SSD mode |
| `GameToFastMs = 13000` | guard | Above this, the GPU is free again → fast mode |
| `PollSeconds = 1`; `FastToGamePolls = 8` / `GameToFastPolls = 12` | guard | Fine-grained polling with the same ~8 s / ~12 s hysteresis; avoids flapping |
| `PressureFreeMib = 1500` | guard | With the model loaded, free VRAM below this means another app took the reserved headroom. Below the normal idle reading (~2.4 GB), so no false alarms |
| `PressurePolls = 5` | guard | ~5 s of pressure is enough to release VRAM; this overrides any hot-time guarantee. A running request still defers the switch |
| Engine-presence guard | guard | While the engine is still **loading** (`/health` says `loaded=false`), no switch is made. Once loaded, the reserved headroom makes the VRAM reading valid |
| Deferred switching | guard | Uses `Test-Busy` + `$pending`; a running task is never interrupted. VRAM is re-checked before applying, so a stale target is corrected |
| Scoped cleanup | guard | Only servers started with our configs and their engines are stopped. Orphaned engines are still caught via the model-file tag, even if their parent died; another PolyStrata instance is left alone |
| One health call | guard | A single `/health` request provides both server-up and model-loaded state |
| Log rotation | guard | Guard log and engine log are archived when they exceed 5 MB |

## Adapting to another model

1. Start from that model's working Poly-strata config.
2. Make a `-review.json` copy and add `lazy_load: true`, `idle_unload_s: 0`, `min_free_vram_mib`, and `--vram-reserve-mib <headroom>` (enough to leave ~2–3 GB free when loaded).
3. Make a `-cpu.json` copy and add `--no-gpu-experts`, `--vram-reserve-mib <almost all VRAM>`, `vision.gpu: false`, `lazy_load`, `idle_unload_s: 20`.
4. In `vram-guard.ps1`, point `$FastCfg` and `$GameCfg` at the new files.
5. Adjust `FastToGameMs` / `GameToFastMs` for the card's total VRAM and `PressureFreeMib` to sit below the fast-mode idle free VRAM you measure.

> This engine (**strata-poly**) has no `-ngl`, no `--vram-elastic`, and no pure-CPU mode. Weights cannot be moved live between VRAM and RAM; mode changes require a server restart. The guard does that automatically.

## Troubleshooting

- **`port 8080 is already in use`** — `Free-Port` removes stale servers on every start.
- **Other app still slow** - check the guard log for `VRAM luata de alta aplicatie` / `trecere in modul joc` and the engine log for `0 of 10240 routed experts in VRAM`. The switch happens ~5 s after pressure is detected, plus ~5 s for the server restart.
- **`the GPU is in use by another program`** — a request arrived during the ~8 s detection window; it will be retried and succeed after the switch. Lower `min_free_vram_mib` only if you accept a temporary VRAM squeeze.
- **Empty answer to "hello"** — MiniCPM-V 4.7 is a reasoning model and sometimes ends its turn inside the `` block (PolyStrata issue #1053). `reasoning_close_retry` is opt-in; larger `max_tokens` or low effort helps. Unrelated to this adaptation.

## What was NOT changed

The original `run-minicpmv-q4_k_m.bat` and `strata-minicpmv-q4_k_m.json` are untouched.

## Verification

Tested live: startup with model unloaded, full-GPU load on request, model still loaded after 40 s idle (no timer), RAM/SSD mode with 0 experts in VRAM, and bidirectional VRAM-driven switching. A CUDA process allocating 900 MiB while the model was loaded triggered the switch in 5.1 s (measured). A real game (Kingdom Come: Deliverance II) caused a switch at 03:03:56 under the previous hot-time rule; that rule has since been removed so pressure now wins immediately. Independent review: see the release notes.
