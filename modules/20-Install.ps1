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

    $response = $null
    try {
        $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw ("HTTP {0} {1}" -f [int]$response.StatusCode, $response.ReasonPhrase)
        }

        $total = $response.Content.Headers.ContentLength
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()

        # Limita cada lectura para que una conexion estancada no bloquee la descarga.
        if ($stream.CanTimeout) {
            try {
                $stream.ReadTimeout = [int][Math]::Min(2147483647.0, ([double]$TimeoutSec * 1000))
            } catch { }
        }

        $output = [System.IO.File]::Create($Destination)

        try {
            $buffer = New-Object byte[] 131072
            [long]$received = 0
            $started = [DateTime]::UtcNow
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
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
        } catch [System.Management.Automation.MethodInvocationException] {
            $io = $_.Exception.InnerException
            $web = if ($io) { $io.InnerException } else { $null }
            if ($web -is [System.Net.WebException] -and $web.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
                throw ("La descarga supero el tiempo limite de {0} segundos." -f $TimeoutSec)
            }
            throw
        } finally {
            $output.Dispose()
            $stream.Dispose()
        }
    } catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if ($response) { $response.Dispose() }
        $client.Dispose()
    }
}

function Get-CertificatePublisherNames {
    param([string]$Subject)

    if (-not $Subject) { return @() }

    $names = @()
    foreach ($match in [regex]::Matches($Subject, '(?:^|,\s*)(?:CN|O)=("(?:\\.|[^"])*"|[^,]*)')) {
        $value = $match.Groups[1].Value.Trim()
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
            $value = $value.Replace('\"', '"').Replace('\,', ',')
        }
        if ($value) { $names += $value }
    }
    return $names
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

        $certificate = $signature.SignerCertificate
        if (-not $certificate) {
            throw 'La firma digital no incluye un certificado de firma.'
        }

        # Compara solo el nombre comun (CN) y la organizacion (O) del sujeto,
        # no cualquier campo (por ejemplo, la localidad).
        $subject = $certificate.Subject
        $names = Get-CertificatePublisherNames -Subject $subject

        $matched = $false
        foreach ($name in $names) {
            if ($name.Equals($File.publisher, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matched = $true
                break
            }
        }
        if (-not $matched) {
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
            # Detiene el instalador (y sus hijos) antes de informar del error.
            try { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null } catch { }
            if (-not $process.HasExited) {
                try { $process.Kill() } catch { }
            }
            try { [void]$process.WaitForExit(5000) } catch { }
            throw ("El instalador supero el tiempo limite de {0} segundos y se detuvo." -f $timeout)
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

    # OSC (titulo, hipervinculos), CSI (colores, cursores) y escapes de dos caracteres.
    $clean = [regex]::Replace($Text, '\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)', '')
    $clean = [regex]::Replace($clean, '\x1B\[[0-?]*[ -/]*[@-~]', '')
    $clean = [regex]::Replace($clean, '\x1B[@-_]', '')
    # Controles restantes: NUL, backspace, tabulador vertical, etc.
    $clean = [regex]::Replace($clean, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    # Normaliza CR y CRLF para que el registro tenga lineas reales.
    return [regex]::Replace($clean, '\r\n?', "`n")
}

function Get-WingetDiagnosticLine {
    param([string]$Output)

    if (-not $Output) { return '' }

    $lines = @($Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) { return '' }

    $pattern = 'not recognized|no installed package|no package|no applicable|no sources|failed|error|invalid|unable|hash|timed out|cancelled'
    foreach ($line in $lines) {
        if ($line -match $pattern) { return $line }
    }
    return $lines[0]
}

function Get-WingetFailureMessage {
    param($Result)

    if ($Result.Diagnostic) {
        return "winget termino con codigo $($Result.ExitCode): $($Result.Diagnostic)"
    }
    return "winget termino con codigo $($Result.ExitCode)."
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

    # Con ErrorActionPreference=Stop, el stderr de un ejecutable nativo puede
    # convertirse en un error terminante al redirigirlo con 2>&1.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rawOutput = @(& winget @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }

    $output = Remove-AnsiSequences (($rawOutput | Out-String).Trim())
    $diagnostic = Get-WingetDiagnosticLine -Output $output

    if (-not $Quiet -and $output) {
        $lines = @($output -split "`n" | Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -gt 40) {
            # Conserva el inicio (donde winget suele explicar el error) y el final.
            $lines = @($lines[0..4]) + @('...') + @($lines[($lines.Count - 35)..($lines.Count - 1)])
        }
        foreach ($line in $lines) {
            Write-LogLine ('  ' + $line.TrimEnd()) 'INFO'
        }
    }

    return [pscustomobject]@{
        ExitCode   = $exitCode
        Output     = $output
        Diagnostic = $diagnostic
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

    # PACKAGE_ALREADY_INSTALLED (0x8A150061) / INSTALL_ALREADY_INSTALLED (0x8A15010D).
    if (@(-1978335135, -1978334963) -contains $result.ExitCode) {
        Write-LogLine "winget: $($File.name) ya estaba instalado." 'OK'
        return 'uptodate'
    }

    # Un fallo real no se considera exito aunque la ruta configurada ya exista.
    throw (Get-WingetFailureMessage -Result $result)
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

    throw (Get-WingetFailureMessage -Result $result)
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

    throw (Get-WingetFailureMessage -Result $result)
}

function Get-WingetUpgradeCount {
    param([string]$Output)

    if (-not $Output) { return 0 }

    $match = [regex]::Match($Output, '(?im)^\s*(\d+)\s+upgrades?\s+available')
    if ($match.Success) { return [int]$match.Groups[1].Value }
    return 0
}

function Invoke-ElvisWingetUpgradeAll {
    param(
        [switch]$DryRun,
        [scriptblock]$OnProgress
    )

    if (-not (Test-WingetAvailable)) {
        throw 'winget no esta disponible en este equipo.'
    }

    if ($OnProgress) { & $OnProgress 5 'Buscando actualizaciones con winget...' | Out-Null }

    # Consulta de solo lectura: no instala nada.
    $listResult = Invoke-WingetCommand -Arguments @(
        'upgrade',
        '--include-unknown',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    $pending = Get-WingetUpgradeCount -Output $listResult.Output

    $summary = [pscustomobject]@{
        Pending  = $pending
        ExitCode = $listResult.ExitCode
        DryRun   = [bool]$DryRun
    }

    if ($DryRun) { return $summary }

    if ($pending -eq 0) {
        return $summary
    }

    if ($OnProgress) { & $OnProgress 25 'Actualizando aplicaciones con winget...' | Out-Null }

    $result = Invoke-WingetCommand -Arguments @(
        'upgrade',
        '--all',
        '--include-unknown',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    $summary.ExitCode = $result.ExitCode

    if ($result.ExitCode -eq 0) {
        Write-LogLine 'winget: actualizacion masiva completada.' 'OK'
        return $summary
    }

    # UPDATE_NOT_APPLICABLE / NO_APPLICATIONS_FOUND: no queda nada por actualizar.
    if (@(-1978335189, -1978335212) -contains $result.ExitCode) {
        Write-LogLine 'winget: no quedan actualizaciones aplicables.' 'OK'
        $summary.Pending = 0
        return $summary
    }

    throw (Get-WingetFailureMessage -Result $result)
}
