<#
.SYNOPSIS
    Keeps a local Business Central (BC) AL dev container in sync with the latest
    GWS/VEO dependency apps: download -> resolve -> publish.

.DESCRIPTION
    Three steps, run in sequence, each independently skippable:

      Step 1 - Download : Downloads every app-package artifact from the most
                          recent successful run of the "Release-Canary" pipeline
                          on Azure DevOps (GWS-gevis / VEO). Skippable with
                          -SkipDownload to reuse the newest already-downloaded run.

      Step 2 - Resolve  : Reads the target project's declared dependencies and
                          walks the graph transitively (via each .app's
                          NavxManifest.xml), always preferring the NEWEST version
                          available among the downloaded artifacts and skipping
                          Microsoft/platform dependencies. Resolution always runs
                          (Step 3 needs it). The resolved files are only written
                          into the project's own .alpackages folder(s) when
                          -CopyToProject is passed -- a normal run never touches
                          the project folder.

      Step 3 - Publish  : Installs each resolved dependency on the container,
                          handling whatever state is already there:
                            - Same version already installed (any scope) -> skip
                            - Different version, non-Dev scope            -> upgrade,
                              falling back to unpublish + reinstall on failure
                            - Different version, Dev scope                -> unpublish + reinstall
                            - Not installed                              -> fresh install
                          A single failure never stops the run: every dependency
                          is attempted and all failures are reported together at
                          the end. Skippable with -SkipPublish.

    Publishing reaches the local container engine and therefore requires an
    elevated (Administrator) session. That precondition is checked up front and
    fails immediately (unless -SkipPublish is set, in which case nothing touches
    the container engine and elevation isn't required).

.PARAMETER AlRoot
    Root folder containing all AL project checkouts, under which a bare
    -ProjectRoot name is resolved. Defaults to the AlRoot setting
    (ScriptLauncher\Config\Settings.json).

.PARAMETER ProjectRoot
    Root folder of the AL project. Required. app.json is looked for in:
      - $ProjectRoot\app.json          (single project at root)
      - $ProjectRoot\app\app.json      (standard subfolder layout)
      - $ProjectRoot\app test\app.json (test app subfolder)
    A bare name (e.g. "Core") is treated as shorthand for that folder under
    -AlRoot, not a path relative to the current directory; a rooted path is used
    as-is.

.PARAMETER ContainerName
    Name of the local BC container to publish to. Required when publishing
    (i.e. unless -SkipPublish is set, in which case it's ignored).

.PARAMETER SkipDownload
    Skip Step 1. Reuses the newest already-downloaded run folder in Downloads.

.PARAMETER CopyToProject
    Also copy the resolved dependency .app files into the project's .alpackages
    folder(s). Off by default -- a normal run leaves the project folder untouched
    and only updates the container. Use this when you also want an up-to-date
    local compile against these dependencies.

.PARAMETER SkipPublish
    Skip Step 3. Only downloads and resolves (and copies, if -CopyToProject).

.EXAMPLE
    .\GWSInstallDependencies.ps1

.EXAMPLE
    .\GWSInstallDependencies.ps1 -SkipDownload

.EXAMPLE
    .\GWSInstallDependencies.ps1 -CopyToProject

.EXAMPLE
    .\GWSInstallDependencies.ps1 -ProjectRoot Core -SkipPublish
    # Download + resolve only; no elevation or container required.

.NOTES
    Prerequisites:
      - Azure CLI installed and in PATH
      - Azure DevOps extension: az extension add --name azure-devops
      - BcContainerHelper PowerShell module: Install-Module BcContainerHelper

    Authentication (first-time or when the token has expired):
      az login --allow-no-subscriptions --tenant 31f142f5-df76-4112-80a3-19bce6a47b15

    Organization : https://dev.azure.com/GWS-gevis
    Project      : VEO
    Pipeline     : Release-Canary

    The container credentials are never taken on the command line. You are
    prompted in-terminal (username echoed, password hidden) and the resulting
    credential is cached DPAPI-encrypted at
    "$env:LOCALAPPDATA\GWSInstallDependencies\bc-container-credential.xml" (tied
    to this Windows user + machine, useless if copied elsewhere) and shared with
    new-container.ps1. If a publish fails with an auth-looking error, the cache
    is cleared and you're re-prompted automatically (no reset switch needed).
#>

# Suppressions for rules that do not apply to an interactive, non-module script.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost',                        '', Justification = 'Intentional: colored terminal output for interactive use')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',  '', Justification = 'Private helper functions inside a script, not exported cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter',                      '', Justification = 'False positive: parameters are used inside catch blocks and stored collections')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters',             '', Justification = 'Positional message argument is idiomatic for Write-Host / Write-Warning')]
param(
    [string]$AlRoot        = '',
    [Parameter(Mandatory)]
    [string]$ProjectRoot,
    [string]$ContainerName = '',
    [switch]$SkipDownload,
    [switch]$CopyToProject,
    [switch]$SkipPublish,
    [switch]$SkipTestApps
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Select-ALProject.ps1 also defines Find-ProjectFile, used in Step 2's project
# discovery. The interactive project picker itself is not used here (ProjectRoot
# is a required parameter), only that file-discovery helper.
. (Join-Path $PSScriptRoot "Common\Select-ALProject.ps1")

# --- Fixed environmental facts (not tunable knobs) --------------------------
$OrganizationUrl = "https://dev.azure.com/GWS-gevis"
$Project         = "VEO"
$PipelineName    = "Release-Canary"
$RunFolderPrefix = "$PipelineName-run-"

$DownloadsPath   = Join-Path $env:USERPROFILE "Downloads"

# --- Per-run publish state (script-scoped so the publish helpers can share it) ---
$script:PublishedApps   = @{}
$script:FailedPublishes = [System.Collections.Generic.List[object]]::new()

# ===========================================================================
# Environment / CLI helpers
# ===========================================================================

function Test-IsElevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# $ErrorActionPreference = "Stop" only governs PowerShell cmdlets, not native
# executables like az.exe -- a failed az call doesn't throw on its own, so every
# az invocation must be checked explicitly against $LASTEXITCODE.
function Assert-LastExitCode([string]$Description) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed (external exit code $LASTEXITCODE)."
    }
}

function Initialize-Directory([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

# ===========================================================================
# Version helpers
# ===========================================================================

function Get-VersionTuple([string]$Version) {
    if (-not $Version) { return @(0, 0, 0, 0) }
    $nums = @()
    foreach ($part in ($Version.Trim() -split '\.')) {
        $n = 0
        [int]::TryParse($part, [ref]$n) | Out-Null
        $nums += $n
    }
    while ($nums.Count -lt 4) { $nums += 0 }
    if ($nums.Count -gt 4)    { $nums = $nums[0..3] }
    return $nums
}

# Returns 1 if $A > $B, -1 if $A < $B, 0 if equal (4-part numeric compare).
function Compare-AppVersion([string]$A, [string]$B) {
    $ta = Get-VersionTuple $A
    $tb = Get-VersionTuple $B
    for ($i = 0; $i -lt 4; $i++) {
        if ($ta[$i] -gt $tb[$i]) { return 1 }
        if ($ta[$i] -lt $tb[$i]) { return -1 }
    }
    return 0
}

# Picks the package with the highest .version. NOTE the parentheses around the
# Compare-AppVersion call: without them, `-gt 0` binds as extra arguments to the
# function instead of comparing its result, and the "highest" selection silently
# collapses to "last one that differs" -- an older version can win. This is the
# single most important line in the tool; it has a dedicated test.
function Select-HighestVersionPackage {
    param([object[]]$Packages)

    $list = @($Packages)
    if ($list.Count -eq 0) { return $null }

    $best = $list[0]
    for ($i = 1; $i -lt $list.Count; $i++) {
        if ((Compare-AppVersion $list[$i].version $best.version) -gt 0) {
            $best = $list[$i]
        }
    }
    return $best
}

# ===========================================================================
# Container credentials
#
# Prompting and DPAPI-encrypted caching of the container PSCredential live in
# Common\ContainerCredential.ps1 (dot-sourced after the guard below), shared
# with new-container.ps1. This script consumes the cache and self-heals on an
# auth-looking failure; the heuristic for "auth-looking" is below.
# ===========================================================================

# Heuristic: does a Publish-BcContainerApp failure look like a bad password
# rather than a genuine publish problem? Used to decide whether a failed first
# publish should trigger a password re-prompt (stale cache) or just fall through
# to the normal retry pass. Deliberately conservative -- when unsure, treat it as
# a publish failure and DON'T disturb a working cached password.
function Test-LooksLikeAuthFailure([string]$Message) {
    if (-not $Message) { return $false }
    return $Message -match '(?i)(401|403|unauthor|forbidden|credential|password|logon|log on|authenticat|access is denied|bad ?request.*sign)'
}

# ===========================================================================
# Project discovery
# ===========================================================================

# Find-ProjectFile lives in Common\Select-ALProject.ps1 (dot-sourced above).

# Resolves -ProjectRoot to a concrete path: a folder under -AlRoot when a bare
# name, or as-is when already rooted.
function Resolve-ProjectRoot([string]$ProjectRoot, [string]$AlRoot) {
    if (-not [System.IO.Path]::IsPathRooted($ProjectRoot)) {
        # A bare name ("Core") is shorthand for a folder under -AlRoot, not a
        # path relative to the current working directory (which never matches).
        if ([string]::IsNullOrWhiteSpace($AlRoot)) {
            throw "AlRoot is not configured, so the project name '$ProjectRoot' can't be resolved to a folder. Set AlRoot in the launcher's Settings menu, pass -AlRoot, or pass -ProjectRoot as a full path."
        }
        return Join-Path $AlRoot $ProjectRoot
    }
    return $ProjectRoot
}

# ===========================================================================
# Artifact folder selection
# ===========================================================================

# Picks the folder with the highest NUMERIC run id. Sorting folder names as
# strings is wrong: "...run-9" sorts above "...run-100" lexicographically, so a
# lexical sort silently reuses an older run when the id's digit count changes.
function Select-LatestRunFolder {
    param([object[]]$Folders, [string]$Prefix)

    $pattern  = '^' + [regex]::Escape($Prefix) + '(\d+)$'
    $numbered = @($Folders | Where-Object { $_.Name -match $pattern })
    if ($numbered.Count -eq 0) { return $null }

    return $numbered |
        Sort-Object { [int64]($_.Name.Substring($Prefix.Length)) } -Descending |
        Select-Object -First 1
}

# ===========================================================================
# App package (.app) metadata
#
# BC .app files are NAVX containers: a 4-byte "NAVX" magic + header, with the ZIP
# payload starting at byte offset 40. NavxManifest.xml inside carries the id,
# name, publisher, version and dependencies. Falls back to the
# Publisher_Name_Version.app filename convention if the manifest can't be read.
# ===========================================================================

function Read-AppPackageMetadata([string]$AppPath) {
    $meta   = $null
    $ms     = $null
    $zip    = $null
    $stream = $null
    $reader = $null

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null

        $rawBytes  = [System.IO.File]::ReadAllBytes($AppPath)
        $zipOffset = 0
        if ($rawBytes.Length -gt 8 -and
            $rawBytes[0] -eq 0x4E -and $rawBytes[1] -eq 0x41 -and
            $rawBytes[2] -eq 0x56 -and $rawBytes[3] -eq 0x58) {
            $zipOffset = 40
        }

        $ms  = [System.IO.MemoryStream]::new(($rawBytes[$zipOffset..($rawBytes.Length - 1)]), [bool]$false)
        $zip = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Read)

        $entry = $zip.Entries | Where-Object { $_.FullName -ieq "NavxManifest.xml" } | Select-Object -First 1
        if ($entry) {
            $stream  = $entry.Open()
            $reader  = [System.IO.StreamReader]::new($stream)
            [xml]$xml = $reader.ReadToEnd()

            $appNode = $xml.SelectSingleNode("//*[local-name()='App']")
            if ($appNode) {
                $pkgDeps  = @()
                $depNodes = $xml.SelectNodes("//*[local-name()='Dependencies']/*[local-name()='Dependency']")
                if ($depNodes) {
                    foreach ($node in $depNodes) {
                        $pkgDeps += [PSCustomObject]@{
                            id        = "$($node.Id)"
                            name      = "$($node.Name)"
                            publisher = "$($node.Publisher)"
                            version   = if ($node.MinVersion) { "$($node.MinVersion)" } else { "0.0.0.0" }
                        }
                    }
                }

                $meta = [PSCustomObject]@{
                    id           = "$($appNode.Id)"
                    name         = "$($appNode.Name)"
                    publisher    = "$($appNode.Publisher)"
                    version      = "$($appNode.Version)"
                    dependencies = $pkgDeps
                    path         = $AppPath
                }
            }
        }
    }
    catch {
        Write-Warning "Could not read BC manifest from '$AppPath': $($_.Exception.Message) -- falling back to filename parsing."
    }
    finally {
        if ($reader) { try { $reader.Dispose() } catch { $null = $_ } }
        if ($stream) { try { $stream.Dispose() } catch { $null = $_ } }
        if ($zip)    { try { $zip.Dispose()    } catch { $null = $_ } }
        if ($ms)     { try { $ms.Dispose()     } catch { $null = $_ } }
    }

    if (-not $meta) {
        # Fallback: Publisher_Name_Version.app
        $file  = [System.IO.Path]::GetFileNameWithoutExtension($AppPath)
        $parts = $file -split "_"
        $ver   = $parts[-1]
        if ($ver -match '^\d+(\.\d+){1,3}$') {
            $publisher = if ($parts.Count -ge 3) { $parts[0] } else { "" }
            $name      = if ($parts.Count -ge 3) { ($parts[1..($parts.Count - 2)] -join "_") } else { $file }
            $meta = [PSCustomObject]@{ id = ""; name = $name; publisher = $publisher; version = $ver;  dependencies = @(); path = $AppPath }
        }
        else {
            $meta = [PSCustomObject]@{ id = ""; name = $file; publisher = ""; version = ""; dependencies = @(); path = $AppPath }
        }
    }

    return $meta
}

function New-AppPackageIndex([string]$RootFolder) {
    $index = [System.Collections.Generic.List[object]]::new()
    Get-ChildItem -Path $RootFolder -Recurse -Filter *.app -File | ForEach-Object {
        $index.Add((Read-AppPackageMetadata $_.FullName))
    }
    return @($index)
}

# ===========================================================================
# Dependency matching + transitive resolution
# ===========================================================================

# Match a declared dependency against an indexed package: by app id when both
# carry one, otherwise by name + publisher (Microsoft/empty publisher matches any).
function Test-DependencyMatch($Dep, $Package) {
    $depId = ("$($Dep.id)").Trim()
    $pkgId = ("$($Package.id)").Trim()
    if ($depId -and $pkgId) {
        return ($depId.ToLower() -eq $pkgId.ToLower())
    }

    $depName = ("$($Dep.name)").Trim()
    $pkgName = ("$($Package.name)").Trim()
    if (-not $depName -or -not $pkgName)         { return $false }
    if ($depName.ToLower() -ne $pkgName.ToLower()) { return $false }

    $depPub = ("$($Dep.publisher)").Trim()
    $pkgPub = ("$($Package.publisher)").Trim()
    if (-not $depPub)                      { return $true }
    if ($depPub.ToLower() -eq "microsoft") { return $true }
    return ($depPub.ToLower() -eq $pkgPub.ToLower())
}

function Get-DependencyKey($Dep) {
    $pub  = ("$($Dep.publisher)").Trim()
    $name = ("$($Dep.name)").Trim()
    return ($pub + '|' + $name).ToLower()
}

# Walks the dependency graph depth-first, emitting each package AFTER its own
# dependencies (dependency-first / topological order). Skips Microsoft/platform
# deps. $Visited and $BrokenKeys are shared by reference across the recursion so
# every package is resolved once and broken chains propagate to their dependents.
function Resolve-TransitiveDependency {
    param(
        [object[]]$RootDeps,
        [object[]]$PackageIndex,
        [hashtable]$Visited,
        [hashtable]$BrokenKeys
    )

    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($dep in $RootDeps) {
        $depPub = ("$($dep.publisher)").Trim()
        if (-not $depPub -or $depPub -ieq "Microsoft") { continue }

        $depName       = ("$($dep.name)").Trim()
        $depKey        = Get-DependencyKey $dep
        $depMinVersion = ("$($dep.version)").Trim()

        if ($Visited.ContainsKey($depKey)) {
            $prev = $Visited[$depKey]
            if ($prev -and $depMinVersion -and (Compare-AppVersion $prev.version $depMinVersion) -lt 0) {
                Write-Warning "VERSION CONFLICT: $depPub / $depName already resolved to v$($prev.version), but another dependent needs >= v$depMinVersion. Keeping v$($prev.version) -- verify compatibility."
            }
            continue
        }

        $pkgMatches = @($PackageIndex | Where-Object { Test-DependencyMatch $dep $_ })
        if ($pkgMatches.Count -eq 0) {
            Write-Warning "DEP NOT FOUND in artifacts: $depPub / $depName -- dependent app will be skipped."
            $BrokenKeys[$depKey] = $true
            $Visited[$depKey]    = $null
            continue
        }

        $best = Select-HighestVersionPackage $pkgMatches
        if ($depMinVersion -and (Compare-AppVersion $best.version $depMinVersion) -lt 0) {
            Write-Warning "$depPub / $depName resolved to v$($best.version), LOWER than the required minimum v$depMinVersion. The artifacts may not contain a compatible version."
        }

        # Mark visited BEFORE recursing so a dependency cycle can't loop forever.
        $Visited[$depKey] = $best

        $thisBroken = $false
        if ($best.dependencies -and @($best.dependencies).Count -gt 0) {
            $subItems = Resolve-TransitiveDependency `
                -RootDeps     $best.dependencies `
                -PackageIndex $PackageIndex `
                -Visited      $Visited `
                -BrokenKeys   $BrokenKeys
            foreach ($item in $subItems) { $result.Add($item) }

            # If any direct dependency in this package's chain is broken, this
            # package can't be published either.
            foreach ($subDep in $best.dependencies) {
                $subPub = ("$($subDep.publisher)").Trim()
                if (-not $subPub -or $subPub -ieq "Microsoft") { continue }
                if ($BrokenKeys.ContainsKey((Get-DependencyKey $subDep))) { $thisBroken = $true; break }
            }
        }

        if ($thisBroken) {
            Write-Warning "SKIPPING '$depPub / $depName' -- a dependency in its chain is missing."
            $BrokenKeys[$depKey] = $true
        }
        else {
            $result.Add([PSCustomObject]@{ dep = $dep; package = $best })
        }
    }

    return @($result)
}

# ===========================================================================
# Local .alpackages copy (only when -CopyToProject)
# ===========================================================================

# Reads a project app.json's OWN identity (id/name/publisher), not its
# dependencies -- used to make sure the project's own app(s) are never installed
# as dependencies (see the own-app exclusion in Resolve-ProjectDependency).
function Get-ALAppIdentity([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }

    $json = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return [PSCustomObject]@{
        id        = "$($json.id)"
        name      = "$($json.name)"
        publisher = "$($json.publisher)"
        version   = "$($json.version)"
    }
}

function Get-ALDependenciesFromAppJson([string]$Path) {
    if (-not (Test-Path $Path)) { throw "app.json not found: $Path" }

    $json = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $json.dependencies) { return @() }

    return @($json.dependencies | ForEach-Object {
        [PSCustomObject]@{
            id        = "$($_.id)"
            name      = "$($_.name)"
            publisher = "$($_.publisher)"
            version   = "$($_.version)"
        }
    })
}

function Remove-FileWithRetry([string]$FilePath, [int]$MaxRetries = 5, [int]$DelaySeconds = 2) {
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Remove-Item -Path $FilePath -Force -ErrorAction Stop
            return $true
        }
        catch {
            if ($attempt -lt $MaxRetries) {
                Write-Host "Warning: file locked, retrying in $DelaySeconds second(s)... (attempt $attempt/$MaxRetries)"
                Start-Sleep -Seconds $DelaySeconds
                continue
            }
            # Last resort: rename so it doesn't block future copies.
            try {
                $name    = [System.IO.Path]::GetFileName($FilePath)
                $newName = "_DELETE_ME_" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8) + "_" + $name
                Rename-Item -Path $FilePath -NewName $newName -Force
                Write-Warning "Could not delete (file locked), renamed to: $newName"
                Write-Warning "Close VS Code / the AL extension and delete it manually."
            }
            catch {
                Write-Error "Failed to delete or rename: $FilePath - $_"
            }
            return $false
        }
    }
    return $false
}

function Remove-MatchingPackagesFromTarget([string]$TargetFolder, $Dep) {
    if (-not (Test-Path $TargetFolder)) { return }
    Get-ChildItem -Path $TargetFolder -Filter *.app -File | ForEach-Object {
        $tp = Read-AppPackageMetadata $_.FullName
        if (Test-DependencyMatch $Dep $tp) {
            Write-Host "Removing existing package: $($_.Name) (v=$($tp.version))"
            Remove-FileWithRetry -FilePath $_.FullName | Out-Null
        }
    }
}

# Resolves the transitive dependency order for one app.json (always), and copies
# the resolved files into $TargetFolder only when -CopyToTarget is passed.
# Returns the ordered list of @{ dep; package } items.
function Resolve-ProjectDependency {
    param(
        [string]$AppJson,
        [object[]]$PackageIndex,
        [string]$TargetFolder,
        [string]$Label = "",
        [switch]$CopyToTarget,
        [object[]]$OwnApps = @()
    )

    $prefix   = if ($Label) { "[$Label] " } else { "" }
    $rootDeps = Get-ALDependenciesFromAppJson $AppJson
    if (-not $rootDeps -or @($rootDeps).Count -eq 0) {
        Write-Host "${prefix}No dependencies declared in: $AppJson"
        return @()
    }

    Write-Host "${prefix}Resolving transitive dependencies for: $AppJson"
    $visited    = @{}
    $brokenKeys = @{}
    $ordered    = @(Resolve-TransitiveDependency -RootDeps $rootDeps -PackageIndex $PackageIndex -Visited $visited -BrokenKeys $brokenKeys)

    if ($brokenKeys.Count -gt 0) {
        Write-Warning "${prefix}$($brokenKeys.Count) dep(s) not found in artifacts -- dependent apps skipped (see warnings above)."
    }

    # Never install the project's OWN app(s): a test app declares a dependency on
    # the app it tests, so the main app would otherwise be resolved from the CI
    # artifacts and published over your local dev copy. Drop any resolved package
    # whose identity matches one of this project's own apps.
    if (@($OwnApps).Count -gt 0) {
        $keep = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $ordered) {
            if (@($OwnApps | Where-Object { Test-DependencyMatch $_ $item.package }).Count -gt 0) {
                Write-Host "${prefix}Skipping own app (developed here, not installed): $($item.package.publisher) / $($item.package.name) v$($item.package.version)" -ForegroundColor Gray
            }
            else {
                $keep.Add($item)
            }
        }
        $ordered = @($keep)
    }

    if ($ordered.Count -eq 0) {
        Write-Host "${prefix}No GWS dependencies resolved."
        return @()
    }

    if (-not $CopyToTarget) {
        Write-Host "${prefix}$($ordered.Count) dependency package(s) resolved (not copied -- pass -CopyToProject to update $TargetFolder)."
        return $ordered
    }

    Initialize-Directory $TargetFolder
    $copied = 0
    foreach ($item in $ordered) {
        Remove-MatchingPackagesFromTarget -TargetFolder $TargetFolder -Dep $item.dep
        $destName = [System.IO.Path]::GetFileName($item.package.path)
        Copy-Item -Path $item.package.path -Destination (Join-Path $TargetFolder $destName) -Force
        Write-Host "Copied: $destName (v=$($item.package.version)) -> $TargetFolder"
        $copied++
    }
    Write-Host "${prefix}Copied $copied package(s) to: $TargetFolder"
    return $ordered
}

# ===========================================================================
# BC container publishing (version + scope aware)
# ===========================================================================

function Get-ContainerAppState {
    param([string]$Container, [string]$Publisher, [string]$Name)
    try {
        $apps = @(Get-BcContainerAppInfo -containerName $Container -ErrorAction SilentlyContinue)
        return $apps |
            Where-Object { $_.Publisher -eq $Publisher -and $_.Name -eq $Name } |
            Sort-Object { try { [version]$_.Version } catch { [version]"0.0.0.0" } } -Descending |
            Select-Object -First 1
    }
    catch { return $null }
}

function Unpublish-AppFromContainer {
    param([string]$Container, [string]$Publisher, [string]$Name, [string]$Version)
    Write-Host "  Removing from container: $Publisher.$Name v$Version" -ForegroundColor Yellow

    try { Sync-BcContainerApp      -containerName $Container -appName $Name -publisher $Publisher -version $Version -Mode ForceSync -ErrorAction SilentlyContinue } catch { $null = $_ }
    try { UnInstall-BcContainerApp -containerName $Container -appName $Name -publisher $Publisher -version $Version -Force      -ErrorAction SilentlyContinue } catch { $null = $_ }
    try { UnPublish-BcContainerApp -containerName $Container -appName $Name -publisher $Publisher -version $Version            -ErrorAction SilentlyContinue } catch { $null = $_ }
}

# -useDevEndpoint is intentional on every publish: this container is used for
# active development too, not just as a dependency host.
function Publish-AppSmart {
    param(
        [string]$AppFilePath,
        [string]$Publisher,
        [string]$Name,
        [string]$ArtifactVersion,
        [string]$Container,
        [pscredential]$Credential
    )

    $key = "$Publisher|$Name".ToLower()
    if ($script:PublishedApps.ContainsKey($key)) {
        Write-Host "  Already processed this run: $Publisher.$Name" -ForegroundColor Gray
        return
    }

    $existing = Get-ContainerAppState -Container $Container -Publisher $Publisher -Name $Name
    if ($existing) {
        $scope = "$($existing.Scope)"
        if ((Compare-AppVersion $ArtifactVersion $existing.Version) -eq 0) {
            Write-Host "  Up to date ($($existing.Version), $scope scope): $Publisher.$Name" -ForegroundColor Gray
            $script:PublishedApps[$key] = $true
            return
        }

        if ($scope -eq "Dev") {
            Write-Host "  Dev-scope version detected ($($existing.Version)), replacing with artifact v$ArtifactVersion..." -ForegroundColor Yellow
            Unpublish-AppFromContainer -Container $Container -Publisher $Publisher -Name $Name -Version $existing.Version
        }
        else {
            Write-Host "  Upgrading: $Publisher.$Name ($($existing.Version) -> $ArtifactVersion)" -ForegroundColor Cyan
            try {
                Publish-BcContainerApp -appFile $AppFilePath -containerName $Container -credential $Credential `
                    -skipVerification -sync -upgrade -useDevEndpoint
                Write-Host "  Upgraded: $Publisher.$Name v$ArtifactVersion" -ForegroundColor Green
                $script:PublishedApps[$key] = $true
                return
            }
            catch {
                Write-Host "  Upgrade failed ($($_.Exception.Message)), removing and reinstalling..." -ForegroundColor Yellow
                Unpublish-AppFromContainer -Container $Container -Publisher $Publisher -Name $Name -Version $existing.Version
            }
        }
    }

    Write-Host "  Publishing: $([System.IO.Path]::GetFileName($AppFilePath)) (v$ArtifactVersion)" -ForegroundColor Cyan
    try {
        Publish-BcContainerApp -appFile $AppFilePath -containerName $Container -credential $Credential `
            -install -skipVerification -sync -useDevEndpoint
        Write-Host "  Published: $Publisher.$Name v$ArtifactVersion" -ForegroundColor Green
        $script:PublishedApps[$key] = $true
    }
    catch {
        Write-Host "  Failed (will retry): $Publisher.${Name} -- $($_.Exception.Message)" -ForegroundColor DarkYellow
        $script:FailedPublishes.Add([PSCustomObject]@{
            AppFilePath     = $AppFilePath
            Publisher       = $Publisher
            Name            = $Name
            ArtifactVersion = $ArtifactVersion
            Container       = $Container
            Credential      = $Credential
            Error           = $_.Exception.Message
        })
    }
}

function Get-FailedPublishRecord([string]$Key) {
    return $script:FailedPublishes | Where-Object { "$($_.Publisher)|$($_.Name)".ToLower() -eq $Key } | Select-Object -First 1
}

# Publishes every resolved dependency. BcContainerHelper has no standalone
# "is this password valid?" check, so the first publish doubles as a credential
# probe: if it fails AND the error looks authentication-related AND the password
# came from the cache (not a fresh prompt), reset the cache, prompt once, and
# retry that one app before continuing. A first-app failure that DOESN'T look
# auth-related is left to the normal retry pass -- a working cached password is
# never disturbed just because some app failed to publish for another reason.
function Publish-DependenciesWithCredentialRecovery {
    param(
        [object[]]$Items,
        [string]$Container,
        [pscredential]$Credential,
        [bool]$CredentialFromCache
    )

    $items      = @($Items)
    $credential = $Credential
    $startIndex = 0

    if ($items.Count -gt 0 -and $CredentialFromCache) {
        $probe    = $items[0].package
        $probeKey = "$($probe.publisher)|$($probe.name)".ToLower()

        Publish-AppSmart -AppFilePath $probe.path -Publisher $probe.publisher -Name $probe.name `
            -ArtifactVersion $probe.version -Container $Container -Credential $credential

        if (-not $script:PublishedApps.ContainsKey($probeKey)) {
            $failed = Get-FailedPublishRecord $probeKey
            $err    = if ($failed) { "$($failed.Error)" } else { "" }

            if (Test-LooksLikeAuthFailure $err) {
                Write-Warning "First publish failed and the error looks credential-related -- the cached credential may be stale. Requesting fresh credentials and retrying once..."
                $script:FailedPublishes.RemoveAll([Predicate[object]]{ param($x) "$($x.Publisher)|$($x.Name)".ToLower() -eq $probeKey }) | Out-Null

                Clear-ContainerCredentialCache | Out-Null
                $credential = (Get-ContainerCredential).Credential

                Publish-AppSmart -AppFilePath $probe.path -Publisher $probe.publisher -Name $probe.name `
                    -ArtifactVersion $probe.version -Container $Container -Credential $credential
            }
            else {
                Write-Warning "First publish failed, but the error doesn't look credential-related ($err) -- keeping the cached credential; the normal retry pass will handle it."
            }
        }

        $startIndex = 1
    }

    for ($i = $startIndex; $i -lt $items.Count; $i++) {
        $pkg = $items[$i].package
        Publish-AppSmart -AppFilePath $pkg.path -Publisher $pkg.publisher -Name $pkg.name `
            -ArtifactVersion $pkg.version -Container $Container -Credential $credential
    }
}

# ===========================================================================
# Steps
# ===========================================================================

function Invoke-DownloadStep {
    param([string]$RunFolderRoot)

    az devops configure --defaults organization=$OrganizationUrl project=$Project | Out-Null
    Assert-LastExitCode "az devops configure"

    $pipelineJson = az pipelines show --name $PipelineName -o json
    Assert-LastExitCode "az pipelines show '$PipelineName'"
    $pipeline = $pipelineJson | ConvertFrom-Json
    if (-not $pipeline) { throw "Pipeline '$PipelineName' not found." }

    $runJson = az pipelines runs list --pipeline-ids $pipeline.id --result succeeded --status completed --top 1 -o json
    Assert-LastExitCode "az pipelines runs list"
    $run = $runJson | ConvertFrom-Json
    if (-not $run) { throw "No successful runs found for pipeline '$PipelineName'." }

    $runId     = $run[0].id
    $runFolder = Join-Path $RunFolderRoot "$RunFolderPrefix$runId"
    Write-Host "Latest successful run ID: $runId"
    Initialize-Directory $runFolder

    $artifactsJson = az pipelines runs artifact list --run-id $runId -o json
    Assert-LastExitCode "az pipelines runs artifact list (run $runId)"
    $artifacts = $artifactsJson | ConvertFrom-Json
    if (-not $artifacts) {
        Write-Host "Run $runId has no artifacts."
        return $runFolder
    }

    foreach ($artifact in $artifacts) {
        $artifactFolder = Join-Path $runFolder $artifact.name
        Initialize-Directory $artifactFolder
        Write-Host "Downloading artifact: $($artifact.name)"
        az pipelines runs artifact download --run-id $runId --artifact-name $artifact.name --path $artifactFolder -o none
        Assert-LastExitCode "az pipelines runs artifact download '$($artifact.name)' (run $runId)"
    }
    Write-Host "`nArtifacts downloaded to: $runFolder"
    return $runFolder
}

# ===========================================================================
# When dot-sourced (e.g. by the test script) load the functions but don't run
# the workflow. Direct execution and ScriptLauncher's `& $path` invocation both
# have an InvocationName other than '.', so only dot-sourcing is caught.
# ===========================================================================
if ($MyInvocation.InvocationName -eq '.') { return }

# ===========================================================================
# Apply user configuration + load credential helper.
# Done here -- after the dot-source guard -- so the zero-dependency unit test,
# which dot-sources this script, never touches config or the credential cache.
# AlRoot falls back to the param default; a parameter passed explicitly on the
# command line (or by the launcher) always wins over config.
# ===========================================================================
. (Join-Path $PSScriptRoot "Common\LauncherConfig.ps1")
. (Join-Path $PSScriptRoot "Common\ContainerCredential.ps1")

if (-not $PSBoundParameters.ContainsKey('AlRoot')) { $AlRoot = Get-LauncherConfigValue 'AlRoot' $AlRoot }

# ===========================================================================
# MAIN
# ===========================================================================

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  AL Dependencies: Download, Resolve and Publish"             -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Elevation is only needed to reach the container engine (Step 3). Check it up
# front so a non-elevated publish run fails immediately, not partway through
# after a long download. A -SkipPublish run touches no container and is exempt.
if (-not $SkipPublish -and -not (Test-IsElevated)) {
    throw "This script must run from an elevated (Administrator) PowerShell session to reach the local BC container engine. Re-run as Administrator, or pass -SkipPublish for a download/resolve-only run."
}

Write-Host "`nChecking prerequisites..." -ForegroundColor Gray

if (-not (Get-Command az -CommandType Application -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found in PATH. Install from: https://aka.ms/installazurecliwindows (then restart your terminal)."
}
Write-Host "  Azure CLI: $((Get-Command az).Source)" -ForegroundColor Gray

$extensionListJson = az extension list --output json
Assert-LastExitCode "az extension list"
$devopsExt = $extensionListJson | ConvertFrom-Json | Where-Object { $_.name -eq "azure-devops" }
if (-not $devopsExt) {
    throw "Azure DevOps extension not installed. Run: az extension add --name azure-devops"
}
Write-Host "  azure-devops extension: v$($devopsExt.version)" -ForegroundColor Gray

if (-not $SkipPublish) {
    if (-not (Get-Module -ListAvailable -Name BcContainerHelper)) {
        throw "BcContainerHelper module not installed. Run: Install-Module BcContainerHelper"
    }
    if (-not $ContainerName) {
        throw "Publishing requires a container: pass -ContainerName, or use -SkipPublish for a download/resolve-only run."
    }
    try {
        $null = Get-BcContainerAppInfo -containerName $ContainerName -ErrorAction Stop
    }
    catch {
        Write-Warning "Cannot reach container '$ContainerName'. Make sure it is running. ($($_.Exception.Message))"
    }
}
Write-Host "  Prerequisites OK" -ForegroundColor Gray

$ProjectRoot = Resolve-ProjectRoot -ProjectRoot $ProjectRoot -AlRoot $AlRoot
Write-Host "  Project: $ProjectRoot" -ForegroundColor Gray

# ---------------------------------------------------------------------------
# Step 1: Download artifacts
# ---------------------------------------------------------------------------

if (-not $SkipDownload) {
    Write-Host "`n[STEP 1/3] Downloading artifacts from Azure DevOps..." -ForegroundColor Yellow
    $runFolder = Invoke-DownloadStep -RunFolderRoot $DownloadsPath
}
else {
    Write-Host "`n[STEP 1/3] Skipping download (reusing existing artifacts)..." -ForegroundColor Gray

    $existingFolders = @(Get-ChildItem -Path $DownloadsPath -Directory -Filter "$RunFolderPrefix*")
    $latest          = Select-LatestRunFolder -Folders $existingFolders -Prefix $RunFolderPrefix
    if (-not $latest) {
        throw "No existing artifact folder matching '$RunFolderPrefix<number>' found. Remove -SkipDownload to fetch fresh artifacts."
    }
    $runFolder = $latest.FullName
    Write-Host "Using existing artifacts from: $runFolder"
}

# ---------------------------------------------------------------------------
# Step 2: Discover app.json files and resolve dependencies (transitive)
# ---------------------------------------------------------------------------

$step2Verb = if ($CopyToProject) { "resolving and copying" } else { "resolving" }
Write-Host "`n[STEP 2/3] Discovering app.json files and $step2Verb transitive dependencies..." -ForegroundColor Yellow

$projects = @(Find-ProjectFile -Root $ProjectRoot)

# The project's own apps (main app, test app, root app) are things you develop
# here, not dependencies to install. A test app depends on the app it tests, so
# without this the main app (e.g. Core) would be resolved from the CI artifacts
# and published over your local copy. Capture their identities from every
# discovered layout (before any -SkipTestApps trimming) so both the copy and
# publish steps can skip them.
$ownApps = @()
foreach ($proj in $projects) {
    $identity = Get-ALAppIdentity -Path $proj.AppJson
    if ($identity) { $ownApps += $identity }
}

# -SkipTestApps drops the project's 'app test' layout, so its test-only
# dependencies (test libraries/toolkits) are never resolved or published --
# the dependency-install analogue of building a dev container without the test
# toolkit. Off by default, so a normal run (and the Test menu entry) is
# unchanged. Only the non-test layouts (root, app) survive the filter.
if ($SkipTestApps) {
    $testLayouts = @($projects | Where-Object { $_.Label -eq 'app test' })
    if ($testLayouts.Count -gt 0) {
        Write-Host "Excluding $($testLayouts.Count) 'app test' layout(s) (-SkipTestApps): test dependencies will not be installed." -ForegroundColor Gray
    }
    $projects = @($projects | Where-Object { $_.Label -ne 'app test' })
}

if ($projects.Count -eq 0) {
    throw "No app.json found under '$ProjectRoot'. Expected locations: app.json, app\app.json, 'app test\app.json'."
}
Write-Host "Projects found:"
$projects | ForEach-Object { Write-Host "  [$($_.Label)] $($_.AppJson)" -ForegroundColor Gray }

Write-Host "`nIndexing .app packages in: $runFolder"
$packageIndex = New-AppPackageIndex $runFolder

$allOrdered = [System.Collections.Generic.List[object]]::new()
foreach ($proj in $projects) {
    Write-Host "`n--- [$($proj.Label)] ---" -ForegroundColor Cyan
    $ordered = Resolve-ProjectDependency `
        -AppJson       $proj.AppJson `
        -PackageIndex  $packageIndex `
        -TargetFolder  $proj.TargetFolder `
        -Label         $proj.Label `
        -OwnApps       $ownApps `
        -CopyToTarget:$CopyToProject
    foreach ($item in $ordered) { $allOrdered.Add($item) }
}

# $allOrdered may list an app more than once (a dep shared by the app and its
# test app). Publishing deduplicates by publisher|name (Publish-AppSmart skips
# anything already handled this run), so the container gets a single install each.
Write-Host "`nTotal: $($allOrdered.Count) dependency reference(s) across $($projects.Count) project(s) (deduplicated at publish time)."

# ---------------------------------------------------------------------------
# Step 3: Publish to BC container
# ---------------------------------------------------------------------------

if (-not $SkipPublish) {
    Write-Host "`n[STEP 3/3] Publishing dependencies to BC container..." -ForegroundColor Yellow

    $credResult = Get-ContainerCredential

    Write-Host "Container: $ContainerName" -ForegroundColor Gray
    Write-Host "Logic: up-to-date (any scope)->skip | non-Dev different version->upgrade | Dev-scope different version->unpublish+reinstall" -ForegroundColor Gray

    Write-Host "`nPublishing dependencies (all projects, dependency-first order)..." -ForegroundColor Cyan
    Publish-DependenciesWithCredentialRecovery `
        -Items               $allOrdered `
        -Container           $ContainerName `
        -Credential          $credResult.Credential `
        -CredentialFromCache $credResult.FromCache

    $maxRetries = 3
    for ($retryPass = 1; $retryPass -le $maxRetries -and $script:FailedPublishes.Count -gt 0; $retryPass++) {
        $stillFailed = [System.Collections.Generic.List[object]]::new()
        Write-Host "`nRetry pass $retryPass/$maxRetries for $($script:FailedPublishes.Count) failed app(s)..." -ForegroundColor Yellow

        foreach ($item in $script:FailedPublishes) {
            $key = "$($item.Publisher)|$($item.Name)".ToLower()
            if ($script:PublishedApps.ContainsKey($key)) { continue }

            Write-Host "  Retrying: $($item.Publisher).$($item.Name) v$($item.ArtifactVersion)" -ForegroundColor Cyan
            try {
                Publish-BcContainerApp -appFile $item.AppFilePath -containerName $item.Container -credential $item.Credential `
                    -install -skipVerification -sync -useDevEndpoint
                Write-Host "  Published: $($item.Publisher).$($item.Name)" -ForegroundColor Green
                $script:PublishedApps[$key] = $true
            }
            catch {
                Write-Host "  Failed again: $($item.Publisher).$($item.Name) -- $($_.Exception.Message)" -ForegroundColor DarkYellow
                $stillFailed.Add($item)
            }
        }
        $script:FailedPublishes = $stillFailed
    }

    if ($script:FailedPublishes.Count -gt 0) {
        Write-Host "`nCould not install $($script:FailedPublishes.Count) app(s) after $maxRetries attempts:" -ForegroundColor Red
        $script:FailedPublishes | ForEach-Object { Write-Host "  - $($_.Publisher).$($_.Name) v$($_.ArtifactVersion)" -ForegroundColor Red }
    }

    Write-Host "`nPublishing complete."
}
else {
    Write-Host "`n[STEP 3/3] Skipping publish to container." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "  All done!"                                                    -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  - Artifacts:     $(if ($SkipDownload) { $runFolder + ' (reused)' } else { $runFolder })"
Write-Host "  - Project root:  $ProjectRoot"
$projects | ForEach-Object { Write-Host "  - [$($_.Label)]: $($_.AppJson) -> $($_.TargetFolder)" }
Write-Host "  - Container:     $(if ($SkipPublish) { 'SKIPPED' } else { $ContainerName })"
Write-Host "  - Published:     $(if ($SkipPublish) { 'SKIPPED' } else { "$($script:PublishedApps.Count) app(s)" })"
Write-Host ""
