# ============================================================================
# ElvisLab - DNS, planes de energia y limpieza de temporales
# ============================================================================

function Clear-ElvisTempFiles {
    $targets = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp'))
    $removed = 0
    $failed = 0

    foreach ($target in $targets) {
        if (-not $target -or -not (Test-Path -LiteralPath $target)) { continue }
        $items = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)
        foreach ($item in $items) {
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $removed++
            } catch {
                $failed++
            }
        }
    }

    Write-LogLine ("Temporales: {0} elemento(s) eliminados, {1} en uso/omitidos." -f $removed, $failed) 'OK'
    return [pscustomobject]@{
        Removed = $removed
        Failed  = $failed
    }
}

function Get-ElvisDnsServers {
    param([string]$Provider)

    switch ($Provider) {
        'google' { return @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844') }
        'cloudflare' { return @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001') }
        'cloudflare-malware' { return @('1.1.1.2', '1.0.0.2', '2606:4700:4700::1112', '2606:4700:4700::1002') }
        'quad9' { return @('9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9') }
        'adguard' { return @('94.140.14.14', '94.140.15.15', '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff') }
        'dhcp' { return @() }
        default { return @() }
    }
}

function Set-ElvisDns {
    param([string]$Provider)

    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch '(?i)Npcap|Loopback|Virtual|Hyper-V|VMware|VPN|TAP|WireGuard|OpenVPN|Tailscale|ZeroTier'
    })

    if ($adapters.Count -eq 0) {
        throw 'No se encontraron adaptadores fisicos activos.'
    }

    $servers = @(Get-ElvisDnsServers -Provider $Provider)
    $applied = 0

    foreach ($adapter in $adapters) {
        if ($servers.Count -eq 0) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
            Write-LogLine ("DNS restablecido a DHCP en '{0}'." -f $adapter.Name) 'OK'
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $servers -ErrorAction Stop
            Write-LogLine ("DNS '{0}' aplicado en '{1}'." -f $Provider, $adapter.Name) 'OK'
        }
        $applied++
    }

    try { $null = (& ipconfig.exe /flushdns 2>&1 | Out-String) } catch { }
    return $applied
}

function Get-PowerPlans {
    $output = (& powercfg.exe /list 2>&1 | Out-String)
    $plans = @()

    foreach ($line in ($output -split "`r?`n")) {
        $match = [regex]::Match($line, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\((.*?)\)')
        if ($match.Success) {
            $plans += [pscustomobject]@{
                Guid = $match.Groups[1].Value.ToLowerInvariant()
                Name = $match.Groups[2].Value.Trim()
            }
        }
    }

    return $plans
}

function Get-UltimatePlanStatePath {
    $dir = Join-Path $env:LOCALAPPDATA 'ElvisLab'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return (Join-Path $dir 'ultimate-plan.txt')
}

function Test-UltimatePlanName {
    param([string]$Name)
    return ($Name -match '(?i)ultimate performance|rendimiento m[aá]ximo|m[aá]ximo rendimiento')
}

function Enable-UltimatePerformance {
    $template = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $statePath = Get-UltimatePlanStatePath
    $plans = @(Get-PowerPlans)
    $plan = $null

    if (Test-Path -LiteralPath $statePath) {
        $savedGuid = (Get-Content -LiteralPath $statePath -Raw).Trim()
        if ($savedGuid -match '^[0-9a-fA-F-]{36}$') {
            $plan = @($plans | Where-Object { $_.Guid -eq $savedGuid.ToLowerInvariant() }) | Select-Object -First 1
        }
    }

    if (-not $plan) {
        $plan = @($plans | Where-Object { Test-UltimatePlanName -Name $_.Name }) | Select-Object -First 1
    }

    if (-not $plan) {
        $beforeGuids = @($plans | ForEach-Object { $_.Guid })
        $output = (& powercfg.exe -duplicatescheme $template 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw ("powercfg -duplicatescheme fallo (codigo {0}): {1}" -f $LASTEXITCODE, $output.Trim())
        }

        $plans = @(Get-PowerPlans)
        $plan = @($plans | Where-Object { $_.Guid -notin $beforeGuids }) | Select-Object -First 1

        if (-not $plan) {
            $guids = @([regex]::Matches($output, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value.ToLowerInvariant() })
            if ($guids.Count -gt 0) {
                $plan = [pscustomobject]@{ Guid = $guids[$guids.Count - 1]; Name = 'Ultimate Performance' }
            }
        }

        if (-not $plan) {
            $plan = @($plans | Where-Object { Test-UltimatePlanName -Name $_.Name }) | Select-Object -First 1
        }
    }

    if (-not $plan) {
        throw 'No se pudo identificar el plan Ultimate Performance.'
    }

    $null = (& powercfg.exe -setactive $plan.Guid 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw ("powercfg -setactive fallo (codigo {0})." -f $LASTEXITCODE)
    }

    Set-Content -LiteralPath $statePath -Value $plan.Guid -Encoding ASCII
    Write-LogLine ("Plan Ultimate Performance activado ({0})." -f $plan.Guid) 'OK'
    return $plan.Guid
}

function Disable-UltimatePerformance {
    $statePath = Get-UltimatePlanStatePath
    $plans = @(Get-PowerPlans)
    $targetGuids = @()

    if (Test-Path -LiteralPath $statePath) {
        $savedGuid = (Get-Content -LiteralPath $statePath -Raw).Trim()
        if ($savedGuid -match '^[0-9a-fA-F-]{36}$') {
            $known = @($plans | Where-Object { $_.Guid -eq $savedGuid.ToLowerInvariant() })
            if ($known.Count -gt 0) { $targetGuids += $savedGuid.ToLowerInvariant() }
        }
    }
    foreach ($plan in @($plans | Where-Object { Test-UltimatePlanName -Name $_.Name })) {
        $targetGuids += $plan.Guid
    }
    $targetGuids = @($targetGuids | Select-Object -Unique)

    if ($targetGuids.Count -eq 0) {
        Write-LogLine 'No hay planes Ultimate Performance que quitar.' 'WARN'
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        return 0
    }

    $balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $null = (& powercfg.exe -setactive $balanced 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw ("No se pudo activar el plan Equilibrado (codigo {0})." -f $LASTEXITCODE)
    }

    $deleted = 0
    foreach ($guid in $targetGuids) {
        $null = (& powercfg.exe -delete $guid 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) {
            $deleted++
            Write-LogLine ("Plan eliminado: {0}." -f $guid) 'OK'
        } else {
            Write-LogLine ("No se pudo eliminar el plan {0} (codigo {1})." -f $guid, $LASTEXITCODE) 'WARN'
        }
    }

    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    Write-LogLine ("Planes Ultimate Performance eliminados: {0}." -f $deleted) 'OK'
    return $deleted
}
