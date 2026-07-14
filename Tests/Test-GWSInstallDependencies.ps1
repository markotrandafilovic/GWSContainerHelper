<#
.SYNOPSIS
    Zero-dependency unit tests for the pure logic in GWSInstallDependencies.ps1.

.DESCRIPTION
    The repo has no test framework by design, so this is a self-contained script
    with a tiny assert harness -- no Pester required. It dot-sources the main
    script (which returns before its workflow runs when dot-sourced) to get the
    functions, then exercises the three pieces of logic most prone to silent,
    hard-to-notice breakage:

      1. Select-HighestVersionPackage -- must return the newest version even when
         it isn't the last element (the exact bug the rewrite fixed).
      2. Select-LatestRunFolder       -- must sort run ids numerically, not as
         strings ("run-9" must NOT beat "run-100").
      3. Test-LooksLikeAuthFailure    -- auth errors true, ordinary publish
         errors false, so a stale-password re-prompt only fires for real.

    Run directly:  .\Tests\Test-GWSInstallDependencies.ps1
    Exits 0 if all pass, 1 if any fail (CI-friendly).
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Test harness intentionally prints results to the console')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-Pkg/New-Folder are in-memory test object factories, not state-changing cmdlets')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Load the functions without running the workflow (the script's dot-source guard
# returns before MAIN when InvocationName is '.'). ProjectRoot is a mandatory
# parameter, bound before the guard runs, so a throwaway value is supplied to
# satisfy binding -- the guard returns before it's ever used.
. (Join-Path $PSScriptRoot "..\Scripts\GWSInstallDependencies.ps1") -ProjectRoot 'unused'

$script:Passed = 0
$script:Failed = 0

function Assert-Equal($Expected, $Actual, [string]$Because) {
    if ("$Expected" -eq "$Actual") {
        $script:Passed++
        Write-Host "  [PASS] $Because" -ForegroundColor Green
    }
    else {
        $script:Failed++
        Write-Host "  [FAIL] $Because (expected '$Expected', got '$Actual')" -ForegroundColor Red
    }
}

function New-Pkg([string]$Version) { [PSCustomObject]@{ version = $Version } }
function New-Folder([string]$Name) { [PSCustomObject]@{ Name = $Name; FullName = "C:\Downloads\$Name" } }

Write-Host "`nCompare-AppVersion" -ForegroundColor Cyan
Assert-Equal  1 (Compare-AppVersion "2.0.0.0" "1.0.0.0")   "2.0.0.0 > 1.0.0.0"
Assert-Equal -1 (Compare-AppVersion "1.0.0.0" "2.0.0.0")   "1.0.0.0 < 2.0.0.0"
Assert-Equal  0 (Compare-AppVersion "1.2.3.4" "1.2.3.4")   "equal versions"
Assert-Equal  1 (Compare-AppVersion "1.0.10.0" "1.0.9.0")  "numeric per-part: 10 > 9 (string sort would fail)"
Assert-Equal  0 (Compare-AppVersion "1.0"      "1.0.0.0")  "short form padded: 1.0 == 1.0.0.0"

Write-Host "`nSelect-HighestVersionPackage (the critical fix)" -ForegroundColor Cyan
# Highest is in the MIDDLE, so 'last that differs' style bug would return 7.
Assert-Equal "9.0.0.0" (Select-HighestVersionPackage @((New-Pkg "5.0.0.0"), (New-Pkg "9.0.0.0"), (New-Pkg "7.0.0.0"))).version "picks 9 from [5,9,7], not the last element"
# Highest is FIRST.
Assert-Equal "9.0.0.0" (Select-HighestVersionPackage @((New-Pkg "9.0.0.0"), (New-Pkg "5.0.0.0"), (New-Pkg "7.0.0.0"))).version "picks 9 from [9,5,7]"
# Highest is LAST.
Assert-Equal "9.0.0.0" (Select-HighestVersionPackage @((New-Pkg "5.0.0.0"), (New-Pkg "7.0.0.0"), (New-Pkg "9.0.0.0"))).version "picks 9 from [5,7,9]"
# Real 4-part numeric ordering.
Assert-Equal "1.0.10.0" (Select-HighestVersionPackage @((New-Pkg "1.0.9.0"), (New-Pkg "1.0.10.0"), (New-Pkg "1.0.2.0"))).version "1.0.10.0 beats 1.0.9.0"
# Single element.
Assert-Equal "3.1.0.0" (Select-HighestVersionPackage @((New-Pkg "3.1.0.0"))).version "single-element list"
# Duplicates / ties don't misbehave.
Assert-Equal "4.0.0.0" (Select-HighestVersionPackage @((New-Pkg "4.0.0.0"), (New-Pkg "4.0.0.0"))).version "tie stays highest"

Write-Host "`nSelect-LatestRunFolder (numeric, not lexical)" -ForegroundColor Cyan
$prefix = "Release-Canary-run-"
Assert-Equal "Release-Canary-run-100"     (Select-LatestRunFolder -Folders @((New-Folder "Release-Canary-run-9"),   (New-Folder "Release-Canary-run-100"))  -Prefix $prefix).Name "run-100 beats run-9"
Assert-Equal "Release-Canary-run-1000000" (Select-LatestRunFolder -Folders @((New-Folder "Release-Canary-run-999999"),(New-Folder "Release-Canary-run-1000000")) -Prefix $prefix).Name "run-1000000 beats run-999999"
Assert-Equal "Release-Canary-run-42"      (Select-LatestRunFolder -Folders @((New-Folder "Release-Canary-run-42"))   -Prefix $prefix).Name "single folder"
# Non-numeric / non-matching folders are ignored.
Assert-Equal "Release-Canary-run-7" (Select-LatestRunFolder -Folders @((New-Folder "Release-Canary-run-7"), (New-Folder "Release-Canary-run-old"), (New-Folder "unrelated")) -Prefix $prefix).Name "ignores non-numeric suffixes"
$none = Select-LatestRunFolder -Folders @((New-Folder "unrelated"), (New-Folder "Release-Canary-run-")) -Prefix $prefix
Assert-Equal "" "$none" "returns nothing when no numeric run folder exists"

Write-Host "`nTest-LooksLikeAuthFailure" -ForegroundColor Cyan
Assert-Equal $true  (Test-LooksLikeAuthFailure "The remote server returned an error: (401) Unauthorized.") "401 Unauthorized -> auth"
Assert-Equal $true  (Test-LooksLikeAuthFailure "Access is denied.")                                        "access denied -> auth"
Assert-Equal $true  (Test-LooksLikeAuthFailure "Invalid credentials / bad password")                       "credential/password -> auth"
Assert-Equal $false (Test-LooksLikeAuthFailure "Dependency App X is not installed and cannot be resolved") "dependency error -> not auth"
Assert-Equal $false (Test-LooksLikeAuthFailure "The process cannot access the file because it is being used by another process") "file lock -> not auth"
Assert-Equal $false (Test-LooksLikeAuthFailure "")                                                          "empty message -> not auth"

Write-Host ""
Write-Host "============================================================"
Write-Host ("  Results: {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { "Green" } else { "Red" })
Write-Host "============================================================"

if ($script:Failed -gt 0) { exit 1 }
exit 0
