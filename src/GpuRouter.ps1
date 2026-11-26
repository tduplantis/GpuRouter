#Requires -Version 5.1
<#
.SYNOPSIS
  GpuRouter background service. Sends apps that are not games to the GPU you picked in Setup.

.DESCRIPTION
  Every PollSeconds it reads the "GPU Process Memory" performance counters. A process counts as
  rendering on the game GPU when most of its dedicated GPU memory is there and it is at least
  MinGameGpuMB. If that exe is not under one of your game paths and not excluded, GpuRouter writes
  the Windows per-app "Specific GPU" preference for your app GPU (the same value Settings writes).

  Windows applies a GPU preference only when an app starts, so a newly routed app moves on its
  next launch. GpuRouter never changes an exe that already has a GPU chosen.

.EXAMPLE
  .\GpuRouter.ps1 -Status
  .\GpuRouter.ps1 -Once -DryRun
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')][switch]$Once,
    [Parameter(ParameterSetName = 'Run')][switch]$DryRun,
    [Parameter(ParameterSetName = 'Run')][switch]$Headless,
    [Parameter(ParameterSetName = 'Run')][string]$ConfigPath,
    [Parameter(ParameterSetName = 'Status')][switch]$Status
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GpuRouter.Common.ps1')
if (-not $ConfigPath) { $ConfigPath = $GR_ConfigPath }
$script:GR_Quiet = [bool]$Headless

function Test-Excluded([string]$path, $cfg) {
    if (Test-GRUnderPath $path $cfg.GamePaths) { return $true }
    if (Test-GRUnderPath $path $cfg.ExcludePathPrefixes) { return $true }
    foreach ($p in $cfg.ExcludePathContains) { if ($path.IndexOf($p, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
    $exe = [IO.Path]::GetFileName($path)
    foreach ($n in $cfg.ExcludeExeNames) { if ($exe -ieq $n) { return $true } }
    $false
}

# Dedicated GPU memory per process on the game GPU and the app GPU, in MB.
function Get-GpuMemory($gpu, $category) {
    $game = @{}; $app = @{}; $sawGame = $false
    foreach ($v in $category.ReadCategory()['dedicated usage'].Values) {
        if ($v.InstanceName -notmatch '^pid_(\d+)_(luid_0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)_') { continue }
        $procId = [int]$matches[1]; $mb = $v.RawValue / 1MB
        if ($matches[2] -eq $gpu.GameLuid)    { $sawGame = $true; $game[$procId] = $mb + [double]$game[$procId] }
        elseif ($matches[2] -eq $gpu.AppLuid) { $app[$procId] = $mb + [double]$app[$procId] }
    }
    @{ Game = $game; App = $app; SawGame = $sawGame }
}

function Invoke-Pass($cfg, $gpu, $state, $category, [switch]$DryRun) {
    $m = Get-GpuMemory $gpu $category
    if (-not $m.SawGame) { return @{ Changed = $false; Rescan = $true } }

    # Group processes by exe and total their GPU memory on each card.
    $byExe = @{}
    foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ExecutablePath, CreationDate) {
        if (-not $p.ExecutablePath) { continue }          # elevated or protected process: path not visible
        $procId = [int]$p.ProcessId
        $g = [double]$m.Game[$procId]; $a = [double]$m.App[$procId]
        if ($g -eq 0 -and $a -eq 0) { continue }
        if (-not $byExe.ContainsKey($p.ExecutablePath)) { $byExe[$p.ExecutablePath] = New-Object System.Collections.ArrayList }
        [void]$byExe[$p.ExecutablePath].Add([pscustomobject]@{ Start = $p.CreationDate; Game = $g; App = $a })
    }

    $changed = $false
    foreach ($path in $byExe.Keys) {
        $procs  = $byExe[$path]
        $gameMB = ($procs | Measure-Object Game -Sum).Sum
        $appMB  = ($procs | Measure-Object App -Sum).Sum
        if ($gameMB -lt $cfg.MinGameGpuMB -or $gameMB -le $appMB) { continue }   # not mostly on the game GPU
        if (Test-Excluded $path $cfg) { continue }

        if ($state.Owned.ContainsKey($path)) {
            # Already routed. If it restarted and is still mostly on the game GPU, the app ignores the setting.
            if ($state.Ignored.ContainsKey($path)) { continue }
            $setAt = [datetime]$state.Owned[$path].SetAt
            $fresh = @($procs | Where-Object { $_.Start -gt $setAt.AddSeconds(5) })
            if ($fresh.Count -gt 0) {
                $fg = ($fresh | Measure-Object Game -Sum).Sum; $fa = ($fresh | Measure-Object App -Sum).Sum
                if ($fg -ge $cfg.MinGameGpuMB -and $fg -gt $fa) {
                    $state.Ignored[$path] = (Get-Date).ToString('o')
                    Write-GRLog ("IGNORES SETTING: {0} restarted but still uses {1:N0} MB on {2} vs {3:N0} MB on {4}. Needs an app-side fix, for example turning off its hardware acceleration." -f $path, $fg, $cfg.GameGpu.Name, $fa, $cfg.AppGpu.Name)
                    $changed = $true
                }
            }
            continue
        }

        $existing = Get-GRPref $path
        if (Test-GRHasChoice $existing) { continue }   # a GPU is already chosen for it

        if ($DryRun) {
            # collected, not written to the pipeline: pipeline output here would become part of the return value
            [void]$script:DryRunLines.Add(("Would route ({0:N0} MB on game GPU): {1}" -f $gameMB, $path))
            continue
        }
        Set-GRPref $path (New-GRPrefValue $existing $gpu.AppSpec)
        $state.Owned[$path] = @{ Original = $existing; SetAt = (Get-Date).ToString('o') }
        Write-GRLog ("ROUTED to {0}: {1} ({2:N0} MB was on the game GPU; moves on its next launch)" -f $cfg.AppGpu.Name, $path, $gameMB)
        $changed = $true
    }
    @{ Changed = $changed; Rescan = $false }
}

# Forget entries for exes that no longer exist (old version folders after updates and so on).
function Invoke-Prune($state) {
    $changed = $false
    foreach ($path in @($state.Owned.Keys)) {
        if (-not (Test-Path -LiteralPath $path)) {
            $cur = Get-GRPref $path
            if ($cur -and $cur -match [regex]::Escape($GR_SpecificPref)) { Remove-GRPref $path }
            $state.Owned.Remove($path); $state.Ignored.Remove($path)
            Write-GRLog "PRUNED (exe no longer exists): $path"
            $changed = $true
        }
    }
    $changed
}

# ---------------------------------------------------------------- status
if ($Status) {
    $state = Get-GRState
    $running = Get-GRRunningInstance
    $cfg = $null; try { $cfg = Get-GRConfig $ConfigPath } catch { }
    "GpuRouter $GR_Version"
    "Running:         " + $(if ($running) { "yes (PID $(@($running.ProcessId) -join ', '))" } else { 'no' })
    "Starts at logon: " + $(if (Test-Path $GR_Shortcut) { 'yes' } else { 'no' })
    if ($cfg) {
        "Game GPU:        $($cfg.GameGpu.Name)"
        "App GPU:         $($cfg.AppGpu.Name)"
        "Game paths:      $($cfg.GamePaths -join ', ')"
    }
    ""
    "Routed by GpuRouter ($($state.Owned.Count)):"
    $state.Owned.Keys | Sort-Object | ForEach-Object { '  ' + $(if ($state.Ignored.ContainsKey($_)) { '[ignores setting] ' } else { '' }) + $_ }
    ""
    "Recent log:"
    if (Test-Path $GR_LogPath) { Get-Content $GR_LogPath -Tail 15 | ForEach-Object { '  ' + $_ } }
    return
}

# ---------------------------------------------------------------- main loop
$mutex = New-Object Threading.Mutex($false, 'Local\GpuRouter')
$haveMutex = $false
if (-not $Once) {
    # a killed previous instance leaves the mutex abandoned; WaitOne then throws, but we do own it
    try { $haveMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveMutex = $true }
    if (-not $haveMutex) { Write-Host 'GpuRouter is already running.'; return }
}

try {
    $cfg = Get-GRConfig $ConfigPath
    $gpu = Resolve-GRGpus $cfg
    $category = New-Object Diagnostics.PerformanceCounterCategory 'GPU Process Memory'
    $state = Get-GRState
    if (-not $Once) { Write-GRLog "Started $GR_Version. Apps -> $($cfg.AppGpu.Name) [$($gpu.AppSpec)], games on $($cfg.GamePaths -join ', ') -> $($cfg.GameGpu.Name)" }

    $script:DryRunLines = New-Object System.Collections.Generic.List[string]
    $pass = 0
    do {
        try {
            $r = Invoke-Pass $cfg $gpu $state $category -DryRun:$DryRun
            if ($r.Rescan) { $gpu = Resolve-GRGpus $cfg }     # LUIDs change after a driver reset
            $dirty = $r.Changed
            if (($pass % 60) -eq 0 -and -not $DryRun) { $dirty = (Invoke-Prune $state) -or $dirty }
            if ($dirty -and -not $DryRun) { Save-GRState $state }
        } catch {
            if ($Once) { throw }
            Write-GRLog "ERROR: $($_.Exception.Message)"
            Start-Sleep -Seconds 30
            try { $cfg = Get-GRConfig $ConfigPath; $gpu = Resolve-GRGpus $cfg } catch { }
        }
        $pass++
        if (-not $Once) { Start-Sleep -Seconds $cfg.PollSeconds }
    } while (-not $Once)
    if ($DryRun) { $script:DryRunLines | Sort-Object }
}
finally {
    if ($haveMutex) { $mutex.ReleaseMutex() }
}
