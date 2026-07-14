Set-StrictMode -Version Latest

<#
    Shared launcher/script configuration.

    Two files live in ScriptLauncher\Config:
      - Settings.template.json : committed to git, all keys present but empty.
      - Settings.json          : per-user, gitignored. Created by copying the
                                 template on first use. Edited via the launcher's
                                 "Settings" menu (Set-LauncherConfigValue).

    Resolution: a setting's effective value is its Settings.json value if that
    is present and non-empty; otherwise the caller's -Fallback (the script's own
    built-in default). So an empty settings file behaves exactly like the old
    hardcoded defaults -- everything works before anyone configures anything.

    Every script and the launcher dot-source this file, so config is honoured
    whether a script is run directly or through the launcher.
#>

# Config lives under ScriptLauncher\Config at the repo root. Common\ is nested
# under Scripts\, so climb two levels (..\..) to reach the repo root.
$script:LauncherConfigDir      = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\ScriptLauncher\Config'))
$script:LauncherConfigTemplate = Join-Path $script:LauncherConfigDir 'Settings.template.json'
$script:LauncherConfigUser     = Join-Path $script:LauncherConfigDir 'Settings.json'
$script:LauncherConfigCache    = $null

function Get-LauncherSettingSchema {
    <#
        The settings shown (in this order) in the launcher's Settings menu.
        Name matches the JSON key and, where applicable, the script parameter
        of the same name. Anything not listed here is not surfaced for editing.
    #>
    @(
        [PSCustomObject]@{ Name = 'AlRoot';      Description = 'Root folder containing your AL project repositories.' }
        [PSCustomObject]@{ Name = 'LicenseFile'; Description = 'Full path to your BC developer license (.bclicense).' }
    )
}

function Initialize-LauncherConfigFile {
    # Copy the committed template to the per-user Settings.json on first use.
    if (Test-Path $script:LauncherConfigUser) { return }
    if (-not (Test-Path $script:LauncherConfigTemplate)) { return }
    try {
        Copy-Item -LiteralPath $script:LauncherConfigTemplate -Destination $script:LauncherConfigUser -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not create settings file '$script:LauncherConfigUser': $($_.Exception.Message)"
    }
}

function Read-LauncherConfigRaw {
    # Loads Settings.json into a hashtable (empty if missing/unreadable/blank).
    $result = @{}
    if (-not (Test-Path $script:LauncherConfigUser)) { return $result }
    try {
        $raw = Get-Content -LiteralPath $script:LauncherConfigUser -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            foreach ($prop in $obj.PSObject.Properties) { $result[$prop.Name] = $prop.Value }
        }
    }
    catch {
        Write-Warning "Could not read settings '$script:LauncherConfigUser': $($_.Exception.Message). Using built-in defaults."
    }
    return $result
}

function Get-LauncherConfig {
    # Cached, template-initialised view of the user's settings.
    if ($null -ne $script:LauncherConfigCache) { return $script:LauncherConfigCache }
    Initialize-LauncherConfigFile
    $script:LauncherConfigCache = Read-LauncherConfigRaw
    return $script:LauncherConfigCache
}

function Get-LauncherConfigValue {
    <#
        Returns the configured value for $Name, or $Fallback when the setting
        is absent or empty. Fallback is the script's own hardcoded default, so
        an unconfigured setting preserves the original behaviour.
    #>
    param(
        [Parameter(Mandatory)][string] $Name,
        [string] $Fallback = ''
    )
    $cfg = Get-LauncherConfig
    if ($cfg.ContainsKey($Name)) {
        $value = $cfg[$Name]
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }
    return $Fallback
}

function Set-LauncherConfigValue {
    <#
        Writes $Name = $Value into the per-user Settings.json (never the
        template). Pass an empty $Value to reset a setting back to the script's
        built-in default. All known schema keys are written in a stable order
        for a tidy, diff-free file; any unknown keys already present are kept.
    #>
    param(
        [Parameter(Mandatory)][string] $Name,
        [string] $Value = ''
    )
    Initialize-LauncherConfigFile
    $cfg = Read-LauncherConfigRaw
    $cfg[$Name] = $Value

    $ordered = [ordered]@{}
    foreach ($setting in (Get-LauncherSettingSchema)) {
        $ordered[$setting.Name] = if ($cfg.ContainsKey($setting.Name)) { [string]$cfg[$setting.Name] } else { '' }
    }
    foreach ($key in $cfg.Keys) {
        if (-not $ordered.Contains($key)) { $ordered[$key] = $cfg[$key] }
    }

    try {
        ($ordered | ConvertTo-Json) | Set-Content -LiteralPath $script:LauncherConfigUser -Encoding UTF8 -ErrorAction Stop
        $script:LauncherConfigCache = $null
    }
    catch {
        Write-Warning "Could not save settings '$script:LauncherConfigUser': $($_.Exception.Message)"
    }
}
