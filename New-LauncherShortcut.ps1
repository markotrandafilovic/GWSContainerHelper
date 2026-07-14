<#
.SYNOPSIS
    Creates a pinnable, always-elevated Start Menu shortcut that opens the
    ScriptLauncher menu -- so you never have to open an admin PowerShell and
    type 'launch' by hand.

.DESCRIPTION
    Writes "<Start Menu>\Programs\<Name>.lnk" pointing at Windows PowerShell
    running Launch.ps1, and flips the shortcut's "Run as administrator" bit so a
    single click prompts for UAC once and comes up already elevated (the launcher
    then skips its own self-elevation).

    After running this, press the Windows key and type the name to find it, and
    right-click -> "Pin to Start" or "Pin to taskbar". Re-run any time to
    refresh it (e.g. if you move the repo).

.PARAMETER Name
    Shortcut display name (default 'GWS Launcher').

.PARAMETER ModuleManifest
    Path to ScriptLauncher.psd1 (defaults to ScriptLauncher\ScriptLauncher.psd1,
    relative to this script at the repo root).

.EXAMPLE
    .\New-LauncherShortcut.ps1
.EXAMPLE
    .\New-LauncherShortcut.ps1 -Name 'BC Deps'
#>
param(
    [string] $Name = 'GWS Launcher',
    [string] $ModuleManifest = (Join-Path $PSScriptRoot 'ScriptLauncher\ScriptLauncher.psd1')
)

$ErrorActionPreference = 'Stop'

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $psExe)) { throw "Windows PowerShell not found at: $psExe" }

# Confirm the launcher module is present before creating a shortcut that depends
# on it (Launch.ps1 imports it at runtime); Resolve-Path throws if it's missing.
$null = (Resolve-Path -LiteralPath $ModuleManifest).Path

# Launch through Launch.ps1 (repo root, next to this script): -NoProfile keeps it
# self-contained (works even if the profile import is ever removed), and there
# is NO -NoExit, so the window CLOSES when you quit the menu. The entry script
# pauses only on a startup failure so errors stay readable.
$entry = Join-Path $PSScriptRoot 'Launch.ps1'
if (-not (Test-Path $entry)) { throw "Entry script not found: $entry" }
$argLine = "-NoProfile -ExecutionPolicy Bypass -File ""$entry"""

$programs = [Environment]::GetFolderPath('Programs')   # ...\Start Menu\Programs
$lnkPath  = Join-Path $programs "$Name.lnk"

$shell = New-Object -ComObject WScript.Shell
try {
    $sc = $shell.CreateShortcut($lnkPath)
    $sc.TargetPath       = $psExe
    $sc.Arguments        = $argLine
    $sc.WorkingDirectory = $PSScriptRoot
    $sc.IconLocation     = "$psExe,0"
    $sc.Description       = 'Open the GWS ScriptLauncher menu (elevated)'
    $sc.WindowStyle      = 1
    $sc.Save()
}
finally {
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}

# Set the shortcut's "Run as administrator" flag: byte 0x15 of the .lnk header,
# bit 0x20. WScript.Shell can't set this, so patch the file directly.
$bytes = [System.IO.File]::ReadAllBytes($lnkPath)
$bytes[0x15] = $bytes[0x15] -bor 0x20
[System.IO.File]::WriteAllBytes($lnkPath, $bytes)

Write-Host "Created elevated shortcut:" -ForegroundColor Green
Write-Host "  $lnkPath"
Write-Host ""
Write-Host "Pin it: press the Windows key, type '$Name', then right-click ->" -ForegroundColor Green
Write-Host "  'Pin to Start' or 'Pin to taskbar'. Clicking it prompts UAC once, then opens the menu."
