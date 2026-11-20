param(
    [int]$Port        = 8080,
    [int]$PollSeconds = 2,
    [int]$PersistPolls = 2
)

# On-demand adaptive VRAM guard.
# No game  -> server with GPU config: model loads on first request at FULL speed,
#            unloads by itself after 60 s idle. VRAM is free when nobody uses it.
# Game     -> server with RAM/SSD config: 0 experts in VRAM, model still loads on
#            request (~1.7 s) and never competes with the game for VRAM.
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

# Never treat these as a game. Add your own here if you see a false switch.
$NeverGame = @(
    'strata-poly.exe', 'strata-vision.exe',
    'python.exe', 'pythonw.exe',
    'powershell.exe', 'pwsh.exe', 'cmd.exe', 'conhost.exe', 'nvidia-smi.exe',
    'dwm.exe', 'explorer.exe', 'ShellHost.exe', 'ShellExperienceHost.exe',
    'ApplicationFrameHost.exe', 'StartMenuExperienceHost.exe', 'SearchHost.exe',
    'SearchApp.exe', 'SearchIndexer.exe', 'TextInputHost.exe', 'SystemSettings.exe',
    'WidgetBoard.exe', 'CrossDeviceResume.exe', 'WindowsTerminal.exe',
    'SnippingTool.exe', 'Photos.exe', 'RuntimeBroker.exe', 'Taskmgr.exe',
    'NVIDIA Overlay.exe', 'nvcontainer.exe', 'NVDisplay.Container.exe',
    'GameBar.exe', 'GameBarFTServer.exe', 'XboxGameBarWidgets.exe',
    'XboxGameBarWidget.exe', 'XboxGameBarWidget_.exe',
    'steam.exe', 'steamwebhelper.exe', 'OpenCode.exe', 'SiYuan.exe',
    'msedge.exe', 'msedgewebview2.exe', 'chrome.exe', 'firefox.exe',
    'opera.exe', 'brave.exe', 'discord.exe', 'obs64.exe', 'vlc.exe', 'spotify.exe'
)

function Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $Log -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-GameProcesses {
    $raw = & nvidia-smi 2>$null | Out-String
    $re  = '^\|\s*\d+\s+\S+\s+\S+\s+(\d+)\s+(C\+G|C|G)\s+(.+?)\s+(N/A|\d+\s*MiB)\s*\|\s*$'
    $found = @{}
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match $re) {
            $name = (($Matches[3].Trim() -split '\\')[-1]).Trim()
            if ($name -and $name -notin $NeverGame) { $found[$name] = [int]$Matches[1] }
        }
    }
    return $found
}

function Get-ServerUp {
    # With lazy_load the server answers even while the model is not loaded.
    try { Invoke-RestMethod -UseBasicParsing -Uri ($Base + '/health') -TimeoutSec 5 | Out-Null; return $true }
    catch { return $false }
}

function Wait-Idle([int]$maxSeconds) {
    for ($i = 0; $i -lt $maxSeconds; $i++) {
        try {
            $s = Invoke-RestMethod -UseBasicParsing -Uri ($Base + '/status') -TimeoutSec 5
            if (-not $s.busy -and -not $s.queued) { return $true }
        } catch { return $true }
        Start-Sleep -Seconds 1
    }
    Log "serverul e inca ocupat; comut fortat"
    return $false
}

function Free-Port {
    $owners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $_.OwningProcess })
    foreach ($procId in ($owners | Select-Object -Unique)) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
        if ($p -and $p.Name -in @('python.exe','pythonw.exe')) {
            Log "eliberez portul $Port (PID $procId ramas de la o rulare anterioara)"
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

function Switch-To([string]$newMode, [string]$cfg) {
    $previous = $mode
    Log ("trecere in modul $newMode (se asteapta cererile in curs) ...")
    Wait-Idle 5 | Out-Null
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

Log "=== adaptive guard start (la cerere) ==="

$games = @((Get-GameProcesses).Keys)
if ($games.Count -gt 0) {
    Log ("joc deja deschis (" + ($games -join ', ') + ") -> mod joc")
    $mode = 'game'
    $ok = Start-Server $GameCfg
} else {
    Log "niciun joc la pornire -> mod rapid (la cerere)"
    $mode = 'fast'
    $ok = Start-Server $FastCfg
}
if (-not $ok) { Log "serverul nu a pornit; iesire."; exit 1 }
Log "modelul NU e incarcat acum; se va incarca la prima cerere si se va descarca dupa 60 s de inactivitate."

$candidate = 0
$down = 0

while ($true) {
    Start-Sleep -Seconds $PollSeconds

    if (-not (Get-ServerUp)) {
        $down++
        if ($down -ge 3) {
            Log "serverul nu raspunde; repornesc in modul $mode"
            Stop-Server
            $cfg = if ($mode -eq 'game') { $GameCfg } else { $FastCfg }
            if (-not (Start-Server $cfg)) { Log "repornire esuata; iesire."; break }
            $down = 0
        }
        continue
    }
    $down = 0

    $games = @((Get-GameProcesses).Keys)
    $gameNow = $games.Count -gt 0

    if ($mode -eq 'fast' -and $gameNow) {
        $candidate++
        if ($candidate -ge $PersistPolls) {
            Log ("joc detectat: " + ($games -join ', '))
            if (Switch-To 'game' $GameCfg) { $mode = 'game' }
            $candidate = 0
        }
    }
    elseif ($mode -eq 'game' -and -not $gameNow) {
        $candidate++
        if ($candidate -ge $PersistPolls) {
            Log "jocul s-a inchis."
            if (Switch-To 'fast' $FastCfg) { $mode = 'fast' }
            $candidate = 0
        }
    }
    else { $candidate = 0 }
}
