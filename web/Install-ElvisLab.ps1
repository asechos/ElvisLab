# ============================================================================
# ElvisLab - Bootstrap remoto para irm ... | iex
# ============================================================================
# Ejecuta la app desde un release o, si no existe, desde la rama master.
# La app se instala en %LOCALAPPDATA%\ElvisLab\app-* y la configuracion
# del usuario se conserva en %LOCALAPPDATA%\ElvisLab\config.json.
#
# Repositorio: https://github.com/asechos/ElvisLab
# Release: https://github.com/asechos/ElvisLab/releases/latest/download/ElvisLab.zip
# ============================================================================
[CmdletBinding()]
param(
    [string]$PackageUrl = $(if ($env:ELVISLAB_PACKAGE_URL) { $env:ELVISLAB_PACKAGE_URL } else { 'https://github.com/asechos/ElvisLab/releases/latest/download/ElvisLab.zip' }),
    [string]$DataDir = "$env:LOCALAPPDATA\ElvisLab",
    [switch]$ResetConfig,
    [switch]$Headless,
    [string]$Install = '',
    [string]$Tweaks = '',
    [switch]$NoTweaks,
    [switch]$Shortcuts,
    [switch]$DryRun,
    [string]$Backend = '',
    [switch]$ApplyOnly,
    [switch]$UndoTweaks,
    [switch]$Upgrade,
    [switch]$UpgradeAll,
    [switch]$WindowsUpdate,
    [switch]$Uninstall,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Test-BootstrapAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

$DataDir = [Environment]::ExpandEnvironmentVariables($DataDir)
try { $DataDir = [System.IO.Path]::GetFullPath($DataDir) } catch { }

$operationRequested = ($Install -or $Tweaks -or $NoTweaks -or $Shortcuts -or $DryRun -or $Backend -or $ApplyOnly -or $UndoTweaks -or $Upgrade -or $UpgradeAll -or $WindowsUpdate -or $Uninstall)
if ($operationRequested -and -not $Headless -and -not $SelfTest) {
    Write-Host 'ElvisLab: argumentos de operacion detectados; se usara modo Headless.' -ForegroundColor Yellow
    $Headless = $true
}

$zipPath = Join-Path $env:TEMP ('ElvisLab-' + [guid]::NewGuid().ToString('N') + '.zip')
$staging = Join-Path $env:TEMP ('ElvisLab-stage-' + [guid]::NewGuid().ToString('N'))
$appDir = $null
$configPath = $null

try {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    Write-Host 'ElvisLab: descargando paquete...' -ForegroundColor Cyan
    if ($PackageUrl -match '^https?://') {
        try {
            Invoke-WebRequest -Uri $PackageUrl -OutFile $zipPath -UseBasicParsing
        } catch {
            if ($PackageUrl -match '^https://github\.com/asechos/ElvisLab/releases/') {
                $archiveUrl = 'https://github.com/asechos/ElvisLab/archive/refs/heads/master.zip'
                Write-Host 'ElvisLab: no hay release disponible; usando la rama master.' -ForegroundColor Yellow
                Invoke-WebRequest -Uri $archiveUrl -OutFile $zipPath -UseBasicParsing
            } else {
                throw
            }
        }
    } else {
        Copy-Item -LiteralPath $PackageUrl -Destination $zipPath -Force
    }

    Expand-Archive -Path $zipPath -DestinationPath $staging -Force
    $appFile = Get-ChildItem -Path $staging -Recurse -Filter 'ElvisLab.ps1' -File | Select-Object -First 1
    if (-not $appFile) {
        throw 'El paquete descargado no contiene ElvisLab.ps1.'
    }

    $appSource = $appFile.Directory.FullName
    $appDir = Join-Path $DataDir ('app-' + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    Copy-Item -Path (Join-Path $appSource '*') -Destination $appDir -Recurse -Force
    Get-ChildItem -Path $appDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    $packageConfig = Join-Path $appDir 'config.json'
    if (-not (Test-Path -LiteralPath $packageConfig)) {
        throw 'El paquete no contiene config.json.'
    }

    $configPath = Join-Path $DataDir 'config.json'
    if ($ResetConfig -or -not (Test-Path -LiteralPath $configPath)) {
        Copy-Item -LiteralPath $packageConfig -Destination $configPath -Force
        Write-Host "ElvisLab: configuracion creada en $configPath" -ForegroundColor Green
    } else {
        Write-Host "ElvisLab: se conserva la configuracion existente en $configPath" -ForegroundColor Gray
    }

    # Mantener solo la version actual y la anterior.
    $oldApps = @(Get-ChildItem -Path $DataDir -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $appDir } |
        Sort-Object LastWriteTime -Descending)
    $oldApps | Select-Object -Skip 1 | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    $appPath = Join-Path $appDir 'ElvisLab.ps1'

    $appArgs = @()
    if ($SelfTest) {
        $appArgs += '-SelfTest'
    } elseif ($Headless) {
        $appArgs += '-Headless'
    }
    if ($Install) { $appArgs += @('-Install', $Install) }
    if ($Tweaks) { $appArgs += @('-Tweaks', $Tweaks) }
    if ($NoTweaks) { $appArgs += '-NoTweaks' }
    if ($Shortcuts) { $appArgs += '-Shortcuts' }
    if ($DryRun) { $appArgs += '-DryRun' }
    if ($Backend) { $appArgs += @('-Backend', $Backend) }
    if ($ApplyOnly) { $appArgs += '-ApplyOnly' }
    if ($UndoTweaks) { $appArgs += '-UndoTweaks' }
    if ($Upgrade) { $appArgs += '-Upgrade' }
    if ($UpgradeAll) { $appArgs += '-UpgradeAll' }
    if ($WindowsUpdate) { $appArgs += '-WindowsUpdate' }
    if ($Uninstall) { $appArgs += '-Uninstall' }
    if (-not $SelfTest -and -not $Headless) { $appArgs += '-HideConsole' }
    $appArgs += @('-ConfigPath', $configPath)

    $quotedArgs = @()
    foreach ($arg in $appArgs) {
        if ($arg -match '\s') { $quotedArgs += ('"{0}"' -f $arg) } else { $quotedArgs += $arg }
    }
    $argString = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $appPath)) + $quotedArgs) -join ' '
    $isAdmin = Test-BootstrapAdmin

    if ($SelfTest) {
        Write-Host "ElvisLab: ejecutando SelfTest..." -ForegroundColor Cyan
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $appPath @appArgs
        $code = $LASTEXITCODE
        Write-Host "ElvisLab: SelfTest termino con codigo $code." -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Yellow' })
        $global:LASTEXITCODE = $code
        return
    }

    if ($Headless) {
        if ($isAdmin) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $appPath @appArgs
            $code = $LASTEXITCODE
        } else {
            try {
                $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -Verb RunAs -Wait -PassThru
                $code = $process.ExitCode
            } catch {
                Write-Host "ERROR: no se pudo elevar ElvisLab: $($_.Exception.Message)" -ForegroundColor Red
                return
            }
        }

        Write-Host "ElvisLab: operacion terminada con codigo $code." -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Yellow' })
        Write-Host "Registro: $env:LOCALAPPDATA\ElvisLab\logs" -ForegroundColor Gray
        $global:LASTEXITCODE = $code
        return
    }

    Write-Host "ElvisLab: iniciando interfaz desde $appDir" -ForegroundColor Cyan
    if ($isAdmin) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argString | Out-Null
    } else {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -Verb RunAs | Out-Null
    }
    Write-Host 'ElvisLab: listo.' -ForegroundColor Green
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
