param(
    [int]$Port          = 8080,
    [int]$PollSeconds   = 1,       # fine-grained polling; the poll counts below keep the timing
    [int]$FastToGameMs  = 11000,   # free VRAM below this (model NOT loaded) -> another app needs the GPU
    [int]$GameToFastMs  = 13000,   # free VRAM above this -> GPU is free again
    [int]$FastToGamePolls = 8,     # ~8 s of low VRAM before switching to RAM/SSD
    [int]$GameToFastPolls = 12,    # ~12 s of free VRAM before switching back to GPU
    [int]$PressureFreeMib = 1500,  # fast mode, model loaded: free below this = another app took the reserved headroom
    [int]$PressurePolls   = 5      # ~5 s of pressure -> release VRAM, overriding any hot-time guarantee
)

# VRAM-only adaptive guard.
# No process-name heuristics and no idle timer in the fast config (idle_unload_s: 0):
#   model unloaded + free < 11 GB  -> RAM/SSD mode, 0 experts in VRAM
#   free > 13 GB                   -> fast GPU mode (model loads on request)
#   model loaded + free < 1.5 GB   -> another app took the reserved headroom; switch
#                                    to RAM/SSD after ~5 s, regardless of how long the
#                                    model has been loaded (pressure overrides hot time)
# With no pressure there is no idle timer at all (idle_unload_s: 0), so the model stays
# in VRAM indefinitely (well beyond 5 minutes).
# The fast config reserves ~4 GB of VRAM (--vram-reserve-mib 4000) so free VRAM stays
# a meaningful signal while the model is loaded. The gap between thresholds avoids flapping.
# Log + console: strata-adaptive-guard.log

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$Root     = 'C:\Users\x1p\Desktop\Poly-strata'
$FastCfg  = Join-Path $Root 'strata-minicpmv-q4_k_m-review.json'
$GameCfg  = Join-Path $Root 'strata-minicpmv-q4_k_m-cpu.json'
$Python   = Join-Path $Root '.venv\Scripts\python.exe'
$ServerPy = 'serve\server.py'
$Log      = Join-Path $Root 'strata-adaptive-guard.log'
$Base     = "http://127.0.0.1:$Port"

function Rotate-Log([string]$path) {
    try {
        if ($path -and (Test-Path $path) -and (Get-Item $path).Length -gt 5MB) {
            $bak = $path -replace '\.log$', ".old-$(Get-Date -Format yyyyMMdd-HHmmss).log"
            Move-Item $path $bak -Force
        }
    } catch { }
}

function Log([string]$msg) {
    Rotate-Log $Log
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $Log -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-FreeVramMib {
    try {
        $v = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
        if ($v -match '(\d+)') { return [int]$Matches[1] }
    } catch { }
    return $null
}

function Get-Health {
    # One request gives both "server up" and "model loaded".
    try {
        $h = Invoke-RestMethod -UseBasicParsing -Uri ($Base + '/health') -TimeoutSec 5
        return [pscustomobject]@{ Up = $true; Loaded = [bool]$h.loaded }
    } catch {
        return [pscustomobject]@{ Up = $false; Loaded = $false }
    }
}

function Test-Busy {
    # A running or queued request must never be killed by a config switch.
    try {
        $s = Invoke-RestMethod -UseBasicParsing -Uri ($Base + '/status') -TimeoutSec 5
        return [bool]($s.busy -or $s.queued)
    } catch {
        # Unreadable status: behave as if a task is running, never switch blindly.
        return $true
    }
}

function Get-OurServerPids {
    # Only servers started with OUR configs are ours to stop.
    $mine = @()
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and
        $_.CommandLine -like '*serve\server.py*' -and
        ($_.CommandLine -like "*$FastCfg*" -or $_.CommandLine -like "*$GameCfg*")
    } | ForEach-Object { $mine += $_.ProcessId }
    return $mine
}

function Get-OurEnginePids {
    # Engines of our servers, plus orphans whose parent died unexpectedly.
    # The model-file tag identifies our engines even when the parent is gone.
    $servers = @(Get-OurServerPids)
    $mine = @()
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('strata-poly.exe','strata-vision.exe') -and
        (($servers -contains $_.ParentProcessId) -or ($_.CommandLine -like '*minicpmv-Q4_K_M.gguf*'))
    } | ForEach-Object { $mine += $_.ProcessId }
    return $mine
}

function Stop-PidIfOurs([int]$procId) {
    if ($procId -le 0 -or $procId -eq $PID) { return }
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
    if ($p -and $p.Name -in @('python.exe','pythonw.exe','strata-poly.exe','strata-vision.exe')) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
}

function Free-Port {
    $owners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $_.OwningProcess })
    $stale = @(Get-OurServerPids) + @(Get-OurEnginePids)
    foreach ($procId in (@($owners + $stale) | Select-Object -Unique)) {
        Log "eliberez portul $Port / server orfan (PID $procId)"
        Stop-PidIfOurs $procId
    }
    Start-Sleep -Seconds 2
}

function Stop-Server {
    $owners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $_.OwningProcess })
    foreach ($procId in (@($owners + @(Get-OurServerPids) + @(Get-OurEnginePids)) | Select-Object -Unique)) {
        Stop-PidIfOurs $procId
    }
    Start-Sleep -Seconds 2
}

function Start-Server([string]$cfg) {
    Free-Port
    try { $cfgObj = Get-Content $cfg -Raw | ConvertFrom-Json; Rotate-Log $cfgObj.log } catch { }
    $a = @($ServerPy, '--engine', 'strata', '--config', $cfg, '--port', "$Port")
    Start-Process -FilePath $Python -ArgumentList $a -WorkingDirectory $Root -NoNewWindow
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 1
        if ((Get-Health).Up) {
            $mod = 'RAPID (GPU la cerere)'
            if ($cfg -eq $GameCfg) { $mod = 'JOC (RAM/SSD, 0 experti in VRAM)' }
            Log "serverul este gata: $mod"
            return $true
        }
    }
    return $false
}

function Request-Switch([string]$target, [string]$why) {
    if (Test-Busy) {
        if (-not $script:pending) {
            Log "$why -> task in curs, aman comutarea (nu opresc nimic)."
            $script:pending = $target
            $script:pendingSince = Get-Date
        }
        return
    }
    Log "$why -> trec in modul $target"
    $cfg = if ($target -eq 'game') { $GameCfg } else { $FastCfg }
    if (Switch-To $target $cfg) { $script:mode = $target }
}

function Switch-To([string]$newMode, [string]$cfg) {
    $previous = $script:mode
    Log "trecere in modul $newMode"
    Stop-Server
    if (Start-Server $cfg) {
        Log "trecere reusita."
        return $true
    }
    Log "pornire esuata; revin la modul $previous"
    $backCfg = if ($previous -eq 'game') { $GameCfg } else { $FastCfg }
    if (-not (Start-Server $backCfg)) { Log "revenirea a esuat; verifica logul serverului." }
    return $false
}

Log "=== adaptive guard start (doar VRAM, fara detectare de procese) ==="

# Decide initial mode from VRAM: a low reading means another app already owns the GPU.
$free = Get-FreeVramMib
if ($null -ne $free -and $free -lt $FastToGameMs) {
    Log "VRAM ocupata la pornire ($free MiB libere) -> mod joc (RAM/SSD)"
    $mode = 'game'
    $ok = Start-Server $GameCfg
} else {
    Log "VRAM libera la pornire ($free MiB) -> mod rapid (GPU la cerere)"
    $mode = 'fast'
    $ok = Start-Server $FastCfg
}
if (-not $ok) { Log "serverul nu a pornit; iesire."; exit 1 }
Log "modelul NU e incarcat; se incarca la prima cerere si ramane in VRAM cat timp nu e presiune. Daca alta aplicatie cere memorie, eliberez VRAM in ~$PressurePolls s."

$script:mode = $mode
$pending = $null
$pendingSince = $null
$lowCount = 0
$highCount = 0
$down = 0

while ($true) {
    Start-Sleep -Seconds $PollSeconds

    $health = Get-Health
    if (-not $health.Up) {
        $down++
        if ($down -ge 3) {
            Log "serverul nu raspunde; repornesc in modul $($script:mode)"
            Stop-Server
            $cfg = if ($script:mode -eq 'game') { $GameCfg } else { $FastCfg }
            if (-not (Start-Server $cfg)) { Log "repornire esuata; iesire."; break }
            $down = 0
        }
        continue
    }
    $down = 0

    # Apply a postponed switch only when the current task has finished.
    if ($pending) {
        if (Test-Busy) {
            if ($pendingSince -and ((Get-Date) - $pendingSince).TotalSeconds -gt 600) {
                Log "taskul dureaza >10 min; comutarea ramane amanata."
                $pendingSince = Get-Date
            }
            continue
        }
        $target = $pending
        # Re-check VRAM: the situation may have changed while the task was running.
        $nowFree = Get-FreeVramMib
        if ($null -ne $nowFree) {
            $right = $target
            if ($nowFree -lt $FastToGameMs) { $right = 'game' }
            elseif ($nowFree -gt $GameToFastMs) { $right = 'fast' }
            if ($right -ne $target) {
                Log "VRAM schimbata intre timp ($nowFree MiB): corectez $target -> $right"
                $target = $right
            }
        }
        $pending = $null
        $pendingSince = $null
        Log "taskul s-a terminat; aplic comutarea in modul $target"
        $cfg = if ($target -eq 'game') { $GameCfg } else { $FastCfg }
        if (Switch-To $target $cfg) { $script:mode = $target }
    }

    $free = Get-FreeVramMib
    if ($null -eq $free) { continue }

    if ($script:mode -eq 'fast') {
        # Never interrupt a running or queued request.
        if (Test-Busy) { $lowCount = 0; continue }

        $engineBusy = Get-Process -Name 'strata-poly','strata-vision' -ErrorAction SilentlyContinue
        if ($health.Loaded -or $engineBusy) {
            if (-not $health.Loaded) { $lowCount = 0; continue }   # still loading
            # The fast config reserves headroom, so free VRAM is meaningful even
            # while loaded. A drop below the floor = another app took that memory.
            # Pressure overrides hot time: no minimum wait before releasing VRAM.
            if ($free -lt $PressureFreeMib) {
                $lowCount++
                if ($lowCount -ge $PressurePolls) {
                    Request-Switch 'game' "VRAM luata de alta aplicatie ($free MiB libere)"
                    $lowCount = 0
                }
            } else { $lowCount = 0 }
            continue
        }

        # Model not loaded: the original free-VRAM criterion applies.
        if ($free -lt $FastToGameMs) {
            $lowCount++
            if ($lowCount -ge $FastToGamePolls) {
                Request-Switch 'game' "VRAM ocupata de alta aplicatie ($free MiB libere)"
                $lowCount = 0
            }
        } else { $lowCount = 0 }
    }
    else {
        # Game mode uses only ~3 GB VRAM, so a high reading means the GPU is free.
        if ($free -gt $GameToFastMs) {
            $highCount++
            if ($highCount -ge $GameToFastPolls) {
                Request-Switch 'fast' "VRAM libera din nou ($free MiB)"
                $highCount = 0
            }
        } else { $highCount = 0 }
    }
}
