# ============================================================================
# ElvisLab - Descargas, verificacion, instaladores y winget
# ============================================================================

function Test-CancelRequested {
    if ([string]::IsNullOrWhiteSpace($script:CancelFile)) { return $false }
    return (Test-Path -LiteralPath $script:CancelFile)
}

function Invoke-HttpDownload {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$TimeoutSec = 600,
        [scriptblock]$OnPercent
    )

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue | Out-Null

    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    try {
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('ElvisLab/1.1') | Out-Null
    } catch { }

    try {
        $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw ("HTTP {0} {1}" -f [int]$response.StatusCode, $response.ReasonPhrase)
        }

        $total = $response.Content.Headers.ContentLength
        $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output = [System.IO.File]::Create($Destination)

        try {
            $buffer = New-Object byte[] 131072
            [long]$received = 0
            $started = [DateTime]::UtcNow
            while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if (([DateTime]::UtcNow - $started).TotalSeconds -gt $TimeoutSec) {
                    throw ("La descarga supero el tiempo limite de {0} segundos." -f $TimeoutSec)
                }
                if (Test-CancelRequested) {
                    throw (New-Object System.OperationCanceledException('Cancelado por el usuario'))
                }
                $output.Write($buffer, 0, $read)
                $received += $read
                if ($total -gt 0 -and $OnPercent) {
                    & $OnPercent ($received / [double]$total)
                }
            }
        } finally {
            $output.Dispose()
            $input.Dispose()
            $response.Dispose()
        }
    } catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        $client.Dispose()
    }
}

function Test-FileIntegrity {
    param($File, [string]$Path)

    $hasCheck = $false

    if ($File.sha256) {
        $hasCheck = $true
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($actual -ne $File.sha256) {
            throw "El SHA256 no coincide. Esperado: $($File.sha256). Obtenido: $actual"
        }
        Write-LogLine "SHA256 verificado: $($File.name)" 'OK'
    }

    if ($File.publisher) {
        $hasCheck = $true
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
        if ($signature.Status -ne 'Valid') {
            throw "La firma digital no es valida ($($signature.Status))."
        }
        $subject = ''
        if ($signature.SignerCertificate) { $subject = $signature.SignerCertificate.Subject }
        if ($subject.IndexOf($File.publisher, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "La firma pertenece a '$subject' y no al editor esperado '$($File.publisher)'."
        }
        Write-LogLine "Firma digital verificada: $($File.publisher)" 'OK'
    }

    if (-not $hasCheck) {
        if (-not $File.allowUnverified) {
            throw "No hay SHA256 ni editor configurado para verificar '$($File.name)'. Agrega uno o allowUnverified=true."
        }
        Write-LogLine "ADVERTENCIA: '$($File.name)' se instalara sin verificacion de integridad." 'WARN'
    }
}

function Invoke-Installer {
    param($File, [string]$Path)

    Write-LogLine ("Ejecutando instalador de {0}..." -f $File.name) 'INFO'

    $startParams = @{ FilePath = $Path; PassThru = $true }
    if ($File.installArgs) { $startParams['ArgumentList'] = $File.installArgs }

    $process = Start-Process @startParams
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $timeout = [Math]::Max(30, [int]$File.installTimeoutSec)

    while (-not $process.HasExited) {
        if ($watch.Elapsed.TotalSeconds -gt $timeout) {
            throw ("El instalador supero el tiempo limite de {0} segundos." -f $timeout)
        }
        Start-Sleep -Milliseconds 500
    }

    $process.Refresh()
    $code = $process.ExitCode
    Write-LogLine ("Instalador de {0} termino con codigo {1}." -f $File.name, $code) 'INFO'

    if (@($File.successExitCodes) -notcontains $code) {
        throw "El instalador termino con codigo $code."
    }
}

function Test-WingetAvailable {
    try {
        return [bool](Get-Command winget -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Remove-AnsiSequences {
    param([string]$Text)

    if (-not $Text) { return '' }
    $escaped = [regex]::Escape([string][char]27 + '[')
    return [regex]::Replace($Text, $escaped + '[0-9;?]*[a-zA-Z]', '')
}

function Invoke-WingetCommand {
    param(
        [string[]]$Arguments,
        [switch]$Quiet
    )

    if (-not (Test-WingetAvailable)) {
        throw 'winget no esta disponible en este equipo.'
    }

    Write-LogLine ("winget " + ($Arguments -join ' ')) 'INFO'

    $rawOutput = @(& winget @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    $output = Remove-AnsiSequences (($rawOutput | Out-String).Trim())

    if (-not $Quiet -and $output) {
        $lines = @($output -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -gt 40) {
            $lines = $lines[($lines.Count - 40)..($lines.Count - 1)]
        }
        foreach ($line in $lines) {
            Write-LogLine ('  ' + $line.TrimEnd()) 'INFO'
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Invoke-WingetInstallOrUpgrade {
    param($File)

    if (-not $File.wingetId) {
        throw "No hay wingetId configurado para '$($File.name)'."
    }

    $installed = Resolve-InstalledPath -File $File
    $verb = if ($installed) { 'upgrade' } else { 'install' }

    $wingetArgs = @(
        $verb,
        '--id', $File.wingetId,
        '--exact',
        '--silent',
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--disable-interactivity',
        '--source', 'winget'
    )

    $result = Invoke-WingetCommand -Arguments $wingetArgs

    if ($verb -eq 'upgrade' -and $result.ExitCode -eq -1978335212) {
        Write-LogLine "winget no reconoce '$($File.name)' como paquete instalado; se intenta instalar." 'WARN'
        $verb = 'install'
        $wingetArgs[0] = 'install'
        $result = Invoke-WingetCommand -Arguments $wingetArgs
    }

    if ($result.ExitCode -eq 0) {
        Write-LogLine "winget: $($File.name) completado." 'OK'
        return 'ok'
    }

    # Ya esta en la ultima version / ya esta instalado.
    if ($verb -eq 'upgrade' -and $result.ExitCode -eq -1978335189) {
        Write-LogLine "winget: $($File.name) ya esta en la ultima version." 'OK'
        return 'uptodate'
    }
    if ($result.ExitCode -eq -1978335135) {
        Write-LogLine "winget: $($File.name) ya estaba instalado." 'OK'
        return 'uptodate'
    }

    if (Resolve-InstalledPath -File $File) {
        Write-LogLine "winget termino con codigo $($result.ExitCode), pero '$($File.name)' esta instalado." 'WARN'
        return 'ok'
    }

    throw "winget termino con codigo $($result.ExitCode)."
}

function Invoke-WingetUpgradeFile {
    param($File)

    if (-not $File.wingetId) {
        throw "No hay wingetId configurado para '$($File.name)'."
    }

    $wingetArgs = @(
        'upgrade',
        '--id', $File.wingetId,
        '--exact',
        '--silent',
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--disable-interactivity',
        '--source', 'winget'
    )

    $result = Invoke-WingetCommand -Arguments $wingetArgs

    if ($result.ExitCode -eq 0) { return 'updated' }
    if ($result.ExitCode -eq -1978335189) { return 'uptodate' }
    if ($result.ExitCode -eq -1978335212) { return 'skipped' }

    throw "winget termino con codigo $($result.ExitCode)."
}

function Invoke-WingetUninstallFile {
    param($File)

    if (-not $File.wingetId) {
        throw "No hay wingetId configurado para '$($File.name)'."
    }

    $wingetArgs = @(
        'uninstall',
        '--id', $File.wingetId,
        '--exact',
        '--silent',
        '--accept-source-agreements',
        '--disable-interactivity',
        '--source', 'winget'
    )

    $result = Invoke-WingetCommand -Arguments $wingetArgs

    if ($result.ExitCode -eq 0) { return $true }
    if ($result.ExitCode -eq -1978335212) {
        Write-LogLine "winget no encontro '$($File.name)' instalado." 'WARN'
        return $false
    }

    throw "winget termino con codigo $($result.ExitCode)."
}
