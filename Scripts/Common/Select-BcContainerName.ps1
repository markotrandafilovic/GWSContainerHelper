<#
    Shared helper, dot-sourced by UploadLicense.ps1, Remove-GWSApps.ps1, and
    GWSInstallDependencies.ps1: defines Select-BcContainerName, which lists
    BC containers on this machine (via Get-BcContainers) and lets you pick one
    (arrow-key list in a real console, numbered prompt otherwise), auto-selecting
    with no prompt if there's only one. Used whenever -ContainerName is left blank.
#>

if (-not (Get-Command Select-FromList -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Select-FromList.ps1')
}

function Select-BcContainerName {
    $containers = @(Get-BcContainers)

    if ($containers.Count -eq 0) {
        throw "No BC containers found on this machine. Create one first (see new-container.ps1)."
    }
    if ($containers.Count -eq 1) {
        return $containers[0]
    }

    $picked = Select-FromList -Items $containers -Title 'Select a BC container (type to filter)'
    if ($null -eq $picked) {
        throw "Container selection cancelled."
    }
    return $picked
}
