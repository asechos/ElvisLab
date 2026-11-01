# ============================================================================
# ElvisLab - Modo desatendido y progreso de trabajos
# ============================================================================

function Write-ProgressState {
    if ($null -eq $script:Progress) { return }
    if (-not [string]::IsNullOrWhiteSpace($script:ProgressFile)) {
        try {
            $script:Progress.items = @($script:ProgressItems.Values)
            $json = $script:Progress | ConvertTo-Json -Depth 6
            $tempFile = "$($script:ProgressFile).tmp"
            [System.IO.File]::WriteAllText($tempFile, $json, $script:Utf8NoBom)
            Move-Item -LiteralPath $tempFile -Destination $script:ProgressFile -Force
        } catch { }
    }
}

function Initialize-Progress {
    param($Files)

    $script:ProgressItems = [ordered]@{}
    foreach ($file in @($Files)) {
        $script:ProgressItems[$file.id] = [ordered]@{
            id      = $file.id
            name    = $file.name
            status  = 'pending'
            message = ''
        }
    }

    $script:Progress = [ordered]@{
        percent   = 0
        status    = 'Iniciando...'
        current   = ''
        done      = $false
        success   = $true
        cancelled = $false
        startedAt = (Get-Date).ToString('o')
        items     = @()
    }
    Write-ProgressState
}

function Set-ProgressItem {
    param([string]$Id, [string]$Status, [string]$Message)

    if (-not $script:ProgressItems.Contains($Id)) { return }
    $script:ProgressItems[$Id].status = $Status
    $script:ProgressItems[$Id].message = $Message
    Write-ProgressState
}

function Update-DownloadProgress {
    param([double]$Fraction, [string]$Name)

    if ($script:HeadlessTotal -le 0) { return }
    $index = [int]$script:HeadlessIndex
    $percent = [int](100 * (($index - 1 + $Fraction) / $script:HeadlessTotal))
    if ($percent -lt 0) { $percent = 0 }
    if ($percent -gt 100) { $percent = 100 }

    if ($percent -ne $script:LastProgressPercent) {
        $script:LastProgressPercent = $percent
        $script:Progress.percent = $percent
        $script:Progress.status = "Descargando {0}... {1}%" -f $Name, [int]($Fraction * 100)
        Write-ProgressState
    }
}

function Get-FilesForRun {
    param($Config, [string[]]$Ids = @())

    $idList = @($Ids | ForEach-Object { ([string]$_ -split ',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($idList.Count -eq 0) { return @($Config.files) }

    $map = @{}
    foreach ($file in @($Config.files)) { $map[$file.id.ToLowerInvariant()] = $file }

    $result = @()
    foreach ($id in $idList) {
        $key = $id.ToLowerInvariant()
        if ($map.ContainsKey($key)) {
            $result += $map[$key]
        } else {
            Write-LogLine "Programa desconocido en -Install: $id" 'WARN'
        }
    }
    return $result
}

function Get-TweaksForRun {
    param($Config, [string[]]$Ids = @(), [switch]$None)

    if ($None) { return @() }

    $idList = @($Ids | ForEach-Object { ([string]$_ -split ',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($idList.Count -eq 0) {
        return @($Config.tweaks | Where-Object { $_.enabled })
    }

    $map = @{}
    foreach ($tweak in @($Config.tweaks)) { $map[$tweak.id.ToLowerInvariant()] = $tweak }

    $result = @()
    foreach ($id in $idList) {
        $key = $id.ToLowerInvariant()
        if ($map.ContainsKey($key)) {
            $result += $map[$key]
        } else {
            Write-LogLine "Tweak desconocido en -Tweaks: $id" 'WARN'
        }
    }
    return $result
}

function Initialize-HeadlessContext {
    $script:ProgressFile = if ($ProgressFile) { Resolve-LocalPath $ProgressFile } else { '' }
    $script:CancelFile = if ($CancelFile) { Resolve-LocalPath $CancelFile } else { '' }
    $script:HeadlessTotal = 0
    $script:HeadlessIndex = 0
    $script:LastProgressPercent = -1
}

function Complete-HeadlessRun {
    param(
        [bool]$Success,
        [string]$Status,
        [int]$ExitCode,
        [switch]$Cancelled
    )

    if ($Cancelled) { $script:Progress.cancelled = $true }
    $script:Progress.success = $Success
    if ($Success) { $script:Progress.percent = 100 }
    $script:Progress.status = $Status
    $script:Progress.done = $true
    Write-ProgressState
    return $ExitCode
}

function Invoke-ApplyTweaksMain {
    param($Config)

    $selectedTweaks = @(Get-TweaksForRun -Config $Config -Ids $Tweaks -None:$NoTweaks)
    Initialize-Progress -Files @()

    if ($selectedTweaks.Count -eq 0) {
        Write-LogLine 'No hay ajustes seleccionados.' 'WARN'
        return (Complete-HeadlessRun -Success $true -Status 'No hay ajustes seleccionados.' -ExitCode 0)
    }

    Write-LogLine ("Aplicando {0} ajuste(s)..." -f $selectedTweaks.Count) 'INFO'
    if ($DryRun) {
        Write-LogLine 'DryRun: no se aplican ajustes.' 'WARN'
        return (Complete-HeadlessRun -Success $true -Status 'DryRun: ajustes omitidos.' -ExitCode 0)
    }
    $ordered = @(@($selectedTweaks | Where-Object { $_.type -eq 'restorepoint' }) + @($selectedTweaks | Where-Object { $_.type -ne 'restorepoint' }))

    $applied = 0
    $failed = $false
    $cancelled = $false
    $index = 0

    foreach ($tweak in $ordered) {
        if (Test-CancelRequested) { $cancelled = $true; break }

        $index++
        $script:Progress.percent = [int](100 * ($index - 1) / [Math]::Max(1, $ordered.Count))
        $script:Progress.status = "Aplicando: $($tweak.name)..."
        Write-ProgressState

        try {
            Invoke-Tweak -Tweak $tweak
            $applied++
        } catch {
            $failed = $true
            Write-LogLine "ERROR al aplicar '$($tweak.name)': $($_.Exception.Message)" 'ERROR'
        }
    }

    $script:Progress.percent = [int](100 * $index / [Math]::Max(1, $ordered.Count))
    Write-ProgressState

    if ($cancelled) {
        Write-LogLine 'Aplicacion de ajustes cancelada.' 'WARN'
        return (Complete-HeadlessRun -Success $false -Status 'Cancelado por el usuario.' -ExitCode 3 -Cancelled)
    }
    if ($failed) {
        Write-LogLine 'La aplicacion de ajustes termino con errores.' 'ERROR'
        return (Complete-HeadlessRun -Success $false -Status 'Ajustes aplicados con errores.' -ExitCode 2)
    }

    Write-LogLine ("Ajustes aplicados: {0}." -f $applied) 'OK'
    return (Complete-HeadlessRun -Success $true -Status ("Ajustes aplicados: {0}." -f $applied) -ExitCode 0)
}

function Invoke-UndoTweaksMain {
    param($Config)

    $selectedTweaks = @(Get-TweaksForRun -Config $Config -Ids $Tweaks -None:$NoTweaks)
    Initialize-Progress -Files @()

    if ($selectedTweaks.Count -eq 0) {
        Write-LogLine 'No hay ajustes seleccionados para deshacer.' 'WARN'
        return (Complete-HeadlessRun -Success $true -Status 'No hay ajustes seleccionados.' -ExitCode 0)
    }

    $undoable = @($selectedTweaks | Where-Object { $_.type -ne 'restorepoint' })
    if ($undoable.Count -ne $selectedTweaks.Count) {
        Write-LogLine 'Los puntos de restauracion no se pueden deshacer desde aqui.' 'WARN'
    }
    if ($undoable.Count -eq 0) {
        return (Complete-HeadlessRun -Success $true -Status 'No hay ajustes reversibles seleccionados.' -ExitCode 0)
    }

    if ($DryRun) {
        Write-LogLine 'DryRun: no se deshacen ajustes.' 'WARN'
        return (Complete-HeadlessRun -Success $true -Status 'DryRun: restauracion omitida.' -ExitCode 0)
    }

    [array]::Reverse($undoable)

    $undone = 0
    $skipped = 0
    $failed = $false
    $cancelled = $false
    $index = 0

    foreach ($tweak in $undoable) {
        if (Test-CancelRequested) { $cancelled = $true; break }

        $index++
        $script:Progress.percent = [int](100 * ($index - 1) / [Math]::Max(1, $undoable.Count))
        $script:Progress.status = "Restaurando: $($tweak.name)..."
        Write-ProgressState

        try {
            $changed = Invoke-UndoTweak -Tweak $tweak
            if ($changed) { $undone++ } else { $skipped++ }
        } catch {
            $failed = $true
            Write-LogLine "ERROR al deshacer '$($tweak.name)': $($_.Exception.Message)" 'ERROR'
        }
    }

    $script:Progress.percent = [int](100 * $index / [Math]::Max(1, $undoable.Count))
    Write-ProgressState

    if ($cancelled) {
        Write-LogLine 'Restauracion de ajustes cancelada.' 'WARN'
        return (Complete-HeadlessRun -Success $false -Status 'Cancelado por el usuario.' -ExitCode 3 -Cancelled)
    }
    if ($failed) {
        Write-LogLine 'La restauracion termino con errores.' 'ERROR'
        return (Complete-HeadlessRun -Success $false -Status 'Ajustes restaurados con errores.' -ExitCode 2)
    }

    $status = "Ajustes restaurados: $undone; sin cambios: $skipped."
    Write-LogLine $status 'OK'
    return (Complete-HeadlessRun -Success $true -Status $status -ExitCode 0)
}

function Invoke-UpgradeMain {
    param($Config)

    $selectedFiles = @(Get-FilesForRun -Config $Config -Ids $Install)
    Initialize-Progress -Files $selectedFiles

    if (-not (Test-WingetAvailable)) {
        Write-LogLine 'winget no esta disponible; no se pueden actualizar aplicaciones.' 'ERROR'
        return (Complete-HeadlessRun -Success $false -Status 'winget no esta disponible.' -ExitCode 2)
    }

    if ($selectedFiles.Count -eq 0) {
        Write-LogLine 'No hay programas seleccionados para actualizar.' 'WARN'
        return (Complete-HeadlessRun -Success $true -Status 'No hay programas seleccionados.' -ExitCode 0)
    }

    Write-LogLine ("Actualizando {0} programa(s) con winget..." -f $selectedFiles.Count) 'INFO'
    if ($DryRun) {
        Write-LogLine 'DryRun: no se actualizan programas.' 'WARN'
        return (Complete-HeadlessRun -Success $true -Status 'DryRun: actualizaciones omitidas.' -ExitCode 0)
    }

    $updated = 0
    $uptodate = 0
    $skipped = 0
    $failed = $false
    $cancelled = $false
    $index = 0

    foreach ($file in $selectedFiles) {
        if (Test-CancelRequested) { $cancelled = $true; break }

        $index++
        $script:HeadlessTotal = $selectedFiles.Count
        $script:HeadlessIndex = $index
        $script:Progress.current = $file.id
        $script:Progress.status = "Actualizando $($file.name)..."
        Set-ProgressItem -Id $file.id -Status 'upgrading' -Message ''

        try {
            $result = Invoke-WingetUpgradeFile -File $file
            switch ($result) {
                'updated' {
                    $updated++
                    Set-ProgressItem -Id $file.id -Status 'updated' -Message 'Actualizado'
                    Write-LogLine "OK: $($file.name) actualizado." 'OK'
                }
                'uptodate' {
                    $uptodate++
                    Set-ProgressItem -Id $file.id -Status 'uptodate' -Message 'Al dia'
                    Write-LogLine "OK: $($file.name) ya esta al dia." 'OK'
                }
                'skipped' {
                    $skipped++
                    Set-ProgressItem -Id $file.id -Status 'skipped' -Message 'No instalado'
                    Write-LogLine "Se omite $($file.name): winget no lo tiene instalado." 'WARN'
                }
            }
        } catch {
            $failed = $true
            Set-ProgressItem -Id $file.id -Status 'error' -Message $_.Exception.Message
            Write-LogLine "ERROR al actualizar $($file.name): $($_.Exception.Message)" 'ERROR'
        }

        $script:Progress.percent = [int](100 * $index / [Math]::Max(1, $selectedFiles.Count))
        Write-ProgressState
    }

    if ($cancelled) {
        Write-LogLine 'Actualizacion cancelada.' 'WARN'
        return (Complete-HeadlessRun -Success $false -Status 'Cancelado por el usuario.' -ExitCode 3 -Cancelled)
    }
    if ($failed) {
        Write-LogLine 'La actualizacion termino con errores.' 'ERROR'
        return (Complete-HeadlessRun -Success $false -Status 'Actualizacion con errores.' -ExitCode 2)
    }

    $status = "Actualizaciones: $updated actualizado(s), $uptodate al dia, $skipped omitido(s)."
    Write-LogLine $status 'OK'
    return (Complete-HeadlessRun -Success $true -Status $status -ExitCode 0)
}

function Invoke-UninstallMain {
    param($Config)

    $selectedFiles = @(Get-FilesForRun -Config $Config -Ids $Install)
    Initialize-Progress -Files $selectedFiles

    if (-not (Test-WingetAvailable)) {
        Write-LogLine 'winget no esta disponible; no se pueden desinstalar aplicaciones.' 'ERROR'
        return (Complete-HeadlessRun -Success $false -Status 'winget no esta disponible.' -ExitCode 2)
    }

    if ($selectedFiles.Count -eq 0) {
        Write-LogLine 'No hay programas seleccionados para desinstalar.' 'WARN'
        return (Complete-HeadlessRun -Success $true -Status 'No hay programas seleccionados.' -ExitCode 0)
    }

    Write-LogLine ("Desinstalando {0} programa(s) con winget..." -f $selectedFiles.Count) 'INFO'
    if ($DryRun) {
        Write-LogLine 'DryRun: no se desinstalan programas.' 'WARN'
        return (Complete-HeadlessRun -Success $true -Status 'DryRun: desinstalacion omitida.' -ExitCode 0)
    }

    $uninstalled = 0
    $skipped = 0
    $failed = $false
    $cancelled = $false
    $index = 0

    foreach ($file in $selectedFiles) {
        if (Test-CancelRequested) { $cancelled = $true; break }

        $index++
        $script:HeadlessTotal = $selectedFiles.Count
        $script:HeadlessIndex = $index
        $script:Progress.current = $file.id
        $script:Progress.status = "Desinstalando $($file.name)..."
        Set-ProgressItem -Id $file.id -Status 'uninstalling' -Message ''

        try {
            $done = Invoke-WingetUninstallFile -File $file
            if ($done) {
                $uninstalled++
                Set-ProgressItem -Id $file.id -Status 'uninstalled' -Message 'Desinstalado'
                Write-LogLine "OK: $($file.name) desinstalado." 'OK'
            } else {
                $skipped++
                Set-ProgressItem -Id $file.id -Status 'skipped' -Message 'No encontrado'
            }
        } catch {
            $failed = $true
            Set-ProgressItem -Id $file.id -Status 'error' -Message $_.Exception.Message
            Write-LogLine "ERROR al desinstalar $($file.name): $($_.Exception.Message)" 'ERROR'
        }

        $script:Progress.percent = [int](100 * $index / [Math]::Max(1, $selectedFiles.Count))
        Write-ProgressState
    }

    if ($cancelled) {
        Write-LogLine 'Desinstalacion cancelada.' 'WARN'
        return (Complete-HeadlessRun -Success $false -Status 'Cancelado por el usuario.' -ExitCode 3 -Cancelled)
    }
    if ($failed) {
        Write-LogLine 'La desinstalacion termino con errores.' 'ERROR'
        return (Complete-HeadlessRun -Success $false -Status 'Desinstalacion con errores.' -ExitCode 2)
    }

    $status = "Desinstalados: $uninstalled; omitidos: $skipped."
    Write-LogLine $status 'OK'
    return (Complete-HeadlessRun -Success $true -Status $status -ExitCode 0)
}

function Set-InstallResult {
    param($File)

    $installed = Resolve-InstalledPath -File $File
    if ($File.installedPath -and -not $installed) {
        Set-ProgressItem -Id $File.id -Status 'warn' -Message 'Instalado, ruta no encontrada'
        Write-LogLine "ADVERTENCIA: $($File.name) se instalo, pero no se encontro '$($File.installedPath)'." 'WARN'
    } else {
        Set-ProgressItem -Id $File.id -Status 'ok' -Message 'Instalado'
        if ($installed) {
            Write-LogLine "OK: $($File.name) instalado en $installed." 'OK'
        } else {
            Write-LogLine "OK: $($File.name) instalado." 'OK'
        }
    }
}

function Invoke-InstallMain {
    param($Config)

    $selectedFiles = @(Get-FilesForRun -Config $Config -Ids $Install)
    $selectedTweaks = @(Get-TweaksForRun -Config $Config -Ids $Tweaks -None:$NoTweaks)

    Write-LogLine ("Modo headless ({0}): {1} programa(s), {2} tweak(s)." -f $Backend, $selectedFiles.Count, $selectedTweaks.Count) 'INFO'
    if ($DryRun) { Write-LogLine 'Modo DryRun: solo se descarga y verifica; no se instala nada.' 'WARN' }

    Initialize-Progress -Files $selectedFiles

    $downloadDir = Join-Path $env:TEMP 'ElvisLab\downloads'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    $script:HeadlessTotal = $selectedFiles.Count
    $script:HeadlessIndex = 0
    $script:LastProgressPercent = -1
    $failed = $false
    $cancelled = $false

    # Los tweaks se aplican antes de instalar. El punto de restauracion va primero.
    if (-not $DryRun -and $selectedTweaks.Count -gt 0) {
        $orderedTweaks = @(@($selectedTweaks | Where-Object { $_.type -eq 'restorepoint' }) + @($selectedTweaks | Where-Object { $_.type -ne 'restorepoint' }))
        foreach ($tweak in $orderedTweaks) {
            if (Test-CancelRequested) { $cancelled = $true; break }
            $script:Progress.status = "Aplicando ajuste: $($tweak.name)..."
            Write-ProgressState
            try {
                Invoke-Tweak -Tweak $tweak
            } catch {
                Write-LogLine "ERROR al aplicar '$($tweak.name)': $($_.Exception.Message)" 'ERROR'
            }
        }
    }

    $index = 0
    foreach ($file in $selectedFiles) {
        if ($cancelled -or (Test-CancelRequested)) { $cancelled = $true; break }

        $index++
        $script:HeadlessIndex = $index
        $script:Progress.current = $file.id

        try {
            if ($Backend -eq 'winget') {
                if (-not $file.wingetId) {
                    throw "No hay wingetId configurado para '$($file.name)'."
                }

                if ($DryRun) {
                    Set-ProgressItem -Id $file.id -Status 'skipped' -Message 'DryRun'
                    Write-LogLine "DryRun: se omite winget install de $($file.name)." 'WARN'
                } else {
                    Set-ProgressItem -Id $file.id -Status 'installing' -Message ''
                    $script:Progress.status = "Instalando $($file.name) con winget..."
                    Write-ProgressState
                    Invoke-WingetInstallOrUpgrade -File $file | Out-Null
                    Set-InstallResult -File $file
                }
            } else {
                $destination = Join-Path $downloadDir $file.destination
                Set-ProgressItem -Id $file.id -Status 'downloading' -Message ''
                $script:Progress.status = "Preparando $($file.name)..."
                Write-ProgressState

                $cached = $false
                if ((Test-Path -LiteralPath $destination) -and $file.sha256) {
                    $existingHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
                    if ($existingHash -eq $file.sha256) {
                        $cached = $true
                        Write-LogLine "Se reutiliza la descarga verificada de $($file.name)." 'OK'
                    }
                }

                if (-not $cached) {
                    Write-LogLine "Descargando $($file.name)..." 'INFO'
                    $progressCallback = {
                        param([double]$fraction)
                        Update-DownloadProgress -Fraction $fraction -Name $file.name
                    }
                    Invoke-HttpDownload -Url $file.source -Destination $destination -TimeoutSec $file.downloadTimeoutSec -OnPercent $progressCallback
                }

                Set-ProgressItem -Id $file.id -Status 'verifying' -Message ''
                $script:Progress.status = "Verificando $($file.name)..."
                Write-ProgressState
                Test-FileIntegrity -File $file -Path $destination

                if ($DryRun) {
                    Set-ProgressItem -Id $file.id -Status 'downloaded' -Message 'Descargado y verificado'
                    Write-LogLine "OK: $($file.name) descargado y verificado (DryRun)." 'OK'
                } else {
                    Set-ProgressItem -Id $file.id -Status 'installing' -Message ''
                    $script:Progress.status = "Instalando $($file.name)..."
                    Write-ProgressState
                    Invoke-Installer -File $file -Path $destination
                    Set-InstallResult -File $file
                }
            }

            $script:Progress.percent = [int](100 * $index / [Math]::Max(1, $selectedFiles.Count))
            Write-ProgressState
        } catch {
            if (Test-CancelRequested) {
                $cancelled = $true
                Set-ProgressItem -Id $file.id -Status 'cancelled' -Message 'Cancelado'
                break
            }
            $failed = $true
            Set-ProgressItem -Id $file.id -Status 'error' -Message $_.Exception.Message
            Write-LogLine "ERROR con $($file.name): $($_.Exception.Message)" 'ERROR'
            $script:Progress.percent = [int](100 * $index / [Math]::Max(1, $selectedFiles.Count))
            Write-ProgressState
        }
    }

    if ($Shortcuts -and -not $cancelled -and -not $DryRun) {
        $script:Progress.status = 'Creando accesos directos...'
        Write-ProgressState
        $created = 0
        foreach ($shortcut in @($Config.shortcuts)) {
            try {
                if (New-ShortcutItem -Shortcut $shortcut -Config $Config) { $created++ }
            } catch {
                Write-LogLine "ERROR al crear el acceso '$($shortcut.name)': $($_.Exception.Message)" 'ERROR'
            }
        }
        Write-LogLine ("Accesos directos creados: {0}" -f $created) 'OK'
    }

    $statuses = @($script:ProgressItems.Values)
    $errorCount = @($statuses | Where-Object { $_.status -eq 'error' }).Count
    $okCount = @($statuses | Where-Object { $_.status -in @('ok', 'downloaded') }).Count
    $warnCount = @($statuses | Where-Object { $_.status -eq 'warn' }).Count

    if ($cancelled) {
        $script:Progress.cancelled = $true
        $script:Progress.success = $false
        $script:Progress.status = 'Cancelado por el usuario.'
        Write-LogLine 'Proceso cancelado por el usuario.' 'WARN'
    } elseif ($failed -or $errorCount -gt 0) {
        $script:Progress.success = $false
        $script:Progress.status = "Completado con $errorCount error(es)."
        Write-LogLine "Proceso completado con $errorCount error(es)." 'ERROR'
    } else {
        $script:Progress.success = $true
        $script:Progress.percent = 100
        $script:Progress.status = "Completado: $okCount programa(s)."
        Write-LogLine "Proceso completado. Programas correctos: $okCount; advertencias: $warnCount." 'OK'
    }

    $script:Progress.done = $true
    Write-ProgressState

    if ($cancelled) { return 3 }
    if ($script:Progress.success) { return 0 }
    return 2
}

function Invoke-HeadlessMain {
    param($Config)

    Initialize-HeadlessContext

    if ($ApplyOnly) { return (Invoke-ApplyTweaksMain -Config $Config) }
    if ($UndoTweaks) { return (Invoke-UndoTweaksMain -Config $Config) }
    if ($Upgrade) { return (Invoke-UpgradeMain -Config $Config) }
    if ($Uninstall) { return (Invoke-UninstallMain -Config $Config) }
    return (Invoke-InstallMain -Config $Config)
}
