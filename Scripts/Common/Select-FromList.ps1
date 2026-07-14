<#
    Shared helper: Select-FromList is a dependency-free, console-native single
    item picker. In a real interactive console it draws an in-place list with a
    highlighted row -- Up/Down (and PageUp/PageDown/Home/End) move the
    highlight, typing filters the list live (fzf-style), Enter selects, Esc
    cancels. When the console can't do raw key reads (input redirected, a host
    without a real screen buffer, CI, the unit tests), it transparently falls
    back to a plain numbered prompt, so callers never have to care which mode
    they're in. Returns the selected item, or $null if cancelled.

    Dot-sourced by Select-BcContainerName.ps1 / Select-ALProject.ps1 (guarded)
    and by the ScriptLauncher module.
#>

function Select-FromListNumbered {
    param(
        [object[]] $Items,
        [scriptblock] $DisplaySelector = { param($item) "$item" },
        [string] $Title = 'Select an item'
    )

    Write-Host ""
    if ($Title) { Write-Host $Title }
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), (& $DisplaySelector $Items[$i]))
    }
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Number (or Q to cancel)"
        if ($choice -match '^\s*[Qq]\s*$') { return $null }
        if ($choice -match '^\s*\d+\s*$') {
            $n = [int]$choice.Trim()
            if ($n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1] }
        }
        Write-Host "  Enter a number between 1 and $($Items.Count), or Q to cancel." -ForegroundColor Yellow
    }
}

function Select-FromList {
    [CmdletBinding()]
    param(
        [object[]] $Items,
        [scriptblock] $DisplaySelector = { param($item) "$item" },
        [string] $Title = 'Select an item',
        [switch] $NoFilter,
        [int] $PageSize = 12
    )

    $Items = @($Items)
    if ($Items.Count -eq 0) { return $null }
    if ($Items.Count -eq 1) { return $Items[0] }

    # Only drive the raw-key UI when we truly have an interactive screen buffer.
    # Redirected input (tests/CI) or a host without a console (WindowHeight
    # throws "handle is invalid") -> numbered prompt instead.
    $interactive = $false
    try {
        if (-not [Console]::IsInputRedirected) {
            $null = [Console]::WindowHeight
            $null = [Console]::CursorTop
            $interactive = $true
        }
    }
    catch { $interactive = $false }

    if (-not $interactive) {
        return Select-FromListNumbered -Items $Items -DisplaySelector $DisplaySelector -Title $Title
    }

    $labels = @(for ($i = 0; $i -lt $Items.Count; $i++) { [string](& $DisplaySelector $Items[$i]) })

    $chrome   = 3                                   # title + filter line + footer
    $viewport = [Math]::Min($PageSize, $Items.Count)
    $viewport = [Math]::Min($viewport, [Math]::Max(1, [Console]::WindowHeight - $chrome - 1))
    $blockH   = $chrome + $viewport

    # Reserve the block up front so the in-place redraws below never scroll the
    # buffer (a scroll would leave the anchored top-of-block Y stale). Printing
    # blank lines forces any needed scroll to happen now; then anchor.
    for ($i = 0; $i -lt $blockH; $i++) { [Console]::WriteLine() }
    $startY = [Console]::CursorTop - $blockH
    if ($startY -lt 0) { $startY = 0 }

    $filter   = ''
    $selected = 0
    $offset   = 0

    $prevCursorVisible = $true
    try { $prevCursorVisible = [Console]::CursorVisible } catch { }
    try { [Console]::CursorVisible = $false } catch { }

    function Write-Row([int]$RowY, [string]$Text, [bool]$Highlight) {
        [Console]::SetCursorPosition(0, $RowY)
        $w = [Math]::Max(1, [Console]::WindowWidth - 1)
        if ($Text.Length -gt $w) { $Text = $Text.Substring(0, $w) }
        $Text = $Text.PadRight($w)
        if ($Highlight) { Write-Host $Text -ForegroundColor Black -BackgroundColor Cyan -NoNewline }
        else            { Write-Host $Text -NoNewline }
    }

    $renderError = $false
    try {
        while ($true) {
            if ($NoFilter -or $filter -eq '') {
                $matchIdx = @(0..($Items.Count - 1))
            }
            else {
                $needle   = $filter.ToLower()
                $matchIdx = @(0..($Items.Count - 1) | Where-Object { $labels[$_].ToLower().Contains($needle) })
            }

            if ($matchIdx.Count -eq 0) { $selected = 0 }
            elseif ($selected -ge $matchIdx.Count) { $selected = $matchIdx.Count - 1 }
            elseif ($selected -lt 0) { $selected = 0 }

            if ($selected -lt $offset) { $offset = $selected }
            elseif ($selected -ge $offset + $viewport) { $offset = $selected - $viewport + 1 }
            if ($offset -lt 0) { $offset = 0 }

            $y = $startY
            Write-Row $y (" " + $Title) $false; $y++
            $filterLine = if ($NoFilter) { " Use Up/Down, Enter to select, Esc to cancel" } else { " Filter: $filter" + [char]0x2588 }
            Write-Row $y $filterLine $false; $y++

            for ($r = 0; $r -lt $viewport; $r++) {
                $pos = $offset + $r
                if ($pos -lt $matchIdx.Count) {
                    $isSel  = ($pos -eq $selected)
                    $marker = if ($isSel) { ' > ' } else { '   ' }
                    $more   = ''
                    if ($r -eq 0 -and $offset -gt 0) { $more = '  (more above)' }
                    elseif ($r -eq $viewport - 1 -and ($offset + $viewport) -lt $matchIdx.Count) { $more = '  (more below)' }
                    Write-Row $y ($marker + $labels[$matchIdx[$pos]] + $more) $isSel
                }
                else {
                    Write-Row $y '' $false
                }
                $y++
            }

            $footer = if ($matchIdx.Count -eq 0) { ' (no matches)   Backspace to edit filter - Esc to cancel' }
                      else { " $($selected + 1)/$($matchIdx.Count)   Up/Down move - Enter select - Esc cancel" + $(if (-not $NoFilter) { ' - type to filter' } else { '' }) }
            Write-Row $y $footer $false

            $key = [Console]::ReadKey($true)
            switch ($key.Key.ToString()) {
                'UpArrow'    { if ($matchIdx.Count) { $selected--; if ($selected -lt 0) { $selected = $matchIdx.Count - 1 } } }
                'DownArrow'  { if ($matchIdx.Count) { $selected = ($selected + 1) % $matchIdx.Count } }
                'PageUp'     { $selected = [Math]::Max(0, $selected - $viewport) }
                'PageDown'   { if ($matchIdx.Count) { $selected = [Math]::Min($matchIdx.Count - 1, $selected + $viewport) } }
                'Home'       { $selected = 0 }
                'End'        { if ($matchIdx.Count) { $selected = $matchIdx.Count - 1 } }
                'Enter'      { if ($matchIdx.Count) { return $Items[$matchIdx[$selected]] } }
                'Escape'     { return $null }
                'Backspace'  { if (-not $NoFilter -and $filter.Length -gt 0) { $filter = $filter.Substring(0, $filter.Length - 1); $selected = 0; $offset = 0 } }
                default {
                    $ch = $key.KeyChar
                    if ($NoFilter) {
                        if ($ch -eq 'q' -or $ch -eq 'Q') { return $null }
                    }
                    elseif ($ch -ne [char]0 -and -not [char]::IsControl($ch)) {
                        $filter += $ch; $selected = 0; $offset = 0
                    }
                }
            }
        }
    }
    catch {
        # Any console/render failure (e.g. the window was resized out from under
        # us). Cleanup happens in finally; fall back to the numbered prompt below
        # rather than crash the caller. A normal Enter/Esc selection returns from
        # inside the try, so this only runs on a genuine render error.
        $renderError = $true
    }
    finally {
        try { [Console]::CursorVisible = $prevCursorVisible } catch { }
        try { [Console]::SetCursorPosition(0, [Math]::Min($startY + $blockH, [Console]::BufferHeight - 1)) } catch { }
        Write-Host ""
    }

    if ($renderError) {
        return Select-FromListNumbered -Items $Items -DisplaySelector $DisplaySelector -Title $Title
    }
    return $null
}
