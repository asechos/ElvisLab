# ============================================================================
# ElvisLab - Instalador de programas y ajustes para Windows
# ============================================================================
<#
.SYNOPSIS
    Descarga, verifica e instala programas de forma desatendida y crea accesos
    directos, aplicando ajustes opcionales del sistema.

.DESCRIPTION
    Interfaz grafica (por defecto) y modo desatendido (-Headless) para instalar
    los programas definidos en config.json. Cada instalador se verifica con
    SHA256 y/o firma digital antes de ejecutarse. El proceso se ejecuta en un
    proceso hijo para que la ventana no se bloquee y se pueda cancelar.

.PARAMETER ConfigPath
    Ruta al archivo de configuracion. Por defecto: config.json junto al script.

.PARAMETER Headless
    Ejecuta sin interfaz grafica.

.PARAMETER Install
    Lista de ids de programas separados por comas (solo -Headless).
    Si se omite, se instalan todos los definidos en config.json.

.PARAMETER Tweaks
    Lista de ids de tweaks separados por comas (solo -Headless).

.PARAMETER NoTweaks
    No aplica ningun tweak (solo -Headless).

.PARAMETER Shortcuts
    Crea los accesos directos despues de instalar (solo -Headless).

.PARAMETER DryRun
    Descarga y verifica los instaladores, pero no los ejecuta ni aplica tweaks.

.PARAMETER Backend
    Motor de instalacion: direct (instalador oficial verificado) o winget.

.PARAMETER ApplyOnly
    Solo aplica los tweaks seleccionados, sin instalar programas.

.PARAMETER UndoTweaks
    Deshace los tweaks seleccionados que lo permitan.

.PARAMETER Upgrade
    Actualiza con winget los programas seleccionados (o todos si no se indica -Install).

.PARAMETER Uninstall
    Desinstala con winget los programas seleccionados.

.PARAMETER Build
    Genera ElvisLab.exe con ps2exe y termina.

.PARAMETER SelfTest
    Comprueba configuracion, conectividad y estado del sistema sin instalar nada.

.EXAMPLE
    .\ElvisLab.ps1

.EXAMPLE
    .\ElvisLab.ps1 -Headless -Install python,git -Tweaks telemetry

.EXAMPLE
    .\ElvisLab.ps1 -Headless -NoTweaks -DryRun

.EXAMPLE
    .\ElvisLab.ps1 -SelfTest

.EXAMPLE
    .\ElvisLab.ps1 -Build
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$Headless,
    [string[]]$Install = @(),
    [string[]]$Tweaks = @(),
    [switch]$NoTweaks,
    [switch]$Shortcuts,
    [switch]$DryRun,
    [ValidateSet('direct', 'winget')]
    [string]$Backend = 'direct',
    [switch]$ApplyOnly,
    [switch]$UndoTweaks,
    [switch]$Upgrade,
    [switch]$Uninstall,
    [switch]$Build,
    [switch]$SelfTest,
    [string]$ProgressFile = '',
    [string]$CancelFile = '',
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Utilidades comunes
# ----------------------------------------------------------------------------

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Get-ScriptDirectory {
    try {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe) {
            $hostName = [System.IO.Path]::GetFileNameWithoutExtension($exe).ToLowerInvariant()
            if ($hostName -notin @('powershell', 'pwsh', 'powershell_ise')) {
                return (Split-Path -Parent $exe)
            }
        }
    } catch { }
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Get-Location).Path
}

$script:ScriptDir = Get-ScriptDirectory

try {
    $mainModule = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $hostName = [System.IO.Path]::GetFileNameWithoutExtension($mainModule).ToLowerInvariant()
    $script:IsCompiledExe = $hostName -notin @('powershell', 'pwsh')
} catch {
    $script:IsCompiledExe = $false
}
$script:ShowConsoleOutput = -not $script:IsCompiledExe

# ----------------------------------------------------------------------------
# Carga de modulos
# ----------------------------------------------------------------------------
# >>> ELVISLAB MODULES
$script:ModuleDir = Join-Path $script:ScriptDir 'modules'
$script:ModuleManifest = Join-Path $script:ModuleDir 'manifest.json'
if (-not (Test-Path -LiteralPath $script:ModuleManifest)) {
    throw "No se encontro el manifiesto de modulos: $script:ModuleManifest"
}
$script:ModuleFiles = @()
$moduleData = Get-Content -LiteralPath $script:ModuleManifest -Raw -Encoding UTF8 | ConvertFrom-Json
$script:ModuleFiles = @($moduleData)
foreach ($moduleFile in $script:ModuleFiles) {
    $modulePath = Join-Path $script:ModuleDir $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "No se encontro el modulo: $modulePath"
    }
    . $modulePath
}
# <<< ELVISLAB MODULES

$script:EntryScriptPath = $PSCommandPath
# ----------------------------------------------------------------------------
# Arranque
# ----------------------------------------------------------------------------

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $script:ScriptDir 'config.json'
}
$ConfigPath = Expand-ConfigPath $ConfigPath
try { $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath) } catch { }

if ($SelfTest) {
    try {
        $Config = Read-ConfigFile -Path $ConfigPath
    } catch {
        if ($script:ShowConsoleOutput) { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
        exit 1
    }
    New-LogFile -Config $Config
    exit (Invoke-SelfTest -Config $Config)
}

if ($Build) {
    try {
        $Config = Read-ConfigFile -Path $ConfigPath
    } catch {
        if ($script:ShowConsoleOutput) { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
        exit 1
    }
    New-LogFile -Config $Config
    exit (Invoke-BuildExe -Config $Config)
}

if (-not (Test-IsAdmin)) {
    if ($script:ShowConsoleOutput) { Write-Host 'Se requieren privilegios de Administrador. Solicitando elevacion...' -ForegroundColor Yellow }
    try {
        Start-ElevatedProcess
    } catch {
        if ($script:ShowConsoleOutput) { Write-Host "ERROR: no se pudo elevar el proceso: $($_.Exception.Message)" -ForegroundColor Red }
        exit 1
    }
    exit 0
}

try {
    $Config = Read-ConfigFile -Path $ConfigPath
} catch {
    if ($script:ShowConsoleOutput) { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
    exit 1
}

New-LogFile -Config $Config
Write-LogLine ("{0} {1} iniciado. Configuracion: {2}" -f $Config.appName, $Config.version, $ConfigPath) 'INFO'

if ($Headless) {
    exit (Invoke-HeadlessMain -Config $Config)
}

Show-Gui -Config $Config
exit 0
