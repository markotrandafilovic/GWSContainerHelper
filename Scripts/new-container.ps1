<#
.SYNOPSIS
    Creates a new local BC sandbox container and imports the dev license.
    Optionally installs the test toolkit, for a container meant for
    automated-test runs rather than everyday development.

.PARAMETER ContainerName
    Name for the new BC container. Required -- you name each container you
    create, so there is no default.

.PARAMETER LicenseFile
    Path to the BC developer license (.bclicense) to apply. Defaults to the
    LicenseFile setting (ScriptLauncher\Config\Settings.json), or DEV.bclicense
    next to this script when that isn't set.

.PARAMETER IncludeTestToolkit
    Installs the BC test toolkit into the container. Leave off for an
    everyday development container; pass it for a container meant to run
    automated tests.

.EXAMPLE
    .\new-container.ps1 -ContainerName "GWS"

.EXAMPLE
    .\new-container.ps1 -ContainerName "GWS-Test" -IncludeTestToolkit

.NOTES
    Requires the BcContainerHelper PowerShell module and Docker.
    Country is fixed to 'de'. You are prompted in-terminal for the container
    username + password, which are cached (DPAPI-encrypted) and shared with
    GWSInstallDependencies.ps1 so it can authenticate to this container.
#>

param(
    [Parameter(Mandatory)]
    [string]$ContainerName,
    [string]$LicenseFile = (Join-Path $PSScriptRoot "DEV.bclicense"),
    [switch]$IncludeTestToolkit
)

$ErrorActionPreference = "Stop"

# Country is fixed -- we always build 'de' sandbox artifacts.
$Country = 'de'

# Apply user configuration (ScriptLauncher\Config\Settings.json). LicenseFile
# falls back to the param default (DEV.bclicense beside this script); an
# explicit -LicenseFile always wins over config.
. (Join-Path $PSScriptRoot "Common\LauncherConfig.ps1")
. (Join-Path $PSScriptRoot "Common\ContainerCredential.ps1")
if (-not $PSBoundParameters.ContainsKey('LicenseFile')) {
    $LicenseFile = Get-LauncherConfigValue 'LicenseFile' $LicenseFile
}

if (-not (Test-Path $LicenseFile)) {
    throw "License file not found: $LicenseFile"
}

# A new container *defines* its own credentials, so always prompt fresh (and
# cache them, so GWSInstallDependencies.ps1 can authenticate to this container).
$credential = New-ContainerCredential

$artifactUrl = Get-BcArtifactUrl -type 'Sandbox' -country $Country -select Latest

New-BcContainer `
    -accept_eula `
    -containerName $ContainerName `
    -credential $credential `
    -auth 'UserPassword' `
    -artifactUrl $artifactUrl `
    -multitenant:$false `
    -assignPremiumPlan `
    -licenseFile $LicenseFile `
    -memoryLimit 12G `
    -updateHosts

if ($IncludeTestToolkit) {
    Import-TestToolkitToBcContainer -containerName $ContainerName -credential $credential -Verbose
}

Restart-BcContainerServiceTier -ContainerName $ContainerName -Verbose
