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
        Lists top-level folders under $Root that pass Find-ProjectFile, so
        tooling/doc folders and worktree containers (which hold parallel
        checkouts rather than being a project themselves) never appear. Only the
        top-level folder is offered, never a checkout one level deeper.
    #>
    if (-not (Test-Path $Root)) {
        throw "AL root not found: $Root"
    }

    $candidates = @(
        Get-ChildItem -Path $Root -Directory |
            Where-Object { @(Find-ProjectFile -Root $_.FullName).Count -gt 0 } |
            Sort-Object Name
    )

    if ($candidates.Count -eq 0) {
        throw "No AL projects found under '$Root' (looked for app.json in <folder>, <folder>\app, <folder>\'app test')."
    }

    $picked = Select-FromList -Items $candidates -DisplaySelector { param($d) $d.Name } `
        -Title "Select an AL project under $Root (type to filter)"
    if ($null -eq $picked) {
        throw "Project selection cancelled."
    }
    return $picked.FullName
}
