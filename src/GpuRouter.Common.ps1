# GpuRouter shared helpers. Dot-sourced by GpuRouter.ps1 and Setup.ps1.
# Windows PowerShell 5.1, no admin rights needed. Everything is per user (HKCU, %LOCALAPPDATA%).

$GR_DataDir      = Join-Path $env:LOCALAPPDATA 'GpuRouter'
$GR_BinDir       = Join-Path $GR_DataDir 'bin'
$GR_ConfigPath   = Join-Path $GR_DataDir 'config.json'
$GR_StatePath    = Join-Path $GR_DataDir 'state.json'
$GR_LogPath      = Join-Path $GR_DataDir 'GpuRouter.log'
$GR_PrefKey      = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$GR_SpecificPref = 'GpuPreference=1073741824'   # what Settings writes for "Specific GPU"
$GR_Shortcut     = Join-Path ([Environment]::GetFolderPath('Startup')) 'GpuRouter.lnk'
$GR_UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GpuRouter'
$GR_Version      = '1.0.0'

if (-not ('GpuRouterDxgi' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public class GpuRouterAdapter {
  public string Name; public string Luid; public uint VendorId; public uint DeviceId; public uint SubSysId;
  public ulong DedicatedVideoMemory; public bool Software; public bool DrivesPrimary; public int Outputs;
}
public static class GpuRouterDxgi {
  [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr f);
  [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int EnumAdapters1(IntPtr s, uint i, out IntPtr a);
  [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int EnumOutputs(IntPtr s, uint i, out IntPtr o);
  [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetDesc(IntPtr s, IntPtr d);
  [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint Release(IntPtr s);
  static IntPtr Slot(IntPtr o, int i) { return Marshal.ReadIntPtr(Marshal.ReadIntPtr(o), i * IntPtr.Size); }
  static void Rel(IntPtr o) { ((Release)Marshal.GetDelegateForFunctionPointer(Slot(o, 2), typeof(Release)))(o); }
  public static List<GpuRouterAdapter> Adapters() {
    var r = new List<GpuRouterAdapter>();
    Guid g = new Guid("770aae78-f26f-4dba-a829-253c83d1b387"); IntPtr f;
    if (CreateDXGIFactory1(ref g, out f) != 0) return r;
    var ea = (EnumAdapters1)Marshal.GetDelegateForFunctionPointer(Slot(f, 12), typeof(EnumAdapters1));
    IntPtr b = Marshal.AllocHGlobal(1024);
    try {
      for (uint i = 0; ; i++) {
        IntPtr a; if (ea(f, i, out a) != 0) break;
        ((GetDesc)Marshal.GetDelegateForFunctionPointer(Slot(a, 10), typeof(GetDesc)))(a, b);   // IDXGIAdapter1::GetDesc1
        var x = new GpuRouterAdapter();
        x.Name = Marshal.PtrToStringUni(b);
        x.VendorId = (uint)Marshal.ReadInt32(b, 256); x.DeviceId = (uint)Marshal.ReadInt32(b, 260); x.SubSysId = (uint)Marshal.ReadInt32(b, 264);
        x.DedicatedVideoMemory = (ulong)Marshal.ReadInt64(b, 272);
        x.Luid = "luid_0x" + Marshal.ReadInt32(b, 300).ToString("X8") + "_0x" + ((uint)Marshal.ReadInt32(b, 296)).ToString("X8");
        x.Software = (Marshal.ReadInt32(b, 304) & 2) != 0;
        var eo = (EnumOutputs)Marshal.GetDelegateForFunctionPointer(Slot(a, 7), typeof(EnumOutputs));
        for (uint o = 0; ; o++) {
          IntPtr op; if (eo(a, o, out op) != 0) break;
          ((GetDesc)Marshal.GetDelegateForFunctionPointer(Slot(op, 7), typeof(GetDesc)))(op, b);   // IDXGIOutput::GetDesc
          x.Outputs++;
          if (Marshal.ReadInt32(b, 64) == 0 && Marshal.ReadInt32(b, 68) == 0) x.DrivesPrimary = true;   // primary monitor sits at 0,0
          Rel(op);
        }
        r.Add(x); Rel(a);
      }
    } finally { Marshal.FreeHGlobal(b); Rel(f); }
    return r;
  }
}
"@
}

# Hardware GPUs with the identifiers GpuRouter needs.
# Spec is the "VEN&DEV&SUBSYS" string Windows stores for a Specific GPU choice (formatted %X&%X&%X).
function Get-GRGpus {
    [GpuRouterDxgi]::Adapters() | Where-Object { -not $_.Software -and $_.VendorId -ne 0x1414 } | ForEach-Object {
        [pscustomobject]@{
            Name          = $_.Name
            Spec          = '{0:X}&{1:X}&{2:X}' -f $_.VendorId, $_.DeviceId, $_.SubSysId
            Luid          = $_.Luid
            VramGB        = [math]::Round($_.DedicatedVideoMemory / 1GB, 1)
            DrivesPrimary = $_.DrivesPrimary
            Monitors      = $_.Outputs
        }
    }
}

# Resolve the LUIDs (they change every boot) for the GPUs named in the config.
function Resolve-GRGpus($cfg) {
    $all = @(Get-GRGpus)
    $game = $all | Where-Object { $_.Spec -eq $cfg.GameGpu.Spec } | Select-Object -First 1
    $app  = $all | Where-Object { $_.Spec -eq $cfg.AppGpu.Spec }  | Select-Object -First 1
    if (-not $game) { throw "Game GPU '$($cfg.GameGpu.Name)' [$($cfg.GameGpu.Spec)] not found. Run Setup again." }
    if (-not $app)  { throw "App GPU '$($cfg.AppGpu.Name)' [$($cfg.AppGpu.Spec)] not found. Run Setup again." }
    @{ GameLuid = $game.Luid; AppLuid = $app.Luid; AppSpec = $app.Spec }
}

function Write-GRLog([string]$msg) {
    if (-not (Test-Path $GR_DataDir)) { New-Item -ItemType Directory -Path $GR_DataDir | Out-Null }
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    if ((Test-Path $GR_LogPath) -and (Get-Item $GR_LogPath).Length -gt 1MB) { Move-Item $GR_LogPath "$GR_LogPath.old" -Force }
    Add-Content -Path $GR_LogPath -Value $line -Encoding UTF8
    if (-not $script:GR_Quiet) { Write-Host $line }
}

function Get-GRConfig([string]$path = $GR_ConfigPath) {
    if (-not (Test-Path $path)) { throw "No config at $path. Run Setup first." }
    $c = Get-Content $path -Raw | ConvertFrom-Json
    foreach ($k in 'GamePaths', 'ExcludePathPrefixes', 'ExcludePathContains', 'ExcludeExeNames') {
        if (-not $c.$k) { $c | Add-Member -NotePropertyName $k -NotePropertyValue @() -Force }
    }
    if (-not $c.PollSeconds)  { $c | Add-Member -NotePropertyName PollSeconds  -NotePropertyValue 10 -Force }
    if (-not $c.MinGameGpuMB) { $c | Add-Member -NotePropertyName MinGameGpuMB -NotePropertyValue 16 -Force }
    $c.ExcludePathPrefixes = @($c.ExcludePathPrefixes | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) })
    $c
}

function Get-GRState {
    $s = @{ Owned = @{}; Ignored = @{} }
    if (Test-Path $GR_StatePath) {
        $j = Get-Content $GR_StatePath -Raw | ConvertFrom-Json
        foreach ($sec in 'Owned', 'Ignored') {
            if ($j.$sec) { foreach ($p in $j.$sec.PSObject.Properties) { $s[$sec][$p.Name] = $p.Value } }
        }
    }
    $s
}

function Save-GRState($s) {
    if (-not (Test-Path $GR_DataDir)) { New-Item -ItemType Directory -Path $GR_DataDir | Out-Null }
    $tmp = "$GR_StatePath.tmp"
    ($s | ConvertTo-Json -Depth 5) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item $tmp $GR_StatePath -Force
}

function Get-GRPref([string]$exe) {
    $k = Get-Item $GR_PrefKey -ErrorAction SilentlyContinue
    if ($k) { $k.GetValue($exe) } else { $null }
}

function Set-GRPref([string]$exe, [string]$value) {
    if (-not (Test-Path $GR_PrefKey)) { New-Item -Path $GR_PrefKey -Force | Out-Null }
    New-ItemProperty -Path $GR_PrefKey -Name $exe -Value $value -PropertyType String -Force | Out-Null
}

function Remove-GRPref([string]$exe) {
    Remove-ItemProperty -Path $GR_PrefKey -Name $exe -ErrorAction SilentlyContinue
}

# Our GPU choice merged into an existing value, keeping other flags (Auto HDR and so on).
function New-GRPrefValue([string]$existing, [string]$spec) {
    $keep = @()
    if ($existing) { $keep = @($existing -split ';' | Where-Object { $_ -and $_ -notmatch '^(GpuPreference|SpecificAdapter)=' }) }
    ((@($keep) + "SpecificAdapter=$spec" + $GR_SpecificPref) -join ';') + ';'
}

# True when a GPU is already chosen for this exe (by the user in Settings, or anything else).
function Test-GRHasChoice([string]$existing) {
    if (-not $existing) { return $false }
    if ($existing -match 'SpecificAdapter=') { return $true }
    if ($existing -match '(^|;)GpuPreference=([1-9]\d*)') { return $true }
    $false   # no value, or GpuPreference=0 ("Let Windows decide")
}

function Test-GRUnderPath([string]$path, $prefixes) {
    foreach ($p in $prefixes) {
        $pp = if ($p.EndsWith('\')) { $p } else { "$p\" }
        if ($path.StartsWith($pp, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function Get-GRRunningInstance {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'GpuRouter\.ps1.*-Headless' -and $_.ProcessId -ne $PID }
}
