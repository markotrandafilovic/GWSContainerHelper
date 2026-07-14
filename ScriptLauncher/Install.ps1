<#
.SYNOPSIS
    Installs the ScriptLauncher module into a PowerShell module path, so
    `Import-Module ScriptLauncher` / `launch` work in any new session with no
    PATH or profile edits.

.DESCRIPTION
    Links (or, with -Copy, copies) this folder to:
      - Windows PowerShell 5.1: Documents\WindowsPowerShell\Modules\ScriptLauncher
      - PowerShell 7+:          Documents\PowerShell\Modules\ScriptLauncher
    depending on which PowerShell edition runs this installer. A symlink means
    edits made directly in this repo take effect immediately in new sessions;
    if symlink creation is blocked (no Developer Mode / not elevated), it
    falls back to a one-time copy and tells you to re-run after future edits.

.PARAMETER Copy
    Skip the symlink attempt and copy the folder instead.

.EXAMPLE
    .\Install.ps1
#>

param(
    [switch] $Copy
)

$ErrorActionPreference = "Stop"

$moduleFolderName = if ($PSVersionTable.PSVersion.Major -ge 6) { 'PowerShell' } else { 'WindowsPowerShell' }
$modulesRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "$moduleFolderName\Modules"
$target = Join-Path $modulesRoot 'ScriptLauncher'

if (-not (Test-Path $modulesRoot)) {
    New-Item -ItemType Directory -Path $modulesRoot -Force | Out-Null
}

if (Test-Path $target) {
    $existing = Get-Item -LiteralPath $target
    if ($existing.LinkType) {
        Remove-Item -LiteralPath $target -Force
    }
    else {
        throw "A non-symlink folder already exists at '$target'. Remove it manually before installing."
    }
}

if (-not $Copy) {
    try {
        New-Item -ItemType SymbolicLink -Path $target -Target $PSScriptRoot | Out-Null
        Write-Host "Linked $target -> $PSScriptRoot" -ForegroundColor Green
        Write-Host "Run 'Import-Module ScriptLauncher' then 'launch' to start." -ForegroundColor Green
        return
    }
    catch {
        Write-Warning "Could not create a symlink ($($_.Exception.Message)); falling back to a copy. Re-run Install.ps1 after future edits to pick up changes."
    }
}

Copy-Item -Path $PSScriptRoot -Destination $target -Recurse -Force
Write-Host "Copied $PSScriptRoot -> $target" -ForegroundColor Green
Write-Host "Run 'Import-Module ScriptLauncher' then 'launch' to start." -ForegroundColor Green
