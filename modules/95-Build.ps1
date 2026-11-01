# ============================================================================
# ElvisLab - Empaquetado con ps2exe
# ============================================================================

function Invoke-BuildExe {
    param($Config)

    $command = Get-Command ps2exe -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue }
    if (-not $command) {
        Write-LogLine 'ps2exe no esta instalado. Ejecuta: Install-Module ps2exe -Scope CurrentUser -Force' 'ERROR'
        return 1
    }

    $entryPath = $script:EntryScriptPath
    if (-not $entryPath -or -not (Test-Path -LiteralPath $entryPath)) {
        Write-LogLine 'No se puede compilar: no se conoce la ruta de ElvisLab.ps1.' 'ERROR'
        return 1
    }

    $moduleDir = Join-Path $script:ScriptDir 'modules'
    $manifestPath = Join-Path $moduleDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Write-LogLine "No se encontro el manifiesto de modulos: $manifestPath" 'ERROR'
        return 1
    }

    try {
        $moduleData = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $moduleFiles = @($moduleData)
    } catch {
        Write-LogLine "No se pudo leer el manifiesto de modulos: $($_.Exception.Message)" 'ERROR'
        return 1
    }

    $builder = New-Object System.Text.StringBuilder
    foreach ($moduleFile in $moduleFiles) {
        $modulePath = Join-Path $moduleDir $moduleFile
        if (-not (Test-Path -LiteralPath $modulePath)) {
            Write-LogLine "No se encontro el modulo: $modulePath" 'ERROR'
            return 1
        }
        [void]$builder.AppendLine('# ----------------------------------------------------------------------------')
        [void]$builder.AppendLine("# Modulo: $moduleFile")
        [void]$builder.AppendLine('# ----------------------------------------------------------------------------')
        [void]$builder.AppendLine((Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8))
    }

    $launcher = Get-Content -LiteralPath $entryPath -Raw -Encoding UTF8
    $startMarker = '# >>> ELVISLAB MODULES'
    $endMarker = '# <<< ELVISLAB MODULES'
    $start = $launcher.IndexOf($startMarker)
    $end = $launcher.IndexOf($endMarker)
    if ($start -lt 0 -or $end -lt 0 -or $end -le $start) {
        Write-LogLine 'No se encontraron los marcadores de modulos en ElvisLab.ps1.' 'ERROR'
        return 1
    }
    $end += $endMarker.Length

    $bundle = $launcher.Substring(0, $start) + $builder.ToString() + $launcher.Substring($end)

    $buildDir = Join-Path $env:TEMP 'ElvisLab\build'
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
    $bundlePath = Join-Path $buildDir 'ElvisLab.bundle.ps1'
    [System.IO.File]::WriteAllText($bundlePath, $bundle, $script:Utf8NoBom)

    $outputPath = Join-Path $script:ScriptDir 'ElvisLab.exe'
    $parameters = @{
        inputFile  = $bundlePath
        outputFile = $outputPath
        noConsole  = $true
        requireAdmin = $true
        STA        = $true
        x64        = $true
        title      = $Config.appName
        description = 'Instalador de programas y ajustes para Windows'
        product    = $Config.appName
        version    = '1.5.0.0'
    }

    $iconPath = Join-Path $script:ScriptDir 'Resources\ElvisLab.ico'
    if (Test-Path -LiteralPath $iconPath) { $parameters['iconFile'] = $iconPath }

    $accepted = @{}
    foreach ($key in $parameters.Keys) {
        if ($command.Parameters.ContainsKey($key)) { $accepted[$key] = $parameters[$key] }
    }

    Write-LogLine ("Compilando {0} con ps2exe (bundle de {1} modulos)..." -f $outputPath, $moduleFiles.Count) 'INFO'
    try {
        & $command @accepted
        if (-not (Test-Path -LiteralPath $outputPath)) {
            Write-LogLine 'ps2exe termino pero no genero el .exe.' 'ERROR'
            return 1
        }
        $info = Get-Item -LiteralPath $outputPath
        Write-LogLine ("OK: {0} generado ({1:N0} bytes)." -f $outputPath, $info.Length) 'OK'
        Write-LogLine 'Nota: el .exe no esta firmado digitalmente.' 'WARN'
        return 0
    } catch {
        Write-LogLine "ERROR al compilar: $($_.Exception.Message)" 'ERROR'
        return 1
    } finally {
        Remove-Item -LiteralPath $bundlePath -Force -ErrorAction SilentlyContinue
    }
}
