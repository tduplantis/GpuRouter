@echo off
rem Double-click to open GpuRouter setup. Passes any arguments through, for example: Setup.cmd -Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" %*
