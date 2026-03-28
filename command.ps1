#Requires -RunAsAdministrator

$dnsProviders = @(
    @{ Name = "DNS4EU";    Primary = "86.54.11.13";    Secondary = "86.54.11.213"   },
    @{ Name = "Cloudflare"; Primary = "1.1.1.1";        Secondary = "1.0.0.1"        },
    @{ Name = "ControlD";  Primary = "76.76.2.2";      Secondary = "76.76.10.2"     },
    @{ Name = "Quad9";     Primary = "9.9.9.9";         Secondary = "149.112.112.112"},
    @{ Name = "AdGuard";   Primary = "94.140.14.14";   Secondary = "94.140.15.15"   }
)

$testSites = @(
    "dr.dk",
    "ekstrabladet.dk",
    "zalando.dk",
    "vg.no",
    "svt.se"
)

$adapterName = "WiFi"
$pingCount   = 5

function Get-FilteredAverageMs {
    param(
        [Parameter(Mandatory)]
        [array]$SiteResults
    )

    $valid = $SiteResults | Where-Object { $_.AvgPing -lt 9999 }
    if (-not $valid) {
        return 9999
    }

    return [math]::Round(($valid | Measure-Object AvgPing -Average).Average, 1)
}

Write-Host "`nDNS Performance Tester" -ForegroundColor Cyan
Write-Host "Adapter: $adapterName  |  Pings per site: $pingCount`n" -ForegroundColor DarkGray

# ── Snapshot current DNS before changing anything ──────────────────────────
$currentDNS = (Get-DnsClientServerAddress -InterfaceAlias $adapterName `
    -AddressFamily IPv4).ServerAddresses

Write-Host "Current DNS: $($currentDNS -join ', ')" -ForegroundColor Magenta
Write-Host "Testing current DNS baseline...`n" -ForegroundColor Magenta

Clear-DnsClientCache
$baselineSites = @()
foreach ($site in $testSites) {
    $pings = Test-Connection -ComputerName $site -Count $pingCount -ErrorAction SilentlyContinue
    $avgPing = if ($pings) {
        [math]::Round(($pings | Measure-Object ResponseTime -Average).Average, 1)
    } else { 9999 }
    $baselineSites += [PSCustomObject]@{ Site = $site; AvgPing = $avgPing }
    Write-Host "  $site : ${avgPing}ms" -ForegroundColor DarkGray
}
$baselineAvg = Get-FilteredAverageMs -SiteResults $baselineSites
Write-Host "  → Baseline average: ${baselineAvg}ms`n" -ForegroundColor Magenta

$allResults = @()

# Add baseline as first entry so it shows in the final table
$allResults += [PSCustomObject]@{
    Provider    = "Current ($($currentDNS[0]))"
    PrimaryDNS  = $currentDNS[0]
    AvgAllSites = $baselineAvg
    SiteResults = $baselineSites
}

# ── Test each provider ──────────────────────────────────────────────────────
foreach ($provider in $dnsProviders) {
    Write-Host "Testing $($provider.Name) ($($provider.Primary))..." -ForegroundColor Yellow

    Set-DnsClientServerAddress -InterfaceAlias $adapterName `
        -ServerAddresses @($provider.Primary, $provider.Secondary) -ErrorAction Stop

    Clear-DnsClientCache
    Start-Sleep -Seconds 2

    $siteResults = @()
    foreach ($site in $testSites) {
        $pings = Test-Connection -ComputerName $site -Count $pingCount -ErrorAction SilentlyContinue
        $avgPing = if ($pings) {
            [math]::Round(($pings | Measure-Object ResponseTime -Average).Average, 1)
        } else { 9999 }
        $siteResults += [PSCustomObject]@{ Site = $site; AvgPing = $avgPing }
        Write-Host "  $site : ${avgPing}ms" -ForegroundColor DarkGray
    }

    $totalAvg = Get-FilteredAverageMs -SiteResults $siteResults
    $allResults += [PSCustomObject]@{
        Provider    = $provider.Name
        PrimaryDNS  = $provider.Primary
        AvgAllSites = $totalAvg
        SiteResults = $siteResults
    }
    Write-Host "  → Average: ${totalAvg}ms`n" -ForegroundColor White
}

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host "`n=== RESULTS ===" -ForegroundColor Cyan
$allResults | Sort-Object AvgAllSites | Format-Table Provider, PrimaryDNS, AvgAllSites -AutoSize

$best = $allResults | Sort-Object AvgAllSites | Select-Object -First 1
$bestSecondary = ($dnsProviders | Where-Object { $_.Name -eq $best.Provider }).Secondary

# Show if best is actually better than baseline
$diff = $baselineAvg - $best.AvgAllSites
if ($diff -gt 0) {
    Write-Host "BEST: $($best.Provider) — $($best.AvgAllSites)ms  ($diff ms faster than your current DNS)" -ForegroundColor Green
} else {
    Write-Host "BEST: Your current DNS is already optimal at ${baselineAvg}ms" -ForegroundColor Green
}

# ── Auto-apply ───────────────────────────────────────────────────────────────
if ($best.Provider -notlike "Current*") {
    $apply = Read-Host "`nApply $($best.Provider) as your DNS? (y/n)"
    if ($apply -eq 'y') {
        Set-DnsClientServerAddress -InterfaceAlias $adapterName `
            -ServerAddresses @($best.PrimaryDNS, $bestSecondary)
        Clear-DnsClientCache
        Write-Host "Applied. DNS is now $($best.Provider)." -ForegroundColor Green
    } else {
        # Restore original DNS if user declines
        Set-DnsClientServerAddress -InterfaceAlias $adapterName `
            -ServerAddresses $currentDNS
        Clear-DnsClientCache
        Write-Host "Restored your original DNS." -ForegroundColor Gray
    }
}

Write-Host "`nTo revert to auto DNS:" -ForegroundColor DarkGray
Write-Host "  Set-DnsClientServerAddress -InterfaceAlias '$adapterName' -ResetServerAddresses`n" -ForegroundColor Gray