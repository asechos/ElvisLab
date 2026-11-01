# ============================================================================
# ElvisLab - Aplicacion y restauracion de tweaks
# ============================================================================

function Invoke-RegistryTweak {
    param($Tweak)

    if (-not $Tweak.values -or @($Tweak.values).Count -eq 0) {
        throw "El tweak '$($Tweak.id)' no tiene valores de registro."
    }

    foreach ($item in @($Tweak.values)) {
        $path = Resolve-LocalPath $item.path
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -Force | Out-Null
        }

        $value = Convert-RegistryValue -Value $item.value -Kind $item.kind
        New-ItemProperty -Path $path -Name $item.valueName -Value $value -PropertyType $item.kind -Force | Out-Null
    }

    Write-LogLine "Tweak aplicado: $($Tweak.name)" 'OK'
}

function Invoke-ServiceTweak {
    param($Tweak)

    $service = Get-Service -Name $Tweak.serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-LogLine "El servicio '$($Tweak.serviceName)' no existe; se omite '$($Tweak.name)'." 'WARN'
        return
    }

    Set-Service -Name $Tweak.serviceName -StartupType $Tweak.startupType -ErrorAction Stop

    if ($Tweak.stopService) {
        $service.Refresh()
        if ($service.Status -eq 'Running') {
            Stop-Service -Name $Tweak.serviceName -Force -ErrorAction Stop
        }
    }

    Write-LogLine "Servicio $($Tweak.serviceName) configurado como $($Tweak.startupType)." 'OK'
}

function Invoke-HibernationTweak {
    param($Tweak)

    $setting = if ($Tweak.hibernationAction -eq 'enable') { 'on' } else { 'off' }
    $output = (& powercfg.exe /hibernate $setting 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg fallo (codigo $LASTEXITCODE): $output"
    }

    Write-LogLine "Hibernacion: $setting." 'OK'
}

function Invoke-RestorePointTweak {
    param($Tweak)

    Write-LogLine "Creando punto de restauracion: $($Tweak.name)..." 'INFO'

    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
    } catch {
        Write-LogLine "No se pudo habilitar la proteccion del sistema: $($_.Exception.Message)" 'WARN'
    }

    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $previousFrequency = $null
    $hadFrequency = $false
    try {
        $previousFrequency = (Get-ItemProperty -Path $regPath -Name 'SystemRestorePointCreationFrequency' -ErrorAction Stop).SystemRestorePointCreationFrequency
        $hadFrequency = $true
    } catch { }

    try {
        if (-not (Test-Path -LiteralPath $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        New-ItemProperty -Path $regPath -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description ("ElvisLab: {0}" -f $Tweak.name) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-LogLine 'Punto de restauracion creado correctamente.' 'OK'
    } catch {
        Write-LogLine "No se pudo crear el punto de restauracion: $($_.Exception.Message)" 'WARN'
    } finally {
        try {
            if ($hadFrequency) {
                Set-ItemProperty -Path $regPath -Name 'SystemRestorePointCreationFrequency' -Value $previousFrequency
            } else {
                Remove-ItemProperty -Path $regPath -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}

function Invoke-UndoRegistryTweak {
    param($Tweak)

    if (-not $Tweak.values -or @($Tweak.values).Count -eq 0) { return $false }

    $changed = $false
    foreach ($item in @($Tweak.values)) {
        $path = Resolve-LocalPath $item.path
        if (-not (Test-Path -LiteralPath $path)) { continue }

        if ($item.undoAction -eq 'set') {
            $value = Convert-RegistryValue -Value $item.undoValue -Kind $item.undoKind
            New-ItemProperty -Path $path -Name $item.valueName -Value $value -PropertyType $item.undoKind -Force | Out-Null
            $changed = $true
        } else {
            $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($key -and ($key.Property -contains $item.valueName)) {
                Remove-ItemProperty -Path $path -Name $item.valueName -ErrorAction Stop
                $changed = $true
            }
        }
    }

    if ($changed) {
        Write-LogLine "Ajuste restaurado: $($Tweak.name)" 'OK'
    } else {
        Write-LogLine "Nada que deshacer en '$($Tweak.name)'." 'WARN'
    }

    return $changed
}

function Invoke-UndoServiceTweak {
    param($Tweak)

    $service = Get-Service -Name $Tweak.serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-LogLine "El servicio '$($Tweak.serviceName)' no existe; se omite." 'WARN'
        return $false
    }

    Set-Service -Name $Tweak.serviceName -StartupType $Tweak.undoStartupType -ErrorAction Stop

    if ($Tweak.undoStartService) {
        $service.Refresh()
        if ($service.Status -ne 'Running') {
            Start-Service -Name $Tweak.serviceName -ErrorAction Stop
        }
    }

    Write-LogLine "Servicio $($Tweak.serviceName) restaurado a $($Tweak.undoStartupType)." 'OK'
    return $true
}

function Invoke-UndoHibernationTweak {
    param($Tweak)

    $setting = if ($Tweak.hibernationAction -eq 'enable') { 'off' } else { 'on' }
    $output = (& powercfg.exe /hibernate $setting 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg fallo (codigo $LASTEXITCODE): $output"
    }

    Write-LogLine "Hibernacion restaurada: $setting." 'OK'
    return $true
}

function Invoke-UndoTweak {
    param($Tweak)

    switch ([string]$Tweak.type) {
        'restorepoint' {
            Write-LogLine "El punto de restauracion no se puede deshacer desde aqui: $($Tweak.name)" 'WARN'
            return $false
        }
        'registry' {
            return (Invoke-UndoRegistryTweak -Tweak $Tweak)
        }
        'service' {
            return (Invoke-UndoServiceTweak -Tweak $Tweak)
        }
        'hibernation' {
            return (Invoke-UndoHibernationTweak -Tweak $Tweak)
        }
        default {
            throw "Tipo de tweak desconocido: $($Tweak.type)"
        }
    }
}

function Invoke-Tweak {
    param($Tweak)

    switch ([string]$Tweak.type) {
        'restorepoint' { Invoke-RestorePointTweak -Tweak $Tweak }
        'registry' { Invoke-RegistryTweak -Tweak $Tweak }
        'service' { Invoke-ServiceTweak -Tweak $Tweak }
        'hibernation' { Invoke-HibernationTweak -Tweak $Tweak }
        default { throw "Tipo de tweak desconocido: $($Tweak.type)" }
    }
}
