# PolyStrata — on-demand adaptive VRAM setup

Scripts and configs for a local PolyStrata / llama.cpp-style server that:

- **does not keep the model in VRAM when it is not in use** (starts empty, unloads itself after inactivity);
- **uses the full GPU when a review request arrives** (full load, no `--no-gpu-experts`);
- **switches to RAM + SSD when a game is running** (`--no-gpu-experts`), so the game keeps its VRAM while the model stays callable.

The model does not need to be "always on". A cold start of about 15 seconds is acceptable.

## States

| Situation | Config in use | What happens |
|---|---|---|
| Startup, no game | `strata-minicpmv-q4_k_m-review.json` | Server is up in ~5 s, **model is not loaded**, ~14.8 GB VRAM free |
| A request arrives | same config | Model loads into VRAM, answers, then unloads after 60 s of inactivity |
| Game detected (~4 s) | `strata-minicpmv-q4_k_m-cpu.json` | **If a task is running, the switch is deferred until it finishes** (nothing is interrupted). Then the server restarts with **0 experts in VRAM**; ~13 GB VRAM reserved for the game; model still answers in ~1–2 s from RAM/SSD |
| Game closed | back to review config | Fast restart (the model is not loaded until the first request) |

## Files

| File | Role |
|---|---|
| `run-minicpmv-q4_k_m-auto.bat` | Launcher. Starts the guard in a visible console; **does not open a browser**. Closing the window stops the server too. |
| `serve/vram-guard.ps1` | Guard: detects games via `nvidia-smi`, switches configs, frees port 8080, prints status to the console. |
| `strata-minicpmv-q4_k_m-review.json` | "Fast" config: full GPU, `lazy_load`, `idle_unload_s=60`, `min_free_vram_mib=5000`. |
| `strata-minicpmv-q4_k_m-cpu.json` | "Game" config: `--no-gpu-experts`, `--vram-reserve-mib 13000`, `vision.gpu=false`, `lazy_load`, `idle_unload_s=60`. |

## Installation on another machine

1. Copy the four files into the root of the Poly-strata installation (keep `serve/vram-guard.ps1` inside `serve\`).
2. Edit the absolute paths in both `.json` files (`exe`, `model`, `mmproj`, `expert-profile`, `tokenizer`, `log`, `lib_dirs`) and in the `.bat` (the path to Python and `serve\server.py`).
3. Create a desktop shortcut pointing to the `.bat`.
4. Do not modify the original `run-minicpmv-q4_k_m.bat` or its config — this adaptation is completely separate.

## Settings that matter

| Setting | Value | Why |
|---|---|---|
| `lazy_load: true` | both configs | Server starts without the model; VRAM is free immediately |
| `idle_unload_s: 60` | both configs | After 60 s without requests, the model leaves VRAM/RAM |
| `min_free_vram_mib: 5000` | review config | If game detection fails, refuse to load instead of starving the game |
| `--no-gpu-experts` | game config only | All experts stay in RAM/SSD; 0 in VRAM |
| `--vram-reserve-mib 13000` | game config only | Leaves ~13 GB VRAM for the game |
| `PollSeconds=2`, `PersistPolls=2` | guard | Detection in ~4 s; filters out transient processes |
| Deferred switching | guard | A config switch is **postponed until the current request finishes** — an in-flight task is never killed. A long task may temporarily slow the game; the switch is applied as soon as the server becomes idle |
| `$NeverGame` | guard | GPU processes that are not games (Windows, Steam, Game Bar, browsers, Phone Link). Add any app here that causes a false switch. |
| System-path filter | guard | Any GPU process whose executable lives under `C:\Windows` or the NVIDIA driver folder is ignored, so unknown Windows/UWP apps cannot be mistaken for a game. |
| VRAM sanity check | guard | In game mode, if more than 10 GB of VRAM stays free for ~12 s, the guard assumes there is no real game and switches back to fast mode. This self-corrects stale false detections. |

## Adapting it to another model

1. Start from the config that already works for that model (its original Poly-strata config).
2. Copy it to `strata-<model>-review.json` and add: `lazy_load: true`, `idle_unload_s: 60`, `min_free_vram_mib` (the heavier your game, the higher this value).
3. Copy it to `strata-<model>-cpu.json`, add `--no-gpu-experts`, `--vram-reserve-mib <almost all VRAM>`, `vision.gpu: false`, `lazy_load`, `idle_unload_s`.
4. In `vram-guard.ps1`, change `$FastCfg` and `$GameCfg` to the new files.
5. Confirm the engine accepts the flags (`--no-gpu-experts` is listed in `strata-poly --help`); older engines may not have them.
6. Tune `$NeverGame` for the processes on your machine.

> Note: this engine (**strata-poly**) has no `-ngl`, no `--vram-elastic`, and no pure-CPU mode. The model cannot be moved "live" between VRAM and RAM; the only way is to restart the server with a different config. That is exactly what the guard does.

## Troubleshooting

- **`port 8080 is already in use`** — the guard frees the port automatically on every start (`Free-Port`). If it persists, check for leftover Python processes manually.
- **Game still at 3 fps** — the model is still in VRAM. Check the logs: you should see `trecere in modul joc` and, in the engine log, `0 of 10240 routed experts in VRAM`.
- **False detection** (e.g. switching when you open a browser) — add that process name to `$NeverGame`.
- **Empty answer to "hello"** — this is not caused by this adaptation. MiniCPM-V 4.7 is a reasoning model: it emits a `` block first and sometimes sends its stop token while still inside the thought, producing no final answer (issue #1053 in PolyStrata). The server has `reasoning_close_retry`, but it is opt-in. A larger `max_tokens` or `reasoning_effort: low` reduces the problem. Nothing was changed in this regard.

## What was NOT changed

The original `run-minicpmv-q4_k_m.bat` and `strata-minicpmv-q4_k_m.json` are untouched. The adaptation is fully separate and can be deleted without affecting the installation.

## Verification

The flow was tested live: startup with the model unloaded (~14.8 GB VRAM free), a request loading the model to ~15.5 GB and answering correctly, automatic unload after 70 s idle, the game config with 0 experts in VRAM, and a close → reopen cycle with no orphan servers. Independent review: ✓ Verified.
