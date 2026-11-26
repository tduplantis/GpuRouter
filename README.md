# GpuRouter

[![Donate with Venmo](https://img.shields.io/badge/Donate-Venmo-008CFF?logo=venmo&logoColor=white)](https://venmo.com/u/TerryDuplantisJr)

Keep your gaming GPU for games. GpuRouter automatically sends every app that is **not** a game to a second GPU in Windows: browsers, chat apps, launchers, RGB tools and video players.

You pick three things:

1. **Your game drive(s) or folders.** Anything that runs from there counts as a game.
2. **The game GPU.** This is normally the card driving your main monitor, and Setup picks it for you.
3. **The app GPU.** Everything else goes here.

## Why

On a PC with two GPUs, Windows renders every app on the GPU driving your **primary** monitor unless the app is told otherwise. That includes a browser playing video on a side monitor plugged into the second card. Every frame is drawn on the gaming GPU, then copied over PCIe to the other card. That costs the game GPU time, decoder capacity and bus bandwidth, and it shows up as stutter.

Windows can't make an app follow the monitor it's on. An app picks one GPU when it starts. What Windows *does* offer is a per-app **Specific GPU** setting (Settings > System > Display > Graphics). GpuRouter sets it for you, automatically, for every app that isn't a game.

## Requirements

* Windows 11 with the **Specific GPU** option in Settings > System > Display > Graphics > (app) > Options
* Two or more GPUs of **different models.** Windows identifies the Specific GPU by model, so it can't tell two identical cards apart.
* Windows PowerShell 5.1, which ships with Windows. No admin rights needed.

## Install

1. Download or clone this repository.
2. Double-click **`Setup.cmd`**.
3. Check the two GPUs, tick your game drive(s) or add game folders, and click **Install**.

**Preview** shows which running apps would move, without changing anything.

Silent install:

```powershell
.\Setup.ps1 -Silent -GameDrives G -AppGpu "5060"
```

```powershell
.\Setup.ps1 -Silent -GameDrives D,E -GameFolders "C:\Games" -GameGpu "4090" -AppGpu "Radeon"
```

`-GameGpu` and `-AppGpu` take part of the GPU's name. If you leave out `-GameGpu`, Setup uses the GPU driving the main monitor. If you leave out `-AppGpu`, it uses the first other GPU.

## How it works

* Every 10 seconds it reads the Windows **GPU Process Memory** performance counters.
* An app counts as running on the game GPU when most of its GPU memory is there, at least 16 MB.
* If that app isn't under a game path and isn't excluded, GpuRouter writes the same **Specific GPU** value Settings would write (`HKCU\Software\Microsoft\DirectX\UserGpuPreferences`).
* **Windows applies the setting the next time the app starts.** Restart an app to move it right away.
* It **never** changes an app that already has a GPU chosen, so your own choices in Settings always win.
* Every change it makes is recorded, so uninstalling can put things back exactly.
* Entries for exes that disappear, such as old version folders after an update, are cleaned up automatically. New versions are picked up as soon as they run.

## Apps that ignore the Windows setting

Some apps choose their GPU themselves. GpuRouter detects this: when an app it routed restarts and still renders on the game GPU, it logs `IGNORES SETTING` once and leaves it alone. Known examples:

| App | Fix |
|---|---|
| Discord | Settings > Advanced > turn off **Hardware Acceleration** |
| Microsoft Edge WebView2 (widgets, parts of Teams and others) | None needed. Light use. |

Chromium browsers such as Brave, Chrome and Edge honor the setting.

## Commands

Status, what it has routed, and recent log entries:

```powershell
& "$env:LOCALAPPDATA\GpuRouter\bin\GpuRouter.ps1" -Status
```

See what it would route right now, without changing anything:

```powershell
& "$env:LOCALAPPDATA\GpuRouter\bin\GpuRouter.ps1" -Once -DryRun
```

Change settings: run `Setup.cmd` again, or the copy at `%LOCALAPPDATA%\GpuRouter\bin\Setup.ps1`.

Uninstall: use Settings > Apps > Installed apps > **GpuRouter**, or run:

```powershell
& "$env:LOCALAPPDATA\GpuRouter\bin\Setup.ps1" -Uninstall -RestoreEntries
```

Without `-RestoreEntries`, the GPU settings it made stay in place.

## Files

| Location | Purpose |
|---|---|
| `%LOCALAPPDATA%\GpuRouter\bin\` | Installed scripts |
| `%LOCALAPPDATA%\GpuRouter\config.json` | Your choices and exclusions |
| `%LOCALAPPDATA%\GpuRouter\state.json` | Apps it routed and their original values |
| `%LOCALAPPDATA%\GpuRouter\GpuRouter.log` | What it did and when |
| Startup folder `GpuRouter.lnk` | Starts it hidden at logon |

## Exclusions

These are never routed. Edit `config.json`, then run Setup again to apply.

* `ExcludePathPrefixes`: `%WINDIR%\` (Windows' own processes such as DWM and Explorer)
* `ExcludePathContains`: `\steamapps\common\` (Steam games in any library)
* `ExcludeExeNames`: overlays and capture tools that have to stay on the game GPU, including OBS, RTSS, MSI Afterburner, NVIDIA Overlay, Steam overlay, Xbox Game Bar, SteelSeries capture and HWiNFO

## Limitations

* Elevated (admin) apps are invisible to a non-admin process, so they aren't routed. Set those by hand in Settings.
* Microsoft Store apps are routed by exe path. Whether every Store app honors that hasn't been verified. The log flags any that don't.
* An app routed to the app GPU still works on your main monitor, but its frames then cross PCIe in the other direction. Keep routed apps on the app GPU's monitors when you can.

## License

MIT
