Set-StrictMode -Version Latest

$script:ModuleRoot = $PSScriptRoot
$script:ConfigPath = Join-Path $ModuleRoot 'Config\Tasks.psd1'

# Shared list-pickers, reused so the launcher can resolve Container / AL-project
# parameters from a list up front (the same helpers the scripts use), instead of
# a raw text prompt. Loaded best-effort: if they're missing, picker parameters
# just fall back to the target script's own prompt.
$script:CommonRoot = Join-Path $script:ModuleRoot '..\Scripts\Common'
foreach ($helper in @('Select-FromList.ps1', 'Select-BcContainerName.ps1', 'Select-ALProject.ps1', 'LauncherConfig.ps1', 'ContainerCredential.ps1')) {
    $helperPath = Join-Path $script:CommonRoot $helper
    if (Test-Path $helperPath) { . $helperPath }
    else { Write-Warning "Launcher picker helper not found: $helperPath (list pickers will fall back to script prompts)." }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedScriptLauncher {
    <#
        Windows can't elevate an already-running process in place, so this
        spawns a new elevated console running the launcher (same pattern as
        the old Launch-ALDeps.ps1) using whichever PowerShell executable is
        already running this session (works for both powershell.exe and
        pwsh.exe). The original, non-elevated session is left alone -- it's
        just returned from, never force-closed, since it may be a general
        interactive console the caller is using for other things too.
    #>
    $exePath = (Get-Process -Id $PID).Path
    $entryPath = Join-Path $script:ModuleRoot '..\Launch.ps1'

    # Route through the shared entry script (no -NoExit) so the elevated window
    # closes when you quit the menu, matching the pinned shortcut's behaviour.
    Start-Process -FilePath $exePath -Verb RunAs -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $entryPath
    )
}

function ConvertTo-MenuNode {
    <#
        Turns one raw Tasks.psd1 entry (a hashtable) into a menu node. An entry
        is either:
          - a GROUP (has a 'Submenu' array) -> a node whose Children are the
            recursively-converted sub-entries. Selecting it opens a submenu.
          - a LEAF task (has a 'Script') -> a runnable node with its resolved
            script path and the optional Parameters / PromptParameters / Pickers
            described below.

        Leaf tasks can optionally carry:
          - Parameters (hashtable): silent preset values. Never prompted for.
          - PromptParameters (string[]): curates which *optional* parameters get
            prompted; an empty array prompts nothing, an absent key prompts all.
          - Pickers (hashtable): paramName -> 'Container' | 'ALProject', resolved
            from an interactive list up front.

        Every node carries IsGroup + Children so callers can treat the tree
        uniformly under Set-StrictMode.
    #>
    param([Parameter(Mandatory)][hashtable] $Raw)

    if ($Raw.ContainsKey('Submenu')) {
        $children = @($Raw['Submenu'] | ForEach-Object { ConvertTo-MenuNode -Raw $_ })
        return [PSCustomObject]@{
            Name             = $Raw['Name']
            IsGroup          = $true
            Exists           = $true
            Children         = $children
            Script           = ''
            Parameters       = @{}
            PromptParameters = $null
            Pickers          = @{}
        }
    }

    $scriptPath = $Raw['Script']
    if (-not [System.IO.Path]::IsPathRooted($scriptPath)) {
        $scriptPath = Join-Path $script:ModuleRoot $scriptPath
    }
    $scriptPath = [System.IO.Path]::GetFullPath($scriptPath)

    $presetParameters = if ($Raw.ContainsKey('Parameters')) { $Raw['Parameters'] } else { @{} }
    $pickers          = if ($Raw.ContainsKey('Pickers')) { $Raw['Pickers'] } else { @{} }

    # Assign directly, NOT via `$x = if (...) { $Raw['PromptParameters'] }`. An
    # empty array returned as an if-expression value collapses to $null -- which
    # downstream reads as "prompt everything", so a `PromptParameters = @()`
    # entry would wrongly prompt every optional parameter.
    $promptParameters = $null
    if ($Raw.ContainsKey('PromptParameters')) {
        $promptParameters = [string[]]$Raw['PromptParameters']
    }

    return [PSCustomObject]@{
        Name             = $Raw['Name']
        IsGroup          = $false
        Exists           = Test-Path -LiteralPath $scriptPath
        Children         = @()
        Script           = $scriptPath
        Parameters       = $presetParameters
        PromptParameters = $promptParameters
        Pickers          = $pickers
    }
}

function Get-ScriptTask {
    <#
        Loads Config\Tasks.psd1 into a tree of menu nodes (see ConvertTo-MenuNode).
        Script paths are resolved against the module root here because relative
        paths in the .psd1 can't reference $PSScriptRoot themselves --
        Import-PowerShellDataFile only allows literal data.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:ConfigPath)) {
        throw "Task config not found: $script:ConfigPath"
    }

    $data = Import-PowerShellDataFile -Path $script:ConfigPath
    foreach ($task in $data.Tasks) {
        ConvertTo-MenuNode -Raw $task
    }
}

function Get-MenuLeaf {
    # Flattens a node tree to just its runnable leaf tasks (depth-first).
    param([object[]] $Nodes)
    foreach ($node in $Nodes) {
        if ($node.IsGroup) { Get-MenuLeaf -Nodes $node.Children }
        else { $node }
    }
}

function Select-ScriptTask {
    <#
        Arrow-key / type-to-filter navigator over a node list via the shared
        Select-FromList helper. Selecting a group descends into its Children
        (Esc there backs up one level); selecting a leaf returns it. Returns the
        chosen leaf node, or $null if the user backed out of the top level.
        Groups are marked with a trailing '>' and missing scripts with [MISSING].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $Nodes,
        [string] $Title = 'ScriptLauncher -- choose a task (type to filter, Esc to quit)'
    )

    while ($true) {
        Clear-LauncherScreen
        $selected = Select-FromList -Items $Nodes -Title $Title -DisplaySelector {
            param($t)
            if ($t.IsGroup)      { "$($t.Name)  >" }
            elseif ($t.Exists)   { $t.Name }
            else                 { "$($t.Name)  [MISSING]" }
        }

        if (-not $selected) { return $null }

        if ($selected.IsGroup) {
            $leaf = Select-ScriptTask -Nodes $selected.Children -Title "$($selected.Name) (type to filter, Esc to go back)"
            if ($leaf) { return $leaf }
            continue   # backed out of the submenu -- redraw this level
        }

        return $selected
    }
}

function Test-ScriptParameterMandatory {
    <#
        A parameter is mandatory if it carries an explicit
        [Parameter(Mandatory=$true)] / [Parameter(Mandatory)] attribute, or if
        it has no default value and isn't a [switch] (an un-defaulted switch
        just means "off").
    #>
    param([Parameter(Mandatory)] $ParameterAst)

    $paramAttr = $ParameterAst.Attributes |
        Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'Parameter' } |
        Select-Object -First 1

    if ($paramAttr) {
        $mandatoryArg = $paramAttr.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' } | Select-Object -First 1
        if ($mandatoryArg) {
            if ($mandatoryArg.ExpressionOmitted) { return $true }
            try { return [bool]$mandatoryArg.Argument.SafeGetValue() } catch { return $true }
        }
    }

    $isSwitch = $ParameterAst.StaticType -eq [System.Management.Automation.SwitchParameter]
    return (-not $ParameterAst.DefaultValue) -and (-not $isSwitch)
}

function Get-ScriptParameterDefault {
    <#
        Pulls the default value out of the AST so it can be shown in the
        prompt instead of a vague "use script default" message.

        First tries SafeGetValue(), which only succeeds for a true constant.
        Every non-literal default in this repo's scripts is built from
        $PSScriptRoot (e.g. `(Join-Path $PSScriptRoot "DEV.bclicense")`), so
        as a fallback, the default expression's own source text is
        re-evaluated in an isolated scriptblock with $PSScriptRoot manually
        set to the target script's folder first. If that still fails (or the
        expression depends on something else entirely), $null is returned
        and the caller falls back to the generic message -- the parameter is
        simply omitted from the splat if left blank either way, so the
        script's own default always applies regardless of whether this
        preview could resolve it.
    #>
    param(
        [Parameter(Mandatory)] $ParameterAst,
        [Parameter(Mandatory)][string] $ScriptPath
    )

    if (-not $ParameterAst.DefaultValue) { return $null }

    try { return $ParameterAst.DefaultValue.SafeGetValue() } catch { }

    try {
        $scriptRoot = Split-Path -Parent $ScriptPath
        $exprText = $ParameterAst.DefaultValue.Extent.Text
        $wrapped = "`$PSScriptRoot = '$($scriptRoot.Replace("'", "''"))'; $exprText"
        return [scriptblock]::Create($wrapped).Invoke() | Select-Object -First 1
    }
    catch {
        return $null
    }
}

function Invoke-ParameterPicker {
    <#
        Resolves a parameter value from an interactive list instead of a raw
        text prompt, reusing the same helpers the scripts use:
          - 'Container' -> Select-BcContainerName (lists BC containers on this
                           machine; auto-picks when there's only one)
          - 'ALProject' -> Select-ALProject (asks for a filter substring, then
                           shows a numbered list) rooted at $Root
        Returns the selected value, or $null if the picker can't run (no
        containers, BcContainerHelper unavailable, unknown type, ...) so the
        caller falls back to leaving the parameter unbound and letting the
        script's own logic resolve it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PickerType,
        [Parameter(Mandatory)][string] $ParameterName,
        [string] $Root
    )

    try {
        switch ($PickerType) {
            'Container' {
                if (-not (Get-Command Select-BcContainerName -ErrorAction SilentlyContinue)) {
                    throw "Select-BcContainerName helper not loaded."
                }
                if (-not (Get-Command Get-BcContainers -ErrorAction SilentlyContinue)) {
                    if (Get-Module -ListAvailable -Name BcContainerHelper) {
                        Import-Module BcContainerHelper -ErrorAction Stop
                    }
                }
                Write-Host "Select a container for -$($ParameterName):" -ForegroundColor Cyan
                return Select-BcContainerName
            }
            'ALProject' {
                if (-not (Get-Command Select-ALProject -ErrorAction SilentlyContinue)) {
                    throw "Select-ALProject helper not loaded."
                }
                Write-Host "Select a project for -$($ParameterName):" -ForegroundColor Cyan
                return Select-ALProject -Root $Root
            }
            default {
                Write-Warning "Unknown picker type '$PickerType' for -$ParameterName -- falling back to the script's own prompt."
                return $null
            }
        }
    }
    catch {
        Write-Warning "Picker for -$ParameterName could not run ($($_.Exception.Message)); the script's own logic will resolve it."
        return $null
    }
}

function Read-ScriptParameter {
    <#
        Introspects the target script's own param() block via AST parsing
        (not Get-Command) so that implicit CmdletBinding common parameters
        (WhatIf, Confirm, Verbose, ...) never show up as prompts -- only what
        the script actually declares does.

        PresetParameters (from the task's Config\Tasks.psd1 entry) fully and
        silently supplies any parameter name it contains -- no prompt, no
        echo. Mandatory parameters are always dynamically prompted regardless
        of either list below, since the script can't run without them.

        PromptParameters curates which *optional* parameters get prompted:
          - $null (the task didn't specify it) -- prompt for every optional
            parameter, same as if this curation didn't exist at all.
          - a string[] (even empty) -- prompt ONLY for the optional
            parameters named in it; every other optional parameter is
            silently skipped (not prompted, not echoed, not added to the
            splat), so the script's own default/internal logic applies
            exactly as if run directly with no override.
        This is how "New Development Container" and "New Test Container" can
        share new-container.ps1, each pin IncludeTestToolkit via
        PresetParameters, and still only ask about ContainerName/Country --
        never mentioning IncludeTestToolkit at all.

        Pickers (paramName -> 'Container'|'ALProject') resolves those
        parameters from an interactive list up front (see Invoke-ParameterPicker)
        rather than a text prompt. It takes precedence over PromptParameters and
        the switch/text prompts. If the picker can't run or the user backs out,
        the parameter is left unbound so the script's own logic resolves it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ScriptPath,
        [hashtable] $PresetParameters = @{},
        [string[]] $PromptParameters = $null,
        [hashtable] $Pickers = @{}
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors) {
        throw "Failed to parse '$ScriptPath': $($parseErrors[0].Message)"
    }

    $boundParams = @{}
    $paramBlock = $ast.ParamBlock
    if (-not $paramBlock) { return $boundParams }

    # A preset or curated prompt name that doesn't match any declared
    # parameter is silently a no-op below (both are only consulted while
    # iterating the script's real parameters), so a typo in Tasks.psd1 --
    # e.g. IncludeTestTookit -- would quietly build the wrong thing with no
    # error. Surface those up front instead.
    $declaredNames = @($paramBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $scriptLeaf = Split-Path -Leaf $ScriptPath
    foreach ($presetName in $PresetParameters.Keys) {
        if ($declaredNames -notcontains $presetName) {
            Write-Warning "Preset parameter '$presetName' is not declared by $scriptLeaf -- ignored (check Tasks.psd1)."
        }
    }
    if ($null -ne $PromptParameters) {
        foreach ($promptName in $PromptParameters) {
            if ($declaredNames -notcontains $promptName) {
                Write-Warning "PromptParameters entry '$promptName' is not declared by $scriptLeaf -- ignored (check Tasks.psd1)."
            }
        }
    }
    foreach ($pickerName in $Pickers.Keys) {
        if ($declaredNames -notcontains $pickerName) {
            Write-Warning "Pickers entry '$pickerName' is not declared by $scriptLeaf -- ignored (check Tasks.psd1)."
        }
    }

    foreach ($p in $paramBlock.Parameters) {
        $name     = $p.Name.VariablePath.UserPath
        $isSwitch = $p.StaticType -eq [System.Management.Automation.SwitchParameter]

        if ($PresetParameters.ContainsKey($name)) {
            $boundParams[$name] = $PresetParameters[$name]
            continue
        }

        if ($Pickers.ContainsKey($name)) {
            # Root for the AL-project picker: an AlRoot already collected this
            # run (Customize prompts it, and AlRoot precedes ProjectRoot in the
            # param block), else AlRoot's own default -- so the quick Dev/Test
            # entries never have to ask for the projects root.
            $root = $null
            if ($Pickers[$name] -eq 'ALProject') {
                if ($boundParams.ContainsKey('AlRoot')) {
                    $root = [string]$boundParams['AlRoot']
                }
                else {
                    # AlRoot wasn't prompted this run (e.g. the quick Dev/Test
                    # entries). Prefer the AlRoot *setting* if configured, else the
                    # script's own default -- matching how the script itself
                    # resolves AlRoot, so the picker lists projects from the same
                    # root the run will use (the script's hardcoded default alone
                    # would ignore a teammate's configured path).
                    $alRootAst = $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AlRoot' } | Select-Object -First 1
                    $astDefault = if ($alRootAst) { [string](Get-ScriptParameterDefault -ParameterAst $alRootAst -ScriptPath $ScriptPath) } else { '' }
                    if (Get-Command Get-LauncherConfigValue -ErrorAction SilentlyContinue) {
                        $root = Get-LauncherConfigValue 'AlRoot' $astDefault
                    }
                    else {
                        $root = $astDefault
                    }
                }
            }
            $picked = Invoke-ParameterPicker -PickerType ([string]$Pickers[$name]) -ParameterName $name -Root $root
            if ($null -ne $picked -and -not [string]::IsNullOrWhiteSpace([string]$picked)) {
                $boundParams[$name] = $picked
                continue
            }
            # The picker produced nothing (backed out, no containers, helper not
            # loaded...). If the parameter is optional, leave it unbound so the
            # script's own default applies. If it's mandatory, DON'T continue --
            # fall through to the required-prompt below so the script can still
            # run (the scripts no longer have their own interactive fallback).
            if (-not (Test-ScriptParameterMandatory -ParameterAst $p)) { continue }
        }

        if (Test-ScriptParameterMandatory -ParameterAst $p) {
            do {
                $value = Read-Host "$name (required)"
            } while ([string]::IsNullOrWhiteSpace($value))
            $boundParams[$name] = $value
            continue
        }

        if ($null -ne $PromptParameters -and $PromptParameters -notcontains $name) {
            continue
        }

        if ($isSwitch) {
            do {
                $answer = Read-Host "$name (y/n, default: n)"
            } while ($answer -notmatch '^[YyNn]?$')
            if ($answer -match '^[Yy]$') { $boundParams[$name] = $true }
            continue
        }

        # A configured setting of the same name (Settings.json) is the effective
        # default the script itself will resolve, so show that in the prompt
        # rather than the script's hardcoded param default. Falls through to the
        # AST default when there's no matching / non-empty setting.
        $configDefault = ''
        if (Get-Command Get-LauncherConfigValue -ErrorAction SilentlyContinue) {
            $configDefault = Get-LauncherConfigValue $name ''
        }
        $default = if (-not [string]::IsNullOrEmpty($configDefault)) {
            $configDefault
        }
        else {
            Get-ScriptParameterDefault -ParameterAst $p -ScriptPath $ScriptPath
        }
        $prompt = if ($null -ne $default -and $default -ne '') {
            "$name (default: $default)"
        }
        else {
            "$name (optional, Enter to use script default)"
        }

        $value = Read-Host $prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $boundParams[$name] = $value
        }
    }

    return $boundParams
}

function Invoke-ScriptTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][hashtable] $BoundParameters
    )

    try {
        & $ScriptPath @BoundParameters
    }
    catch {
        Write-Host ""
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ScriptStackTrace) {
            Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
        }
    }
}

function Format-TaskInvocation {
    <#
        Renders a readable preview of the command a menu pick resolves to,
        so the user sees exactly what is about to run before committing --
        crucially INCLUDING silent preset parameters (e.g. IncludeTestToolkit),
        which are otherwise the only difference between the "New Development
        Container" and "New Test Container" entries and never appear on screen.
        Switch/bool values render as a bare -Name when true and are omitted
        when false (matching how you'd type the command); any password-like
        value is masked rather than printed.
    #>
    param(
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][hashtable] $BoundParameters
    )

    $leaf = Split-Path -Leaf $ScriptPath
    $parts = foreach ($key in ($BoundParameters.Keys | Sort-Object)) {
        $value = $BoundParameters[$key]
        if ($value -is [bool] -or $value -is [System.Management.Automation.SwitchParameter]) {
            if ($value) { "-$key" }
            continue
        }
        $rendered = if ($key -match 'password') { '***' } else { [string]$value }
        if ($rendered -match '\s') { "-$key `"$rendered`"" } else { "-$key $rendered" }
    }

    return (@(".\$leaf") + @($parts)) -join ' '
}

function Clear-LauncherScreen {
    <#
        Clears the console so each menu "screen" replaces the previous one
        instead of scrolling it off below. Only fires on a real interactive
        console: if input is redirected or there's no screen buffer (CI, the
        unit tests, a piped host), it no-ops -- clearing there is pointless and
        would blow away scrollback. Mirrors Select-FromList's own interactivity
        check so the two agree on when we're driving a live terminal.
    #>
    try {
        if ([Console]::IsInputRedirected) { return }
        $null = [Console]::WindowHeight
    }
    catch { return }
    Clear-Host
}

function Invoke-ClearCredentialCache {
    <#
        Deletes the shared, DPAPI-encrypted BC container credential cache so the
        next script that needs credentials prompts fresh. Safe to run anytime.
    #>
    [CmdletBinding()]
    param()

    Clear-LauncherScreen
    Write-Host "=== Clear Credential Cache ===" -ForegroundColor Cyan

    if (-not (Get-Command Clear-ContainerCredentialCache -ErrorAction SilentlyContinue)) {
        Write-Warning "Credential helper not loaded (Common\ContainerCredential.ps1) -- nothing to do."
        return
    }

    if (Clear-ContainerCredentialCache) {
        Write-Host "Cleared. You'll be prompted for the container username/password on the next run." -ForegroundColor Green
    }
    else {
        Write-Host "No cached credential found -- nothing to clear." -ForegroundColor Yellow
    }
}

function Show-SettingsMenu {
    <#
        Arrow-key / type-to-filter editor for the shared settings in
        Settings.json (see Common\LauncherConfig.ps1). Same Select-FromList UX
        as the main menu: Up/Down highlight, type to filter, Enter to edit the
        highlighted setting, Esc to return to the main menu. Editing a setting
        prompts for a new value (blank keeps the current one, '-' resets it to
        the script's built-in default) and writes it to the per-user file.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command Get-LauncherSettingSchema -ErrorAction SilentlyContinue)) {
        Write-Warning "Settings are unavailable -- Common\LauncherConfig.ps1 did not load."
        return
    }

    # Carried across iterations so a save/reset confirmation survives the
    # screen clear and shows above the freshly redrawn list.
    $status = ''
    while ($true) {
        Clear-LauncherScreen
        if ($status) {
            Write-Host $status -ForegroundColor Green
            Write-Host ""
            $status = ''
        }

        $schema = @(Get-LauncherSettingSchema)

        $selected = Select-FromList -Items $schema -Title 'Settings (Enter to edit, Esc to go back)' -DisplaySelector {
            param($s)
            $value = Get-LauncherConfigValue $s.Name ''
            $shown = if ([string]::IsNullOrEmpty($value)) { '(built-in default)' } else { $value }
            '{0,-20} {1}' -f $s.Name, $shown
        }

        if (-not $selected) { return }

        $current = Get-LauncherConfigValue $selected.Name ''
        $shown = if ([string]::IsNullOrEmpty($current)) { '(built-in default)' } else { $current }

        Write-Host ""
        Write-Host "=== $($selected.Name) ===" -ForegroundColor Cyan
        Write-Host $selected.Description -ForegroundColor Gray
        Write-Host "Current: $shown" -ForegroundColor Gray
        $new = Read-Host "New value (Enter to keep, '-' to reset to built-in default)"

        if ($new -eq '') { continue }
        if ($new -eq '-') {
            Set-LauncherConfigValue -Name $selected.Name -Value ''
            $status = "Reset $($selected.Name) to its built-in default."
        }
        else {
            Set-LauncherConfigValue -Name $selected.Name -Value $new
            $status = "Saved $($selected.Name) = $new"
        }
    }
}

function Start-ScriptLauncher {
    <#
    .SYNOPSIS
        Shows a menu of configured scripts (see Config\Tasks.psd1) and runs
        the one you pick, prompting for its parameters based on its own
        param() block. Aliased as 'launch'.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-IsAdministrator)) {
        Write-Host ""
        Write-Host "ScriptLauncher needs an elevated session -- every configured script talks to Docker/BC containers." -ForegroundColor Yellow
        Write-Host "Relaunching as Administrator (accept the UAC prompt)..." -ForegroundColor Yellow
        try {
            Start-ElevatedScriptLauncher
            Write-Host "Continue in the new elevated window. This one is safe to keep using or close." -ForegroundColor Yellow
        }
        catch {
            Write-Host "Could not relaunch elevated: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Open PowerShell as Administrator yourself, then run 'launch' again." -ForegroundColor Red
        }
        return
    }

    while ($true) {
        $tasks = @(Get-ScriptTask)

        if ($tasks.Count -eq 0) {
            Write-Warning "No tasks configured in $script:ConfigPath"
            return
        }

        # Synthetic menu entries (not Tasks.psd1 scripts). Shaped like a leaf
        # node (IsGroup/Children included) so the tree navigator lists them;
        # matched back by reference so they never collide with a real task.
        # Appended after the configured tasks, with Settings intentionally last.
        $settingsItem = [PSCustomObject]@{
            Name = 'Settings...'; IsGroup = $false; Script = ''; Exists = $true
            Children = @(); Parameters = @{}; PromptParameters = $null; Pickers = @{}
        }
        $clearCredItem = [PSCustomObject]@{
            Name = 'Clear Credential Cache'; IsGroup = $false; Script = ''; Exists = $true
            Children = @(); Parameters = @{}; PromptParameters = $null; Pickers = @{}
        }

        $selected = Select-ScriptTask -Nodes (@($tasks) + $clearCredItem + $settingsItem)
        if (-not $selected) {
            Write-Host "Goodbye."
            return
        }

        if ($selected -eq $settingsItem) {
            Show-SettingsMenu
            continue
        }

        if ($selected -eq $clearCredItem) {
            Invoke-ClearCredentialCache
            Write-Host ""
            [void](Read-Host "Press Enter to return to the menu")
            continue
        }

        if (-not $selected.Exists) {
            Write-Host "Cannot run '$($selected.Name)' -- script not found at $($selected.Script)" -ForegroundColor Red
            continue
        }

        Clear-LauncherScreen
        Write-Host "=== $($selected.Name) ===" -ForegroundColor Cyan

        $boundParams = Read-ScriptParameter -ScriptPath $selected.Script -PresetParameters $selected.Parameters -PromptParameters $selected.PromptParameters -Pickers $selected.Pickers

        Write-Host ""
        Write-Host "Running: $(Format-TaskInvocation -ScriptPath $selected.Script -BoundParameters $boundParams)" -ForegroundColor DarkGray
        $confirm = Read-Host "Press Enter to run, or C to cancel"
        if ($confirm -match '^\s*[Cc]') {
            Write-Host "Cancelled -- back to the menu." -ForegroundColor Yellow
            continue
        }

        Invoke-ScriptTask -ScriptPath $selected.Script -BoundParameters $boundParams

        Write-Host ""
        [void](Read-Host "Press Enter to return to the menu")
    }
}

Set-Alias -Name launch -Value Start-ScriptLauncher

Export-ModuleMember -Function Start-ScriptLauncher -Alias launch
