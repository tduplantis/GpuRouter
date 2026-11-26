#Requires -Version 5.1
<#
.SYNOPSIS
  GpuRouter setup. Pick your game drive(s), the GPU that runs your games, and the GPU for everything else.

.DESCRIPTION
  Without parameters it opens a setup window. With -Silent it installs from the parameters given.
  Installs per user, no admin rights needed:
    * scripts to %LOCALAPPDATA%\GpuRouter\bin
    * settings to %LOCALAPPDATA%\GpuRouter\config.json
    * a hidden Startup shortcut so it runs at logon
    * an entry in Settings > Apps > Installed apps for uninstalling

.EXAMPLE
  .\Setup.ps1
.EXAMPLE
  .\Setup.ps1 -Silent -GameDrives G -AppGpu "5060"
.EXAMPLE
  .\Setup.ps1 -Silent -GameDrives D,E -GameFolders "C:\Games" -GameGpu "4090" -AppGpu "Radeon"
.EXAMPLE
  .\Setup.ps1 -Uninstall -RestoreEntries
#>
[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Silent', Mandatory)][switch]$Silent,
    [Parameter(ParameterSetName = 'Silent')][string[]]$GameDrives = @(),
    [Parameter(ParameterSetName = 'Silent')][string[]]$GameFolders = @(),
    [Parameter(ParameterSetName = 'Silent')][string]$GameGpu,   # part of the name; default: the GPU driving the main monitor
    [Parameter(ParameterSetName = 'Silent')][string]$AppGpu,    # part of the name; default: the first other GPU
    [Parameter(ParameterSetName = 'Silent')][switch]$NoStartup,
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)][switch]$Uninstall,
    [Parameter(ParameterSetName = 'Uninstall')][switch]$RestoreEntries
)

$ErrorActionPreference = 'Stop'
$SrcDir = if (Test-Path (Join-Path $PSScriptRoot 'src\GpuRouter.ps1')) { Join-Path $PSScriptRoot 'src' } else { $PSScriptRoot }
. (Join-Path $SrcDir 'GpuRouter.Common.ps1')

$DefaultExcludeExe = @(
    'obs64.exe', 'obs32.exe', 'RTSS.exe', 'RTSSHooksLoader64.exe', 'MSIAfterburner.exe',
    'EncoderServer.exe', 'EncoderServer64.exe', 'NVIDIA Overlay.exe', 'nvcontainer.exe',
    'gameoverlayui.exe', 'gameoverlayui64.exe', 'GameBar.exe', 'GameBarFTServer.exe',
    'SteelSeriesCaptureSvc.exe', 'HWiNFO64.exe', 'RadeonSoftware.exe', 'AMDRSServ.exe'
)

# ---------------------------------------------------------------- install / uninstall
function Stop-GRInstances {
    Get-GRRunningInstance | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

function Install-GpuRouter {
    param([object]$GameGpuObj, [object]$AppGpuObj, [string[]]$GamePaths, [bool]$StartWithWindows = $true)

    if (-not $GamePaths -or $GamePaths.Count -eq 0) { throw 'Pick at least one game drive or folder.' }
    if ($GameGpuObj.Spec -eq $AppGpuObj.Spec) {
        throw "The game GPU and app GPU are the same model ($($AppGpuObj.Name)). Windows identifies a Specific GPU by model, so it cannot tell two identical cards apart."
    }
    $GamePaths = @($GamePaths | ForEach-Object { $p = $_.Trim(); if ($p -match '^[A-Za-z]:?$') { $p = $p.Substring(0, 1).ToUpper() + ':\' }; if (-not $p.EndsWith('\')) { $p += '\' }; $p } | Select-Object -Unique)

    $out = New-Object System.Collections.Generic.List[string]
    Stop-GRInstances

    # 1. files
    New-Item -ItemType Directory -Force -Path $GR_BinDir | Out-Null
    foreach ($f in 'GpuRouter.ps1', 'GpuRouter.Common.ps1') { Copy-Item (Join-Path $SrcDir $f) (Join-Path $GR_BinDir $f) -Force }
    Copy-Item $PSCommandPath (Join-Path $GR_BinDir 'Setup.ps1') -Force
    Get-ChildItem $GR_BinDir | Unblock-File
    $out.Add("Installed to $GR_BinDir")

    # 2. config (keeps your exclusion edits from an earlier install)
    $old = $null; if (Test-Path $GR_ConfigPath) { try { $old = Get-Content $GR_ConfigPath -Raw | ConvertFrom-Json } catch { } }
    # arrays are built first: $(...) inside a hashtable would flatten a one-item array into a string
    $epp = if ($old.ExcludePathPrefixes) { @($old.ExcludePathPrefixes) } else { @('%WINDIR%\') }
    $epc = if ($old.ExcludePathContains) { @($old.ExcludePathContains) } else { @('\steamapps\common\') }
    $een = if ($old.ExcludeExeNames)     { @($old.ExcludeExeNames) }     else { @($DefaultExcludeExe) }
    $cfg = [ordered]@{
        GameGpu             = [ordered]@{ Name = $GameGpuObj.Name; Spec = $GameGpuObj.Spec }
        AppGpu              = [ordered]@{ Name = $AppGpuObj.Name;  Spec = $AppGpuObj.Spec }
        GamePaths           = [object[]]$GamePaths
        PollSeconds         = $(if ($old.PollSeconds) { $old.PollSeconds } else { 10 })
        MinGameGpuMB        = $(if ($old.MinGameGpuMB) { $old.MinGameGpuMB } else { 16 })
        ExcludePathPrefixes = [object[]]$epp
        ExcludePathContains = [object[]]$epc
        ExcludeExeNames     = [object[]]$een
    }
    # Windows PowerShell escapes & ' < > as \u00XX; write them plainly so the file is easy to edit
    $json = ($cfg | ConvertTo-Json -Depth 5) -replace '\\u0026', '&' -replace '\\u0027', "'" -replace '\\u003c', '<' -replace '\\u003e', '>'
    Set-Content -Path $GR_ConfigPath -Value $json -Encoding UTF8
    $out.Add("Settings saved to $GR_ConfigPath")

    # 3. bring earlier routing in line with the new choices
    $state = Get-GRState
    $moved = 0; $released = 0
    foreach ($exe in @($state.Owned.Keys)) {
        if (Test-GRUnderPath $exe $GamePaths) {
            # now counts as a game: give back the original value
            $orig = $state.Owned[$exe].Original
            if ($orig) { Set-GRPref $exe $orig } else { Remove-GRPref $exe }
            $state.Owned.Remove($exe); $state.Ignored.Remove($exe); $released++
            continue
        }
        $cur = Get-GRPref $exe
        if ($cur -and $cur -match 'SpecificAdapter=([^;]+)' -and $matches[1] -ne $AppGpuObj.Spec) {
            Set-GRPref $exe (New-GRPrefValue $cur $AppGpuObj.Spec); $state.Ignored.Remove($exe); $moved++
        }
    }
    Save-GRState $state
    if ($moved)    { $out.Add("Pointed $moved earlier routed apps at $($AppGpuObj.Name)") }
    if ($released) { $out.Add("Released $released apps that are now inside a game path") }

    # 4. startup shortcut and uninstall entry
    $router = Join-Path $GR_BinDir 'GpuRouter.ps1'
    $launch = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$router`" -Headless"
    if ($StartWithWindows) {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($GR_Shortcut)
        $lnk.TargetPath = "$env:WINDIR\System32\conhost.exe"
        $lnk.Arguments = $launch
        $lnk.WorkingDirectory = $GR_BinDir
        $lnk.WindowStyle = 7
        $lnk.Description = 'GpuRouter: send non-game apps to the second GPU'
        $lnk.Save()
        $out.Add('Starts automatically at logon')
    } elseif (Test-Path $GR_Shortcut) { Remove-Item $GR_Shortcut -Force }

    New-Item -Path $GR_UninstallKey -Force | Out-Null
    $un = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $GR_BinDir 'Setup.ps1')`" -Uninstall -RestoreEntries"
    $props = @{ DisplayName = 'GpuRouter'; DisplayVersion = $GR_Version; Publisher = 'GpuRouter'; InstallLocation = $GR_DataDir
                UninstallString = $un; QuietUninstallString = $un; NoModify = 1; NoRepair = 1 }
    foreach ($k in $props.Keys) {
        $type = if ($props[$k] -is [int]) { 'DWord' } else { 'String' }
        New-ItemProperty -Path $GR_UninstallKey -Name $k -Value $props[$k] -PropertyType $type -Force | Out-Null
    }

    # 5. start now
    Start-Process -FilePath "$env:WINDIR\System32\conhost.exe" -ArgumentList $launch -WindowStyle Hidden
    $out.Add('GpuRouter is running')
    $out
}

function Uninstall-GpuRouter([bool]$Restore) {
    $out = New-Object System.Collections.Generic.List[string]
    Stop-GRInstances
    if (Test-Path $GR_Shortcut) { Remove-Item $GR_Shortcut -Force; $out.Add('Removed startup shortcut') }
    if ($Restore) {
        $state = Get-GRState
        foreach ($exe in @($state.Owned.Keys)) {
            $orig = $state.Owned[$exe].Original
            if ($orig) { Set-GRPref $exe $orig } else { Remove-GRPref $exe }
        }
        $out.Add("Restored GPU settings for $($state.Owned.Count) apps")
        Remove-Item $GR_StatePath -Force -ErrorAction SilentlyContinue
    } else {
        $out.Add('GPU settings it made were left in place')
    }
    Remove-Item $GR_UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $GR_BinDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $GR_ConfigPath -Force -ErrorAction SilentlyContinue
    $out.Add("Removed GpuRouter (log kept at $GR_LogPath)")
    $out
}

# ---------------------------------------------------------------- choosing GPUs
function Select-GRGpu($gpus, [string]$match, $fallback) {
    if ($match) {
        $hit = @($gpus | Where-Object { $_.Name -like "*$match*" })
        if ($hit.Count -eq 0) { throw "No GPU matches '$match'. Found: $(($gpus.Name) -join ', ')" }
        return $hit[0]
    }
    $fallback
}

function Get-GRDefaults {
    $gpus = @(Get-GRGpus)
    if ($gpus.Count -lt 2) { throw "GpuRouter needs at least two GPUs. Found: $(($gpus.Name) -join ', ')" }
    $game = $gpus | Where-Object DrivesPrimary | Select-Object -First 1
    if (-not $game) { $game = $gpus | Sort-Object VramGB -Descending | Select-Object -First 1 }
    $app = $gpus | Where-Object { $_.Spec -ne $game.Spec } | Select-Object -First 1
    @{ Gpus = $gpus; Game = $game; App = $app }
}

function Format-Gpu($g) {
    $tags = @()
    if ($g.DrivesPrimary) { $tags += 'main monitor' }
    $tags += "$($g.Monitors) monitor$(if ($g.Monitors -ne 1) { 's' })"
    if ($g.VramGB) { $tags += "$($g.VramGB) GB" }
    "$($g.Name)  ($($tags -join ', '))"
}

# ---------------------------------------------------------------- window
# The dialog is shown from inside this function on purpose: the button handlers use its local variables.
function Show-SetupForm([switch]$NoShow) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $d = Get-GRDefaults
    $cfg = $null; try { $cfg = Get-GRConfig } catch { }

    $font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $bold = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "GpuRouter $GR_Version Setup"; $f.Font = $font
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(560, 540); $f.AutoScaleMode = 'Dpi'

    $y = 14
    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'Apps that run from your game drives stay on the game GPU. Everything else is sent to the app GPU, so games keep the main card to themselves.'
    $intro.SetBounds(16, $y, 528, 40); $f.Controls.Add($intro); $y += 50

    $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'Game GPU (normally the one driving your main monitor)'; $l1.Font = $bold
    $l1.SetBounds(16, $y, 528, 22); $f.Controls.Add($l1); $y += 24
    $cbGame = New-Object System.Windows.Forms.ComboBox; $cbGame.DropDownStyle = 'DropDownList'
    $cbGame.SetBounds(16, $y, 528, 26); $f.Controls.Add($cbGame); $y += 40

    $l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'App GPU (everything that is not a game)'; $l2.Font = $bold
    $l2.SetBounds(16, $y, 528, 22); $f.Controls.Add($l2); $y += 24
    $cbApp = New-Object System.Windows.Forms.ComboBox; $cbApp.DropDownStyle = 'DropDownList'
    $cbApp.SetBounds(16, $y, 528, 26); $f.Controls.Add($cbApp); $y += 40

    foreach ($g in $d.Gpus) { [void]$cbGame.Items.Add((Format-Gpu $g)); [void]$cbApp.Items.Add((Format-Gpu $g)) }
    $gi = [array]::IndexOf(@($d.Gpus.Spec), $(if ($cfg) { $cfg.GameGpu.Spec } else { $d.Game.Spec })); if ($gi -lt 0) { $gi = [array]::IndexOf(@($d.Gpus.Spec), $d.Game.Spec) }
    $ai = [array]::IndexOf(@($d.Gpus.Spec), $(if ($cfg) { $cfg.AppGpu.Spec } else { $d.App.Spec }));  if ($ai -lt 0) { $ai = [array]::IndexOf(@($d.Gpus.Spec), $d.App.Spec) }
    $cbGame.SelectedIndex = $gi; $cbApp.SelectedIndex = $ai

    $l3 = New-Object System.Windows.Forms.Label; $l3.Text = 'Game drives and folders'; $l3.Font = $bold
    $l3.SetBounds(16, $y, 528, 22); $f.Controls.Add($l3); $y += 24
    $list = New-Object System.Windows.Forms.CheckedListBox; $list.CheckOnClick = $true
    $list.SetBounds(16, $y, 410, 150); $f.Controls.Add($list)
    $btnAdd = New-Object System.Windows.Forms.Button; $btnAdd.Text = 'Add folder...'; $btnAdd.SetBounds(436, $y, 108, 30); $f.Controls.Add($btnAdd)
    $y += 160

    $existing = @(); if ($cfg) { $existing = @($cfg.GamePaths) }
    foreach ($disk in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object DeviceID) {
        $root = "$($disk.DeviceID)\"
        $label = if ($disk.VolumeName) { $disk.VolumeName } else { 'Local Disk' }
        $text = '{0}  {1}  ({2:N0} GB)' -f $root, $label, ($disk.Size / 1GB)
        $isSys = $root -ieq "$env:SystemDrive\"
        if ($isSys) { $text += '  Windows drive' }
        $i = $list.Items.Add($text)
        if ($existing -icontains $root) { $list.SetItemChecked($i, $true) }
    }
    foreach ($p in $existing) { if ($p -notmatch '^[A-Za-z]:\\$') { $list.SetItemChecked($list.Items.Add($p), $true) } }
    $btnAdd.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Pick a folder that holds games (for example C:\Games or a Steam library)'
        if ($fb.ShowDialog($f) -eq 'OK') { $list.SetItemChecked($list.Items.Add($fb.SelectedPath), $true) }
    })

    $chkStart = New-Object System.Windows.Forms.CheckBox; $chkStart.Text = 'Start with Windows'; $chkStart.Checked = $true
    $chkStart.SetBounds(16, $y, 300, 24); $f.Controls.Add($chkStart); $y += 34

    $note = New-Object System.Windows.Forms.Label; $note.ForeColor = [System.Drawing.Color]::DimGray
    $note.Text = 'Apps move to the app GPU the next time they start. Some apps ignore the Windows setting (Discord, for example); those are listed in the log.'
    $note.SetBounds(16, $y, 528, 40); $f.Controls.Add($note); $y += 48

    $btnInstall = New-Object System.Windows.Forms.Button; $btnInstall.Text = $(if ($cfg) { 'Save and restart' } else { 'Install' })
    $btnInstall.SetBounds(16, $y, 130, 32); $f.Controls.Add($btnInstall); $f.AcceptButton = $btnInstall
    $btnPreview = New-Object System.Windows.Forms.Button; $btnPreview.Text = 'Preview'; $btnPreview.SetBounds(156, $y, 100, 32); $f.Controls.Add($btnPreview)
    $btnUninstall = New-Object System.Windows.Forms.Button; $btnUninstall.Text = 'Uninstall'; $btnUninstall.SetBounds(266, $y, 100, 32)
    $btnUninstall.Enabled = [bool]$cfg; $f.Controls.Add($btnUninstall)
    $btnClose = New-Object System.Windows.Forms.Button; $btnClose.Text = 'Close'; $btnClose.SetBounds(444, $y, 100, 32); $f.Controls.Add($btnClose); $f.CancelButton = $btnClose

    $getPaths = {
        @($list.CheckedItems | ForEach-Object { if ($_ -match '^([A-Za-z]:\\)\s') { $matches[1] } else { [string]$_ } })
    }
    $check = {
        $g = $d.Gpus[$cbGame.SelectedIndex]; $a = $d.Gpus[$cbApp.SelectedIndex]
        if ($g.Spec -eq $a.Spec) { [System.Windows.Forms.MessageBox]::Show($f, 'Pick two different GPUs.', 'GpuRouter', 'OK', 'Warning') | Out-Null; return $null }
        $paths = & $getPaths
        if ($paths.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show($f, 'Tick at least one game drive or folder.', 'GpuRouter', 'OK', 'Warning') | Out-Null; return $null }
        if ($paths -icontains "$env:SystemDrive\") {
            $r = [System.Windows.Forms.MessageBox]::Show($f, "You ticked the Windows drive ($env:SystemDrive\). Every app installed there will count as a game and stay on the game GPU. Continue?", 'GpuRouter', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return $null }
        }
        @{ Game = $g; App = $a; Paths = $paths }
    }
    $btnInstall.Add_Click({
        $c = & $check; if (-not $c) { return }
        try {
            $f.Cursor = 'WaitCursor'
            $msg = Install-GpuRouter -GameGpuObj $c.Game -AppGpuObj $c.App -GamePaths $c.Paths -StartWithWindows $chkStart.Checked
            $f.Cursor = 'Default'
            [System.Windows.Forms.MessageBox]::Show($f, ($msg -join "`n"), 'GpuRouter installed', 'OK', 'Information') | Out-Null
            $f.Close()
        } catch { $f.Cursor = 'Default'; [System.Windows.Forms.MessageBox]::Show($f, $_.Exception.Message, 'GpuRouter', 'OK', 'Error') | Out-Null }
    })
    $btnPreview.Add_Click({
        $c = & $check; if (-not $c) { return }
        $tmp = Join-Path $env:TEMP 'GpuRouter.preview.json'
        $pc = [ordered]@{ GameGpu = @{ Name = $c.Game.Name; Spec = $c.Game.Spec }; AppGpu = @{ Name = $c.App.Name; Spec = $c.App.Spec }; GamePaths = $c.Paths
                          ExcludePathPrefixes = @('%WINDIR%\'); ExcludePathContains = @('\steamapps\common\'); ExcludeExeNames = $DefaultExcludeExe }
        if ($cfg) { $pc.ExcludePathPrefixes = @($cfg.ExcludePathPrefixes); $pc.ExcludePathContains = @($cfg.ExcludePathContains); $pc.ExcludeExeNames = @($cfg.ExcludeExeNames) }
        ($pc | ConvertTo-Json -Depth 5) | Set-Content $tmp -Encoding UTF8
        try {
            $f.Cursor = 'WaitCursor'
            $lines = @(& (Join-Path $SrcDir 'GpuRouter.ps1') -Once -DryRun -ConfigPath $tmp)
            $f.Cursor = 'Default'
            $text = if ($lines.Count) { "Running apps that would move to $($c.App.Name):`n`n" + (($lines | ForEach-Object { $_ -replace '^Would route \([^)]*\): ', '' }) -join "`n") } else { 'No running apps would be moved right now.' }
            [System.Windows.Forms.MessageBox]::Show($f, $text, 'GpuRouter preview', 'OK', 'Information') | Out-Null
        } catch { $f.Cursor = 'Default'; [System.Windows.Forms.MessageBox]::Show($f, $_.Exception.Message, 'GpuRouter', 'OK', 'Error') | Out-Null }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    })
    $btnUninstall.Add_Click({
        $r = [System.Windows.Forms.MessageBox]::Show($f, "Uninstall GpuRouter?`n`nYes: uninstall and undo the GPU settings it made.`nNo: uninstall but keep those settings.", 'GpuRouter', 'YesNoCancel', 'Question')
        if ($r -eq 'Cancel') { return }
        $msg = Uninstall-GpuRouter -Restore ($r -eq 'Yes')
        [System.Windows.Forms.MessageBox]::Show($f, ($msg -join "`n"), 'GpuRouter', 'OK', 'Information') | Out-Null
        $f.Close()
    })
    $btnClose.Add_Click({ $f.Close() })
    if ($NoShow) { return $f }   # used by tests to build the window without showing it
    [void]$f.ShowDialog()
    $f.Dispose()
}

# ---------------------------------------------------------------- entry point (skipped when dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    if ($Uninstall) { Uninstall-GpuRouter -Restore $RestoreEntries.IsPresent; return }
    if ($Silent) {
        $d = Get-GRDefaults
        $game = Select-GRGpu $d.Gpus $GameGpu $d.Game
        $app  = Select-GRGpu $d.Gpus $AppGpu ($d.Gpus | Where-Object { $_.Spec -ne $game.Spec } | Select-Object -First 1)
        $paths = @($GameDrives) + @($GameFolders)
        Install-GpuRouter -GameGpuObj $game -AppGpuObj $app -GamePaths $paths -StartWithWindows (-not $NoStartup)
        return
    }
    try { Show-SetupForm }
    catch {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'GpuRouter setup', 'OK', 'Error') | Out-Null
    }
}
