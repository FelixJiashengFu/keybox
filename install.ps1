# Installs dist\KeyBox.exe for the current user:
#   %LOCALAPPDATA%\Programs\KeyBox\KeyBox.exe  + desktop and Start-menu shortcuts.
# Re-run after build.ps1 to update. Your vault (%APPDATA%\KeyBox) is not touched.
# Usage:  powershell -ExecutionPolicy Bypass -File install.ps1 [-Uninstall]
# Keep this file pure ASCII: Windows PowerShell 5.1 reads scripts as the ANSI code page.
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$appName = [string][char]0x5BC6 + [char]0x94A5 + [char]0x5323   # the Chinese app name
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\KeyBox'
$exe = Join-Path $installDir 'KeyBox.exe'
$links = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "$appName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Programs')) "$appName.lnk")
)

if (Get-Process -Name KeyBox -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) {
    throw 'KeyBox is running. Lock it and close the window first, then run this again.'
}

if ($Uninstall) {
    foreach ($l in $links) { if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l } }
    if (Test-Path $installDir) { Remove-Item -Recurse $installDir }
    Write-Host "Removed $installDir and the shortcuts. Your vault in $env:APPDATA\KeyBox was left alone."
    return
}

$source = Join-Path $PSScriptRoot 'dist\KeyBox.exe'
if (-not (Test-Path $source)) { throw "Build first: $source not found (run build.ps1)" }

New-Item -ItemType Directory -Force $installDir | Out-Null
Copy-Item $source $exe -Force

$shell = New-Object -ComObject WScript.Shell
foreach ($l in $links) {
    $s = $shell.CreateShortcut($l)
    $s.TargetPath = $exe
    $s.WorkingDirectory = $installDir
    $s.IconLocation = "$exe,0"
    $s.Description = 'KeyBox - encrypted API key vault'
    $s.Save()
}
Write-Host "Installed $exe"
$links | ForEach-Object { Write-Host "Shortcut  $_" }
