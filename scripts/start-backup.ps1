#Requires -Version 5.1
<#
  Starts the iPhone Photo Backup server.
  Double-click "Start Backup.cmd" in the project folder, or run:
      .\scripts\start-backup.ps1 [-Port 8787] [-NoBrowser]
  Changes nothing system-wide: no installs, no firewall rules, no environment variables
  outside this window. Press Ctrl+C to stop.
#>
param(
  [int]$Port = 8787,
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

function Fail([string]$Message) {
  Write-Host ''
  Write-Host $Message -ForegroundColor Red
  Write-Host ''
  exit 1
}

# --- runtime checks -----------------------------------------------------------
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Fail 'Node.js is not installed. Install the current LTS from https://nodejs.org (version 22.18 or newer), then run this again.'
}
$nodeVersion = [version]((& node -v).TrimStart('v'))
if ($nodeVersion -lt [version]'22.18.0') {
  Fail "Node.js $nodeVersion is too old. This app needs 22.18 or newer (it runs TypeScript directly and uses Node's built-in SQLite)."
}

if (-not (Test-Path 'node_modules')) {
  Write-Host 'First run: installing dependencies into this folder (one time)...'
  & npm install
  if ($LASTEXITCODE -ne 0) { Fail 'npm install failed. Check your internet connection and try again.' }
}
if (-not (Test-Path 'web\dist\index.html')) {
  Write-Host 'Building the web interface (one time)...'
  & npm run build
  if ($LASTEXITCODE -ne 0) { Fail 'Building the web interface failed.' }
}

# --- run ----------------------------------------------------------------------
$env:PHOTOSYNC_PORT = $Port   # this process only
$nodeArgs = @('--disable-warning=ExperimentalWarning', 'server/main.ts')
if ($NoBrowser) { $nodeArgs += '--no-open' }

# The server prints the dashboard URL, the iPhone address, a QR code, and a clear message
# if the port is already in use. Ctrl+C stops it cleanly.
& node @nodeArgs
exit $LASTEXITCODE
