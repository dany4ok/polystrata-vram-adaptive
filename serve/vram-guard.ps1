param(
    [int]$Port          = 8080,
    [int]$PollSeconds   = 2,
    [int]$FastToGameMs  = 11000,   # free VRAM below this -> another app needs the GPU
    [int]$GameToFastMs  = 13000,   # free VRAM above this -> GPU is free again
    [int]$FastToGamePolls = 4,     # ~8 s of low VRAM before switching to RAM/SSD
    [int]$GameToFastPolls = 6      # ~12 s of free VRAM before switching back to GPU
)

# VRAM-only adaptive guard.
# No process-name heuristics: the mode is decided by how much VRAM is actually free.
#   free < 11 GB (and model not loaded) -> RAM/SSD mode, 0 experts in VRAM
#   free > 13 GB                        -> fast GPU mode (model loads on request)
# The gap between the thresholds prevents flapping.
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

function Log([string]$msg) {
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

function Get-ServerUp {
    try { Invoke-RestMethod -UseBasicParsing -Uri ($Base + '/health') -TimeoutSec 5 | Out-Null; return $true }
    catch { return $false }
}

function Get-ModelLoaded {
    try {
        $h = Invoke-RestMethod -UseBasicParsing -Uri ($Base + '/health') -TimeoutSec 5
        return [bool]$h.loaded
    } catch { return $false }
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

function Free-Port {
    $owners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $_.OwningProcess })
    $stale = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and
        $_.CommandLine -like '*serve\server.py*' -and
        $_.CommandLine -like '*Poly-strata*'
    } | ForEach-Object { $_.ProcessId })
    foreach ($procId in (@($owners + $stale) | Select-Object -Unique)) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
        if ($p -and $p.Name -in @('python.exe','pythonw.exe')) {
            Log "eliberez portul $Port / server orfan (PID $procId)"
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        }
    }
    Get-Process -Name 'strata-poly','strata-vision' -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

function Stop-Server {
    $owners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $_.OwningProcess })
    foreach ($procId in ($owners | Select-Object -Unique)) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    Get-Process -Name 'strata-poly','strata-vision' -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

function Start-Server([string]$cfg) {
    Free-Port
    $a = @($ServerPy, '--engine', 'strata', '--config', $cfg, '--port', "$Port")
    Start-Process -FilePath $Python -ArgumentList $a -WorkingDirectory $Root -NoNewWindow
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 1
        if (Get-ServerUp) {
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
Log "modelul NU e incarcat; se incarca la prima cerere si se descarca dupa 60 s de inactivitate."

$script:mode = $mode
$pending = $null
$pendingSince = $null
$lowCount = 0
$highCount = 0
$down = 0

while ($true) {
    Start-Sleep -Seconds $PollSeconds

    if (-not (Get-ServerUp)) {
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
        $pending = $null
        $pendingSince = $null
        Log "taskul s-a terminat; aplic comutarea in modul $target"
        $cfg = if ($target -eq 'game') { $GameCfg } else { $FastCfg }
        if (Switch-To $target $cfg) { $script:mode = $target }
    }

    $free = Get-FreeVramMib
    if ($null -eq $free) { continue }

    if ($script:mode -eq 'fast') {
        # While the model itself is loaded it uses ~12 GB, so free VRAM is not a
        # valid signal. Also skip switching while a task is active.
        if ((Get-ModelLoaded) -or (Test-Busy)) { $lowCount = 0; continue }
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
