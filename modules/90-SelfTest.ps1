# ============================================================================
# ElvisLab - Autotest
# ============================================================================

function Invoke-SelfTest {
    param($Config)

    $ok = $true
    $admin = Test-IsAdmin

    Write-LogLine '=== ElvisLab SelfTest ===' 'INFO'
    Write-LogLine ("PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition) 'INFO'
    Write-LogLine ("Proceso de 64 bits: {0}" -f [Environment]::Is64BitProcess) 'INFO'
    Write-LogLine ("Administrador: {0}" -f $admin) 'INFO'
    Write-LogLine ("Directorio del script: {0}" -f $script:ScriptDir) 'INFO'
    Write-LogLine ("Script de entrada: {0}" -f $script:EntryScriptPath) 'INFO'
    Write-LogLine ("Archivo de registro: {0}" -f $script:LogFile) 'INFO'

    try {
        $launch = Get-HostLaunchCommand
        Write-LogLine ("Host para trabajos: {0} {1}" -f $launch.FileName, ($launch.Prefix -join ' ')) 'INFO'
    } catch {
        Write-LogLine ("No se pudo resolver el host de trabajos: {0}" -f $_.Exception.Message) 'WARN'
    }

    $ps2exe = Get-Command ps2exe -ErrorAction SilentlyContinue
    if (-not $ps2exe) { $ps2exe = Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue }
    Write-LogLine ("ps2exe disponible: {0}" -f [bool]$ps2exe) 'INFO'

    $wingetOk = Test-WingetAvailable
    $wingetVersionText = ''
    if ($wingetOk) {
        try { $wingetVersionText = ((& winget --version 2>&1 | Out-String).Trim()) } catch { }
    }
    Write-LogLine ("winget disponible: {0} {1}" -f $wingetOk, $wingetVersionText) 'INFO'

    $powerPlans = @(Get-PowerPlans)
    Write-LogLine ("Planes de energia detectados: {0}" -f $powerPlans.Count) 'INFO'

    foreach ($file in @($Config.files)) {
        $http = 'sin comprobar'
        try {
            $response = Invoke-WebRequest -Uri $file.source -Method Head -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 5
            $http = [int]$response.StatusCode
        } catch {
            $http = "ERROR: $($_.Exception.Message)"
            $ok = $false
        }

        $verification = @()
        if ($file.sha256) { $verification += 'SHA256' }
        if ($file.publisher) { $verification += "firma ($($file.publisher))" }
        if ($verification.Count -eq 0) { $verification += 'SIN VERIFICACION' }
        if ($verification -contains 'SIN VERIFICACION' -and -not $file.allowUnverified) { $ok = $false }

        $installed = Resolve-InstalledPath -File $file
        Write-LogLine ("{0}: HTTP {1}; verificacion: {2}; instalado: {3}" -f $file.name, $http, ($verification -join ' + '), [bool]$installed) 'INFO'
    }

    foreach ($tweak in @($Config.tweaks)) {
        Write-LogLine ("Tweak '{0}' ({1}), activo por defecto: {2}" -f $tweak.name, $tweak.type, $tweak.enabled) 'INFO'
    }

    foreach ($shortcut in @($Config.shortcuts)) {
        $resolved = ''
        if ($shortcut.fileId) {
            $file = @($Config.files | Where-Object { $_.id -eq $shortcut.fileId }) | Select-Object -First 1
            if ($file) { $resolved = Resolve-InstalledPath -File $file }
        } elseif ($shortcut.target) {
            $resolved = Resolve-LocalPath $shortcut.target
        }
        Write-LogLine ("Acceso '{0}' -> {1} (existe: {2})" -f $shortcut.name, $resolved, [bool]($resolved -and (Test-Path -LiteralPath $resolved))) 'INFO'
    }

    if (-not $admin) {
        Write-LogLine 'Nota: para instalar es necesario ejecutar como Administrador.' 'WARN'
    }

    Write-LogLine ("SelfTest: {0}" -f $(if ($ok) { 'OK' } else { 'con problemas' })) $(if ($ok) { 'OK' } else { 'WARN' })
    if ($ok) { return 0 }
    return 1
}
