<#
.SYNOPSIS
    Imports a BC developer license into a local container and restarts it.

.PARAMETER ContainerName
    Name of the local BC container. Required.

.PARAMETER LicenseFile
    Path to the BC developer license (.bclicense) to import. Defaults to the
    LicenseFile setting (ScriptLauncher\Config\Settings.json), or DEV.bclicense
    next to this script when that isn't set.

.EXAMPLE
    .\UploadLicense.ps1 -ContainerName "GWS-Test"
#>

param(
    [Parameter(Mandatory)]
    [string]$ContainerName,
    [string]$LicenseFile = (Join-Path $PSScriptRoot "DEV.bclicense")
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common\LauncherConfig.ps1")

# LicenseFile falls back to the param default (DEV.bclicense beside this
# script); an explicit -LicenseFile always wins over config.
if (-not $PSBoundParameters.ContainsKey('LicenseFile')) {
    $LicenseFile = Get-LauncherConfigValue 'LicenseFile' $LicenseFile
}

if (-not (Test-Path $LicenseFile)) {
    throw "License file not found: $LicenseFile"
}

Import-BcContainerLicense -licenseFile $LicenseFile -containerName $ContainerName
Restart-BcContainer $ContainerName
