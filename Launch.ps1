<#
    Entry point for the pinned shortcut and for the module's self-elevation
    spawn. Imports the module and opens the menu, then lets the window CLOSE
    when you exit the menu (the host is launched without -NoExit). It pauses
    only if STARTUP fails, so a module-load error stays on screen instead of
    the window vanishing before you can read it.
#>
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'ScriptLauncher\ScriptLauncher.psd1') -Force
    Start-ScriptLauncher
}
catch {
    Write-Host ""
    Write-Host "ScriptLauncher failed to start: $($_.Exception.Message)" -ForegroundColor Red
    [void](Read-Host "Press Enter to close")
}
