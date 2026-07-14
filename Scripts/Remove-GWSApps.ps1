<#
Pomocna skripta: uklanja sve GWS aplikacije iz BC containera (uninstall + unpublish).
Koristiti pre testiranja Download-Copy-Publish skripte radi cistog pocetnog stanja.

Pokretanje:
  .\Remove-GWSApps.ps1
  .\Remove-GWSApps.ps1 -ContainerName "MojContainer"
  .\Remove-GWSApps.ps1 -WhatIf   # prikaz sta bi bilo uklonjeno, bez akcije

Ako -ContainerName nije naveden, bira se iz liste postojecih containera
(Get-BcContainers) -- automatski, bez pitanja, ako postoji samo jedan.
#>

param(
    [Parameter(Mandatory)]
    [string]$ContainerName,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Publisher substring identifying the apps to remove -- always 'GWS'.
$PublisherFilter = 'GWS'   # sve aplikacije ciji publisher sadrzi ovaj string

Write-Host "════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Uklanjanje GWS aplikacija iz containera: $ContainerName" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Cyan

# Ucitaj sve app-ove sortirane po zavisnostima (DependenciesLast = dependenti pre dep-ova).
# Sortiramo SVE pre filtriranja kako bi redosled bio ispravan i kada GWS app zavisi od drugog GWS app-a.
$allApps = @(Get-BcContainerAppInfo -containerName $ContainerName -tenantSpecificProperties -sort DependenciesLast)

$gwsApps = @($allApps | Where-Object { $_.Publisher -like "*$PublisherFilter*" })

if ($gwsApps.Count -eq 0) {
    Write-Host "`nNema GWS aplikacija u containeru '$ContainerName'." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nPronadjeno $($gwsApps.Count) GWS aplikacija (redosled uklanjanja):"
$gwsApps | ForEach-Object {
    $status = if ($_.IsInstalled) { "installed" } else { "published" }
    Write-Host ("  - {0,-45} v{1,-15} [{2}] [{3}]" -f "$($_.Publisher).$($_.Name)", $_.Version, $_.Scope, $status)
}

if ($WhatIf) {
    Write-Host "`n[WhatIf] Nista nije uklonjeno." -ForegroundColor Gray
    exit 0
}

Write-Host ""

function Remove-OneApp {
    param($app)
    $label = "$($app.Publisher).$($app.Name) v$($app.Version)"

    # ForceSync - cisti podatke pre deinstalacije
    try {
        Sync-BcContainerApp -containerName $ContainerName `
            -appName $app.Name -publisher $app.Publisher -version $app.Version `
            -Mode ForceSync -ErrorAction SilentlyContinue
    }
    catch { }

    # UnInstall (-Force obradjuje eventualne zavisne app-ove koji i sami treba da se uklone)
    try {
        UnInstall-BcContainerApp -containerName $ContainerName `
            -appName $app.Name -publisher $app.Publisher -version $app.Version `
            -Force -ErrorAction Stop
        Write-Host "  UnInstall OK: $label" -ForegroundColor Gray
    }
    catch {
        Write-Host "  UnInstall GRESKA ($label): $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    # UnPublish
    try {
        UnPublish-BcContainerApp -containerName $ContainerName `
            -appName $app.Name -publisher $app.Publisher -version $app.Version `
            -ErrorAction Stop
        Write-Host "  UnPublish OK: $label" -ForegroundColor Gray
        return $true
    }
    catch {
        Write-Host "  UnPublish GRESKA ($label): $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $false
    }
}

# Prolazak 1: ukloni sve redom (dependenti su vec ispred dep-ova zbog DependenciesLast sorta)
$failed = [System.Collections.Generic.List[object]]::new()
foreach ($app in $gwsApps) {
    Write-Host "Uklanjam: $($app.Publisher).$($app.Name) v$($app.Version) [$($app.Scope)]" -ForegroundColor Yellow
    $ok = Remove-OneApp $app
    if (-not $ok) { $failed.Add($app) }
}

# Prolazak 2+: ponovi za one koji nisu uspeli (ponekad dependency red nije savrsen)
$maxPasses = 3
$pass = 2
while ($failed.Count -gt 0 -and $pass -le $maxPasses) {
    Write-Host "`nProlazak $pass - ponavljam za $($failed.Count) neuspela(ih)..." -ForegroundColor Yellow
    $stillFailed = [System.Collections.Generic.List[object]]::new()
    foreach ($app in $failed) {
        Write-Host "Ponavljam: $($app.Publisher).$($app.Name) v$($app.Version)" -ForegroundColor Yellow
        $ok = Remove-OneApp $app
        if (-not $ok) { $stillFailed.Add($app) }
    }
    $failed = $stillFailed
    $pass++
}

if ($failed.Count -gt 0) {
    Write-Host "`nNije moguce ukloniti $($failed.Count) aplikacija(e):" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $($_.Publisher).$($_.Name) v$($_.Version)" -ForegroundColor Red }
}
else {
    Write-Host "`nGotovo. Container je spreman za testiranje." -ForegroundColor Green
}
