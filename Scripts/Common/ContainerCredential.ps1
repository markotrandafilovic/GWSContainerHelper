Set-StrictMode -Version Latest

<#
    Shared BC container credential handling.

    A single PSCredential (username + password) is cached, DPAPI-encrypted, at
    %LOCALAPPDATA%\GWSInstallDependencies\bc-container-credential.xml -- tied to
    the current Windows user + machine, useless if copied elsewhere.
    Export-Clixml on a PSCredential encrypts the SecureString password via DPAPI
    automatically (the username is stored in the clear, which is fine).

    Model:
      - new-container.ps1 always prompts fresh (New-ContainerCredential) because
        it *defines* the credentials for a container it is creating, and writes
        them to the cache so consumers can authenticate afterwards.
      - GWSInstallDependencies.ps1 consumes the cache (Get-ContainerCredential):
        cached if present, otherwise prompt once and cache. If a publish then
        fails and the error looks authentication-related, it clears the cache
        (Clear-ContainerCredentialCache) and prompts again -- self-healing, which
        is why there is no -ResetContainerPassword switch anymore.
      - UploadLicense.ps1 / Remove-GWSApps.ps1 never authenticate, so they don't
        use this at all.

    The prompt is in-terminal (username echoed, password hidden) rather than the
    GUI Get-Credential dialog, so it never leaves the console and can't hang on a
    windowed prompt in an odd host. It throws (rather than hangs) if there's no
    interactive console to prompt from.
#>

$script:ContainerCredentialCachePath = Join-Path $env:LOCALAPPDATA "GWSInstallDependencies\bc-container-credential.xml"

function Get-ContainerCredentialCachePath {
    return $script:ContainerCredentialCachePath
}

function Clear-ContainerCredentialCache {
    # Returns $true if a cache file existed and was removed, else $false.
    if (Test-Path $script:ContainerCredentialCachePath) {
        Remove-Item -Path $script:ContainerCredentialCachePath -Force
        return $true
    }
    return $false
}

function Read-CachedContainerCredential {
    if (-not (Test-Path $script:ContainerCredentialCachePath)) { return $null }
    try {
        return Import-Clixml -Path $script:ContainerCredentialCachePath
    }
    catch {
        Write-Warning "Could not read cached container credential ($($_.Exception.Message)) -- you will be prompted again."
        return $null
    }
}

function Save-ContainerCredential {
    param([Parameter(Mandatory)][pscredential]$Credential)
    $dir = Split-Path $script:ContainerCredentialCachePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Credential | Export-Clixml -Path $script:ContainerCredentialCachePath
}

function Read-ContainerCredentialInteractive {
    <#
        Prompts in-terminal for a username (echoed, defaults to $DefaultUserName
        on blank) and a password (hidden), returning a PSCredential. Throws if
        there is no interactive console rather than hanging.
    #>
    param([string]$DefaultUserName = 'admin')

    if ([Console]::IsInputRedirected) {
        throw "BC container credentials are required but no interactive console is available to prompt for them. Run this from an interactive PowerShell session."
    }

    $userPrompt = if ($DefaultUserName) { "BC container username (Enter for '$DefaultUserName')" } else { "BC container username" }
    $user = Read-Host $userPrompt
    if ([string]::IsNullOrWhiteSpace($user)) { $user = $DefaultUserName }

    $secure = Read-Host "BC container password" -AsSecureString
    return [pscredential]::new($user, $secure)
}

function New-ContainerCredential {
    # Always prompt fresh and (re)write the cache. For container *creation*.
    param([string]$DefaultUserName = 'admin')
    $cred = Read-ContainerCredentialInteractive -DefaultUserName $DefaultUserName
    Save-ContainerCredential -Credential $cred
    return $cred
}

function Get-ContainerCredential {
    <#
        For *consumers*: return the cached credential if present, otherwise
        prompt once and cache it. Returns a PSCustomObject with:
          .Credential (pscredential)
          .FromCache  (bool) -- so the caller can decide whether a subsequent
                        auth failure means "stale cache, re-prompt" vs "fresh
                        credential, this isn't a credential problem".
    #>
    param([string]$DefaultUserName = 'admin')

    $cached = Read-CachedContainerCredential
    if ($cached) { return [PSCustomObject]@{ Credential = $cached; FromCache = $true } }

    $cred = Read-ContainerCredentialInteractive -DefaultUserName $DefaultUserName
    Save-ContainerCredential -Credential $cred
    return [PSCustomObject]@{ Credential = $cred; FromCache = $false }
}
