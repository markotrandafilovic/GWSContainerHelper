<#
.SYNOPSIS
    Creates a test-ready local BC container for one AL project in a single step:
    a fresh container WITH the test toolkit, then that project's dependencies
    installed in test mode.

.DESCRIPTION
    A thin orchestrator over the two scripts you would otherwise run back to
    back when you start work on a project:

      Step 1 - new-container.ps1 -IncludeTestToolkit
               Creates a fresh 'de' sandbox container and imports the BC test
               toolkit. The toolkit is what makes the container test-ready: the
               application Test Libraries, System Application Test Library and
               the Tests-* suites that GWS test apps depend on are Microsoft
               apps that a bare sandbox artifact does NOT publish, and Step 2's
               dependency installer skips Microsoft apps -- so nothing but this
               import supplies them. (Only the core Test Framework -- Library
               Assert, Any, Library Variable Storage, Test Runner -- ships in a
               plain container.) new-container.ps1 prompts once, in-terminal,
               for the container credentials and caches them.

      Step 2 - GWSInstallDependencies.ps1 (test mode)
               Downloads the latest CI artifacts, resolves this project's
               transitive GWS dependencies INCLUDING its 'app test' layout
               (test mode = no -SkipTestApps), and publishes them to the
               container just created, reusing the cached credentials.

    Both steps reach the local container engine, so an elevated (Administrator)
    session is required; that is checked up front and fails immediately.

    Partial failure is intentional: if Step 1 succeeds but Step 2 fails, the
    created container is left in place -- re-run "Install GWS Dependencies" for
    the project rather than rebuilding the container. If Step 1 fails, Step 2 is
    never attempted.

.PARAMETER ContainerName
    Name for the NEW container to create. Required -- you name each container.

.PARAMETER ProjectRoot
    Root folder of the AL project whose dependencies to install. Required. A
    bare name (e.g. "Core") is resolved as a folder under -AlRoot; a rooted path
    is used as-is (the same rule as GWSInstallDependencies.ps1).

.PARAMETER AlRoot
    Root folder containing all AL project checkouts, under which a bare
    -ProjectRoot name is resolved and forwarded to Step 2. Defaults to the
    AlRoot setting (ScriptLauncher\Config\Settings.json), else the built-in
    default.

.EXAMPLE
    .\New-ProjectContainer.ps1 -ContainerName GWS-Core -ProjectRoot Core

.NOTES
    Requires an elevated session, the BcContainerHelper module + Docker (both
    steps) and Azure CLI + the azure-devops extension (Step 2's download). See
    new-container.ps1 and GWSInstallDependencies.ps1 for each step's full
    prerequisites and its credential handling (the shared DPAPI cache is what
    lets Step 1's single prompt satisfy Step 2).
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Intentional: colored terminal output for interactive use')]
param(
    [string]$AlRoot = '',
    [Parameter(Mandatory)]
    [string]$ProjectRoot,
    [Parameter(Mandatory)]
    [string]$ContainerName
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# AlRoot resolution mirrors GWSInstallDependencies.ps1: fall back to the AlRoot
# setting when the parameter wasn't passed explicitly, so a bare -ProjectRoot
# name and the value forwarded to Step 2 line up with the rest of the toolset.
. (Join-Path $PSScriptRoot "Common\LauncherConfig.ps1")
if (-not $PSBoundParameters.ContainsKey('AlRoot')) { $AlRoot = Get-LauncherConfigValue 'AlRoot' $AlRoot }

function Test-IsElevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Both steps reach the container engine, so elevation is always required. Check
# up front so a non-elevated run fails immediately, not partway through creating
# the container (new-container.ps1 has no up-front elevation check of its own).
if (-not (Test-IsElevated)) {
    throw "This script must run from an elevated (Administrator) PowerShell session to create and publish to a BC container. Re-run as Administrator."
}

# A bare -ProjectRoot name (e.g. "Core") is resolved as a folder under -AlRoot by
# Step 2. Fail up front -- before creating a container -- when AlRoot isn't set,
# so a fresh clone doesn't build a container only to error on project resolution.
if (-not [System.IO.Path]::IsPathRooted($ProjectRoot) -and [string]::IsNullOrWhiteSpace($AlRoot)) {
    throw "AlRoot is not configured, so the project name '$ProjectRoot' can't be resolved to a folder. Set AlRoot in the launcher's Settings menu, pass -AlRoot, or pass -ProjectRoot as a full path."
}

$newContainerScript = Join-Path $PSScriptRoot "new-container.ps1"
$installDepsScript  = Join-Path $PSScriptRoot "GWSInstallDependencies.ps1"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Create Project Container"                                    -ForegroundColor Cyan
Write-Host "  Container: $ContainerName"                                   -ForegroundColor Cyan
Write-Host "  Project:   $ProjectRoot"                                     -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# --- Step 1: create the container WITH the test toolkit ---------------------
# -IncludeTestToolkit is what makes this a *test* container; see .DESCRIPTION
# for why the dependency installer can't stand in for it. new-container.ps1
# prompts for and caches the credentials Step 2 then reuses.
Write-Host "`n[STEP 1/2] Creating container '$ContainerName' with the test toolkit..." -ForegroundColor Yellow
& $newContainerScript -ContainerName $ContainerName -IncludeTestToolkit

# --- Step 2: install the project's dependencies in test mode ----------------
# Test mode = no -SkipTestApps, so the project's 'app test' layout is resolved
# and its GWS test dependencies are published too. On failure the container is
# deliberately left in place -- creating it is the slow part, so re-running just
# the install is far cheaper than rebuilding.
Write-Host "`n[STEP 2/2] Installing '$ProjectRoot' dependencies (test mode) into '$ContainerName'..." -ForegroundColor Yellow
try {
    & $installDepsScript -ContainerName $ContainerName -ProjectRoot $ProjectRoot -AlRoot $AlRoot
}
catch {
    Write-Host "`nContainer '$ContainerName' was created, but installing its dependencies failed." -ForegroundColor Red
    Write-Host "The container is left in place -- fix the issue and re-run 'Install GWS Dependencies' for '$ProjectRoot'; there's no need to recreate the container." -ForegroundColor Yellow
    throw
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "  Project container ready: '$ContainerName' ($ProjectRoot)"    -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
