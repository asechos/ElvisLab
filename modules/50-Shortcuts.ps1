# ============================================================================
# ElvisLab - Creacion de accesos directos
# ============================================================================

function New-ShortcutItem {
    param($Shortcut, $Config)

    $target = ''
    if ($Shortcut.fileId) {
        $file = @($Config.files | Where-Object { $_.id -eq $Shortcut.fileId }) | Select-Object -First 1
        if ($file) {
            $target = Resolve-InstalledPath -File $file
            if (-not $target -and $file.installedPath) { $target = Resolve-LocalPath $file.installedPath }
        }
    } elseif ($Shortcut.target) {
        $target = Resolve-LocalPath $Shortcut.target
    }

    if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target -PathType Leaf)) {
        Write-LogLine ("Se omite el acceso '{0}': no se encontro '{1}'." -f $Shortcut.name, $target) 'WARN'
        return $false
    }

    switch ([string]$Shortcut.location) {
        'Desktop' {
            $folder = [Environment]::GetFolderPath('Desktop')
            if (-not $folder) { $folder = Join-Path $env:USERPROFILE 'Desktop' }
        }
        'StartMenu' {
            $folder = [Environment]::GetFolderPath('Programs')
            if (-not $folder) { $folder = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
        }
        default { $folder = Resolve-LocalPath $Shortcut.location }
    }

    if (-not $folder) {
        Write-LogLine ("Se omite el acceso '{0}': ubicacion no valida." -f $Shortcut.name) 'WARN'
        return $false
    }
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    $shortcutPath = Join-Path $folder $Shortcut.fileName

    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($shortcutPath)
        $link.TargetPath = $target
        $link.WorkingDirectory = Split-Path -Parent $target
        if ($Shortcut.arguments) { $link.Arguments = $Shortcut.arguments }
        if ($Shortcut.description) { $link.Description = $Shortcut.description } else { $link.Description = $Shortcut.name }
        if ($Shortcut.icon) {
            $iconPath = Resolve-LocalPath $Shortcut.icon
            if (Test-Path -LiteralPath $iconPath) { $link.IconLocation = "$iconPath,0" }
        }
        $link.Save()
    } finally {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
    }

    Write-LogLine "Acceso directo creado: $shortcutPath" 'OK'
    return $true
}
