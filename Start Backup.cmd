@echo off
rem Double-click to start the iPhone Photo Backup server. Close the window or press Ctrl+C to stop.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-backup.ps1" %*
if errorlevel 1 pause
