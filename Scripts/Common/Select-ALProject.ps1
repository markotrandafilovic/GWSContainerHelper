<#
    Shared helper, dot-sourced by GWSInstallDependencies.ps1 and by the
    ScriptLauncher module: defines Find-ProjectFile (discovers the app.json
    layouts of a single AL project) and Select-ALProject (lists the AL projects
    under a root and lets you pick one with live type-to-filter). Extracted here
    so the launcher's up-front project picker and the script's own -ProjectRoot
    resolution run the exact same logic.
#>

if (-not (Get-Command Select-FromList -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Select-FromList.ps1')
}

# Returns one descriptor per app.json found at the project root, in app\, and in
# 'app test\'. Wrapped in @() by callers before any .Count check -- a single
# match would otherwise unroll to a bare object under Set-StrictMode.
function Find-ProjectFile([string]$Root) {
    $found = [System.Collections.Generic.List[object]]::new()

    $layouts = @(
        @{ Label = "root";     AppJson = (Join-Path $Root "app.json");          Target = (Join-Path $Root ".alpackages") }
        @{ Label = "app";      AppJson = (Join-Path $Root "app\app.json");       Target = (Join-Path $Root "app\.alpackages") }
        @{ Label = "app test"; AppJson = (Join-Path $Root "app test\app.json");  Target = (Join-Path $Root "app test\.alpackages") }
    )

    foreach ($layout in $layouts) {
        if (Test-Path $layout.AppJson) {
            $found.Add([PSCustomObject]@{
                Label        = $layout.Label
                AppJson      = $layout.AppJson
                TargetFolder = $layout.Target
            })
        }
    }

    return @($found)
}

function Select-ALProject([string]$Root) {
    <#
        Lists AL projects under $Root and lets you pick one with type-to-filter.

        Discovery is a bounded two-level descent:
          - A top-level folder that is itself a project (passes Find-ProjectFile)
            is offered as-is and NOT descended into -- so a real project's
            worktree checkouts one level deeper stay hidden, and tooling/doc
            folders drop out.
          - A top-level folder that is NOT itself a project (a grouping container
            such as "MDE-Cloud") is opened one level deeper, and any of ITS
            children that are projects are offered, displayed as
            "<container>\<project>" so nested ones stay distinguishable.
        Because we only ever descend into folders that are NOT themselves
        projects, parallel checkouts under a real project are still never
        surfaced.
    #>
    if (-not (Test-Path $Root)) {
        throw "AL root not found: $Root"
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($top in @(Get-ChildItem -Path $Root -Directory)) {
        if (@(Find-ProjectFile -Root $top.FullName).Count -gt 0) {
            # Top-level folder is itself a project: offer it, don't descend.
            $candidates.Add([PSCustomObject]@{ Name = $top.Name; FullName = $top.FullName })
        }
        else {
            # Not a project: treat as a grouping container and look one level in.
            foreach ($child in @(Get-ChildItem -Path $top.FullName -Directory)) {
                if (@(Find-ProjectFile -Root $child.FullName).Count -gt 0) {
                    $candidates.Add([PSCustomObject]@{
                        Name     = "$($top.Name)\$($child.Name)"
                        FullName = $child.FullName
                    })
                }
            }
        }
    }

    $candidates = @($candidates | Sort-Object Name)

    if ($candidates.Count -eq 0) {
        throw "No AL projects found under '$Root' (looked for app.json in <folder>, <folder>\app, <folder>\'app test' -- and one level down inside grouping folders)."
    }

    $picked = Select-FromList -Items $candidates -DisplaySelector { param($d) $d.Name } `
        -Title "Select an AL project under $Root (type to filter)"
    if ($null -eq $picked) {
        throw "Project selection cancelled."
    }
    return $picked.FullName
}
