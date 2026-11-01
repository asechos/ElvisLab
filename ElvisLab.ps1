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
    if ($PSScriptRoot) { return $PSScriptRoot }
    try {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe) { return (Split-Path -Parent $exe) }
    } catch { }
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

function Expand-ConfigPath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    try { $expanded = $ExecutionContext.InvokeCommand.ExpandString($expanded) } catch { }
    if ($expanded -eq '~') { return $HOME }
    if ($expanded.StartsWith('~\')) { return (Join-Path $HOME $expanded.Substring(2)) }
    return $expanded
}

function Resolve-LocalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $resolved = Expand-ConfigPath $Path
    # Rutas de proveedor de PowerShell (HKLM:, HKCU:, Registry::, etc.)
    if ($resolved -match '^[A-Za-z][A-Za-z0-9_]*:') { return $resolved }
    if ($resolved -and -not [System.IO.Path]::IsPathRooted($resolved)) {
        $resolved = Join-Path $script:ScriptDir $resolved
    }
    return $resolved
}

function ConvertTo-UndoSpec {
    param($Node)

    $action = 'remove'
    $value = $null
    $kind = 'DWord'

    if ($Node) {
        if ($Node.action) { $action = ([string]$Node.action).ToLowerInvariant() }
        if ($action -notin @('remove', 'set')) {
            throw "Accion de deshacer desconocida: $action"
        }
        $value = $Node.value
        if ($Node.kind) { $kind = [string]$Node.kind }
    }

    if ($kind -notin @('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord', 'None')) {
        throw "Tipo de valor de registro desconocido: $kind"
    }

    return [pscustomobject]@{
        action = $action
        value  = $value
        kind   = $kind
    }
}

function Convert-RegistryValue {
    param($Value, [string]$Kind)

    switch ($Kind) {
        'DWord' { return [int]$Value }
        'QWord' { return [long]$Value }
        'String' { return [string]$Value }
        'ExpandString' { return [string]$Value }
        default { return $Value }
    }
}

function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ----------------------------------------------------------------------------
# Registro de actividades
# ----------------------------------------------------------------------------

function New-LogFile {
    param($Config)

    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        $script:LogFile = Resolve-LocalPath $LogFile
    } else {
        $logDir = ''
        if ($Config -and $Config.logDirectory) {
            $logDir = Resolve-LocalPath $Config.logDirectory
        }
        if (-not $logDir) {
            $logDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ElvisLab\logs'
        }
        try {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        } catch {
            $logDir = Join-Path $env:TEMP 'ElvisLab\logs'
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $script:LogFile = Join-Path $logDir ('ElvisLab_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }

    $parent = Split-Path -Parent $script:LogFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:LogFile)) {
        [System.IO.File]::WriteAllText($script:LogFile, '', $script:Utf8NoBom)
    }
}

function Write-LogLine {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    if ($script:LogFile) {
        try {
            [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", $script:Utf8NoBom)
        } catch { }
    }
    $color = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    if ($script:ShowConsoleOutput) {
        Write-Host $line -ForegroundColor $color
    }
}

# ----------------------------------------------------------------------------
# Configuracion
# ----------------------------------------------------------------------------

function Read-ConfigFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "No se encontro el archivo de configuracion: $Path"
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    } catch {
        throw "No se pudo leer el archivo de configuracion: $($_.Exception.Message)"
    }

    try {
        $data = $raw | ConvertFrom-Json
    } catch {
        throw "config.json no es un JSON valido: $($_.Exception.Message)"
    }

    if ($null -eq $data) { throw 'config.json esta vacio.' }

    $appName = if ($data.appName) { [string]$data.appName } else { 'ElvisLab' }
    $version = if ($data.version) { [string]$data.version } else { '0.0.0' }
    $logDirectory = if ($data.logDirectory) { [string]$data.logDirectory } else { '' }

    $files = @()
    $fileIds = @{}
    $fileIndex = 0

    foreach ($entry in @($data.files)) {
        $fileIndex++
        if ($null -eq $entry) { continue }

        $source = [string]$entry.source
        $destination = [string]$entry.destination
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($destination)) {
            throw "La entrada de 'files' #$fileIndex no tiene 'source' o 'destination'."
        }
        if ($source -notmatch '^https://') {
            throw "El origen de '$destination' debe usar HTTPS."
        }
        if ([System.IO.Path]::GetFileName($destination) -ne $destination) {
            throw "El 'destination' de '$source' debe ser solo un nombre de archivo."
        }

        $id = if ($entry.id) { ([string]$entry.id).Trim() } else { [System.IO.Path]::GetFileNameWithoutExtension($destination) }
        if (-not $id) { throw "La entrada de 'files' #$fileIndex no tiene un id valido." }
        $key = $id.ToLowerInvariant()
        if ($fileIds.ContainsKey($key)) { throw "Id de programa duplicado: $id" }
        $fileIds[$key] = $true

        $sha256 = ([string]$entry.sha256).Trim().ToUpperInvariant()
        if ($sha256 -and $sha256 -notmatch '^[A-F0-9]{64}$') {
            throw "El sha256 de '$id' no tiene 64 caracteres hexadecimales."
        }

        $publisher = ([string]$entry.publisher).Trim()

        $timeout = if ($entry.installTimeoutSec) { [int]$entry.installTimeoutSec } else { 900 }
        if ($timeout -lt 30) { $timeout = 30 }

        $downloadTimeout = if ($entry.downloadTimeoutSec) { [int]$entry.downloadTimeoutSec } else { 600 }
        if ($downloadTimeout -lt 30) { $downloadTimeout = 30 }

        $successCodes = @()
        foreach ($code in @($entry.successExitCodes)) {
            if ($null -ne $code -and "$code" -ne '') { $successCodes += [int]$code }
        }
        if ($successCodes.Count -eq 0) { $successCodes = @(0, 3010, 1641) }

        $alternatePaths = @()
        foreach ($alt in @($entry.alternatePaths)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$alt)) { $alternatePaths += [string]$alt }
        }

        $files += [pscustomobject]@{
            id                = $id
            name              = if ($entry.name) { [string]$entry.name } else { $id }
            wingetId          = [string]$entry.wingetId
            category          = if ($entry.category) { [string]$entry.category } else { 'Programas' }
            badgeText         = if ($entry.badgeText) { [string]$entry.badgeText } else { '' }
            badgeColor        = if ($entry.badgeColor) { [string]$entry.badgeColor } else { '' }
            icon              = [string]$entry.icon
            source            = $source
            destination       = $destination
            sha256            = $sha256
            publisher         = $publisher
            allowUnverified   = [bool]$entry.allowUnverified
            installArgs       = [string]$entry.installArgs
            installTimeoutSec = $timeout
            downloadTimeoutSec = $downloadTimeout
            successExitCodes  = $successCodes
            installedPath     = [string]$entry.installedPath
            alternatePaths    = $alternatePaths
        }
    }

    $tweaks = @()
    $tweakIds = @{}
    $tweakIndex = 0

    foreach ($entry in @($data.tweaks)) {
        $tweakIndex++
        if ($null -eq $entry) { continue }

        $id = if ($entry.id) { ([string]$entry.id).Trim() } else { "tweak$tweakIndex" }
        $key = $id.ToLowerInvariant()
        if ($tweakIds.ContainsKey($key)) { throw "Id de tweak duplicado: $id" }
        $tweakIds[$key] = $true

        $type = if ($entry.type) { ([string]$entry.type).ToLowerInvariant() } else { 'registry' }
        if ($type -notin @('registry', 'restorepoint', 'service', 'hibernation')) {
            throw "El tweak '$id' tiene un tipo desconocido: $type"
        }

        $enabled = if ($null -eq $entry.enabled) { $true } else { [bool]$entry.enabled }
        $category = if ($entry.category) { [string]$entry.category } else { 'Ajustes' }

        $values = @()
        if ($type -eq 'registry') {
            $rawValues = @($entry.values | Where-Object { $null -ne $_ })
            if ($rawValues.Count -gt 0) {
                foreach ($raw in $rawValues) {
                    $valuePath = if ($raw.path) { [string]$raw.path } else { [string]$entry.path }
                    $valueName = [string]$raw.valueName
                    if ([string]::IsNullOrWhiteSpace($valuePath)) { throw "El tweak '$id' tiene un valor sin 'path'." }
                    if ([string]::IsNullOrWhiteSpace($valueName)) { throw "El tweak '$id' tiene un valor sin 'valueName'." }

                    $valueKind = if ($raw.kind) { [string]$raw.kind } else { 'DWord' }
                    if ($valueKind -notin @('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord', 'None')) {
                        throw "El tweak '$id' tiene un tipo de valor de registro desconocido: $valueKind"
                    }

                    $undo = ConvertTo-UndoSpec -Node $raw.undo
                    $values += [pscustomobject]@{
                        path       = $valuePath
                        valueName  = $valueName
                        value      = $raw.value
                        kind       = $valueKind
                        undoAction = $undo.action
                        undoValue  = $undo.value
                        undoKind   = $undo.kind
                    }
                }
            } else {
                if ([string]::IsNullOrWhiteSpace([string]$entry.path)) { throw "El tweak '$id' no tiene 'path'." }
                if ([string]::IsNullOrWhiteSpace([string]$entry.valueName)) { throw "El tweak '$id' no tiene 'valueName'." }

                $valueKind = if ($entry.kind) { [string]$entry.kind } else { 'DWord' }
                if ($valueKind -notin @('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord', 'None')) {
                    throw "El tweak '$id' tiene un tipo de valor de registro desconocido: $valueKind"
                }

                $undo = ConvertTo-UndoSpec -Node $entry.undo
                $values += [pscustomobject]@{
                    path       = [string]$entry.path
                    valueName  = [string]$entry.valueName
                    value      = $entry.value
                    kind       = $valueKind
                    undoAction = $undo.action
                    undoValue  = $undo.value
                    undoKind   = $undo.kind
                }
            }
        }

        $serviceName = ''
        $startupType = ''
        $stopService = $false
        $undoStartupType = ''
        $undoStartService = $false
        $hibernationAction = 'disable'

        if ($type -eq 'service') {
            $serviceName = [string]$entry.serviceName
            if ([string]::IsNullOrWhiteSpace($serviceName)) { throw "El tweak '$id' no tiene 'serviceName'." }

            $startupType = if ($entry.startupType) { [string]$entry.startupType } else { 'Disabled' }
            if ($startupType -notin @('Automatic', 'Manual', 'Disabled')) {
                throw "El tweak '$id' tiene un 'startupType' no valido: $startupType"
            }

            $stopService = if ($null -eq $entry.stopService) { $true } else { [bool]$entry.stopService }

            $undoStartupType = if ($entry.undoStartupType) { [string]$entry.undoStartupType } else { 'Automatic' }
            if ($undoStartupType -notin @('Automatic', 'Manual', 'Disabled')) {
                throw "El tweak '$id' tiene un 'undoStartupType' no valido: $undoStartupType"
            }

            $undoStartService = if ($null -eq $entry.undoStartService) { $true } else { [bool]$entry.undoStartService }
        }

        if ($type -eq 'hibernation') {
            $hibernationAction = if ($entry.action) { ([string]$entry.action).ToLowerInvariant() } else { 'disable' }
            if ($hibernationAction -notin @('disable', 'enable')) {
                throw "El tweak '$id' tiene una accion de hibernacion no valida: $hibernationAction"
            }
        }

        $tweaks += [pscustomobject]@{
            id                = $id
            name              = if ($entry.name) { [string]$entry.name } else { $id }
            type              = $type
            category          = $category
            enabled           = $enabled
            description       = [string]$entry.description
            values            = $values
            serviceName       = $serviceName
            startupType       = $startupType
            stopService       = $stopService
            undoStartupType   = $undoStartupType
            undoStartService  = $undoStartService
            hibernationAction = $hibernationAction
        }
    }

    $shortcuts = @()
    $shortcutIndex = 0

    foreach ($entry in @($data.shortcuts)) {
        $shortcutIndex++
        if ($null -eq $entry) { continue }

        $fileId = [string]$entry.fileId
        $target = [string]$entry.target
        if ([string]::IsNullOrWhiteSpace($fileId) -and [string]::IsNullOrWhiteSpace($target)) {
            throw "El acceso directo #$shortcutIndex no tiene 'fileId' ni 'target'."
        }
        if ($fileId) {
            $lookup = $fileId.ToLowerInvariant()
            if (-not $fileIds.ContainsKey($lookup)) {
                throw "El acceso directo '$fileId' apunta a un programa que no existe en 'files'."
            }
        }

        $name = if ($entry.name) { [string]$entry.name } else { if ($fileId) { $fileId } else { "Acceso $shortcutIndex" } }
        $fileName = if ($entry.fileName) { [string]$entry.fileName } else { "$name.lnk" }
        if (-not $fileName.ToLowerInvariant().EndsWith('.lnk')) { $fileName = "$fileName.lnk" }
        if ([System.IO.Path]::GetFileName($fileName) -ne $fileName) {
            throw "El 'fileName' del acceso '$name' debe ser solo un nombre de archivo."
        }

        $location = if ($entry.location) { [string]$entry.location } else { 'Desktop' }

        $shortcuts += [pscustomobject]@{
            name        = $name
            fileName    = $fileName
            location    = $location
            fileId      = $fileId
            target      = $target
            arguments   = [string]$entry.arguments
            description = [string]$entry.description
            icon        = [string]$entry.icon
        }
    }

    return [pscustomobject]@{
        appName      = $appName
        version      = $version
        logDirectory = $logDirectory
        files        = $files
        tweaks       = $tweaks
        shortcuts    = $shortcuts
    }
}

function Resolve-InstalledPath {
    param($File)

    if ($null -eq $File) { return '' }

    $candidates = @()
    if ($File.installedPath) { $candidates += (Resolve-LocalPath $File.installedPath) }
    foreach ($alt in @($File.alternatePaths)) {
        if ($alt) { $candidates += (Resolve-LocalPath $alt) }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    return ''
}

# ----------------------------------------------------------------------------
# Descarga, integridad e instalacion
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# Tweaks
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# Accesos directos
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# Progreso del modo headless (archivo JSON que lee la interfaz grafica)
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# Seleccion de elementos
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# Modo headless
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# Interfaz grafica
# ----------------------------------------------------------------------------

function Initialize-UiTypes {
    if ('ElvisCardsView' -as [type]) { return }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $code = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;

public class ElvisProgram
{
    public string Id;
    public string Name;
    public string Category;
    public string BadgeText;
    public Color BadgeColor = Color.FromArgb(88, 101, 242);
    public Image Icon;
    public bool Selected;
    public bool Installed;
    public string Status;
    public int StatusKind;
}

public class ElvisCardsView : ScrollableControl
{
    private List<ElvisProgram> programs = new List<ElvisProgram>();
    private Dictionary<string, Rectangle> cardRects = new Dictionary<string, Rectangle>();
    private Dictionary<string, Rectangle> headerRects = new Dictionary<string, Rectangle>();
    private HashSet<string> collapsed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    private bool layoutDirty = true;
    private string hoverCard = null;
    private string hoverHeader = null;
    private string filterText = "";
    private bool installedOnly = false;
    private Font titleFont;
    private Font detailFont;
    private Font headerFont;
    private Font badgeFont;

    public event EventHandler SelectionChanged;

    public ElvisCardsView()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.FromArgb(30, 31, 34);
        AutoScroll = true;
        titleFont = new Font("Segoe UI", 11f, FontStyle.Regular);
        detailFont = new Font("Segoe UI", 9.5f, FontStyle.Regular);
        headerFont = new Font("Segoe UI", 11.5f, FontStyle.Bold);
        badgeFont = new Font("Segoe UI", 9.5f, FontStyle.Bold);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            if (titleFont != null) { titleFont.Dispose(); }
            if (detailFont != null) { detailFont.Dispose(); }
            if (headerFont != null) { headerFont.Dispose(); }
            if (badgeFont != null) { badgeFont.Dispose(); }
        }
        base.Dispose(disposing);
    }

    public int SelectedCount
    {
        get
        {
            int count = 0;
            for (int i = 0; i < programs.Count; i++)
            {
                if (programs[i].Selected) { count++; }
            }
            return count;
        }
    }

    public void SetPrograms(List<ElvisProgram> items)
    {
        programs = items == null ? new List<ElvisProgram>() : items;
        layoutDirty = true;
        Invalidate();
    }

    public void SetFilter(string text)
    {
        filterText = text == null ? "" : text.Trim();
        layoutDirty = true;
        Invalidate();
    }

    public void SetInstalledOnly(bool value)
    {
        installedOnly = value;
        layoutDirty = true;
        Invalidate();
    }

    public string[] GetSelectedIds()
    {
        return programs.Where(p => p.Selected).Select(p => p.Id).ToArray();
    }

    public void SelectAll()
    {
        for (int i = 0; i < programs.Count; i++) { programs[i].Selected = true; }
        Invalidate();
        RaiseSelectionChanged();
    }

    public void ClearSelection()
    {
        for (int i = 0; i < programs.Count; i++) { programs[i].Selected = false; }
        Invalidate();
        RaiseSelectionChanged();
    }

    public void ExpandAll()
    {
        collapsed.Clear();
        layoutDirty = true;
        Invalidate();
    }

    public void CollapseAll()
    {
        collapsed.Clear();
        foreach (var group in programs.GroupBy(p => CategoryOf(p))) { collapsed.Add(group.Key); }
        layoutDirty = true;
        Invalidate();
    }

    public void SetStatus(string id, string status, int kind)
    {
        ElvisProgram target = programs.FirstOrDefault(p => string.Equals(p.Id, id, StringComparison.OrdinalIgnoreCase));
        if (target == null) { return; }
        target.Status = status;
        target.StatusKind = kind;
        Invalidate();
    }

    private void RaiseSelectionChanged()
    {
        if (SelectionChanged != null) { SelectionChanged(this, EventArgs.Empty); }
    }

    private static string CategoryOf(ElvisProgram p)
    {
        return string.IsNullOrEmpty(p.Category) ? "Programas" : p.Category;
    }

    private bool Matches(ElvisProgram p)
    {
        if (installedOnly && !p.Installed) { return false; }
        if (string.IsNullOrEmpty(filterText)) { return true; }
        string needle = filterText.ToLowerInvariant();
        if (p.Name != null && p.Name.ToLowerInvariant().Contains(needle)) { return true; }
        if (p.Category != null && p.Category.ToLowerInvariant().Contains(needle)) { return true; }
        return false;
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        layoutDirty = true;
        Invalidate();
    }

    private void EnsureLayout()
    {
        if (!layoutDirty) { return; }
        layoutDirty = false;
        cardRects.Clear();
        headerRects.Clear();

        int pad = 18;
        int cardW = 180;
        int cardH = 50;
        int gap = 10;
        int headerH = 34;
        int sectionGap = 14;

        int available = ClientSize.Width - (pad * 2);
        int columns = Math.Max(1, (available + gap) / (cardW + gap));
        int y = pad;

        foreach (var group in programs.Where(p => Matches(p)).GroupBy(p => CategoryOf(p)))
        {
            headerRects[group.Key] = new Rectangle(pad, y, available, 28);
            y += headerH;

            if (!collapsed.Contains(group.Key))
            {
                int col = 0;
                foreach (var p in group)
                {
                    int x = pad + (col * (cardW + gap));
                    cardRects[p.Id] = new Rectangle(x, y, cardW, cardH);
                    col++;
                    if (col >= columns)
                    {
                        col = 0;
                        y += cardH + gap;
                    }
                }
                if (col != 0) { y += cardH + gap; }
            }
            y += sectionGap;
        }

        Size desired = new Size(0, y + pad);
        if (AutoScrollMinSize != desired) { AutoScrollMinSize = desired; }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        EnsureLayout();
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        g.Clear(BackColor);

        int scroll = AutoScrollPosition.Y;

        foreach (var entry in headerRects)
        {
            Rectangle rect = entry.Value;
            rect.Offset(0, scroll);
            DrawHeader(g, entry.Key, rect);
        }

        foreach (var entry in cardRects)
        {
            ElvisProgram program = programs.FirstOrDefault(p => p.Id == entry.Key);
            if (program == null) { continue; }
            Rectangle rect = entry.Value;
            rect.Offset(0, scroll);
            DrawCard(g, program, rect);
        }
    }

    private void DrawHeader(Graphics g, string text, Rectangle rect)
    {
        bool isCollapsed = collapsed.Contains(text);
        Color accent = Color.FromArgb(90, 169, 230);

        using (SolidBrush brush = new SolidBrush(accent))
        {
            g.DrawString(text, headerFont, brush, rect.X, rect.Y + 2);
        }

        SizeF size = g.MeasureString(text, headerFont);
        int lineX = rect.X + (int)size.Width + 10;
        using (Pen pen = new Pen(Color.FromArgb(58, 60, 65)))
        {
            g.DrawLine(pen, lineX, rect.Y + 14, rect.Right - 24, rect.Y + 14);
        }

        using (Pen pen = new Pen(Color.FromArgb(140, 143, 148), 1.6f))
        {
            PointF[] points;
            if (isCollapsed)
            {
                points = new PointF[]
                {
                    new PointF(rect.Right - 17, rect.Y + 7),
                    new PointF(rect.Right - 11, rect.Y + 13),
                    new PointF(rect.Right - 17, rect.Y + 19)
                };
            }
            else
            {
                points = new PointF[]
                {
                    new PointF(rect.Right - 20, rect.Y + 9),
                    new PointF(rect.Right - 13, rect.Y + 16),
                    new PointF(rect.Right - 6, rect.Y + 9)
                };
            }
            g.DrawLines(pen, points);
        }
    }

    private void DrawCard(Graphics g, ElvisProgram program, Rectangle rect)
    {
        bool hover = string.Equals(hoverCard, program.Id, StringComparison.OrdinalIgnoreCase);

        Color background = hover ? Color.FromArgb(53, 55, 60) : Color.FromArgb(43, 45, 49);
        Color border = program.Selected
            ? Color.FromArgb(59, 165, 93)
            : (hover ? Color.FromArgb(74, 76, 82) : Color.FromArgb(58, 59, 64));

        using (GraphicsPath path = RoundedRect(rect, 6))
        {
            using (SolidBrush brush = new SolidBrush(background))
            {
                g.FillPath(brush, path);
            }
            using (Pen pen = new Pen(border, program.Selected ? 1.6f : 1f))
            {
                g.DrawPath(pen, path);
            }
        }

        Rectangle badge = new Rectangle(rect.X + 8, rect.Y + ((rect.Height - 30) / 2), 30, 30);
        if (program.Icon != null)
        {
            g.DrawImage(program.Icon, badge);
        }
        else
        {
            using (GraphicsPath path = RoundedRect(badge, 5))
            {
                using (SolidBrush brush = new SolidBrush(program.BadgeColor))
                {
                    g.FillPath(brush, path);
                }
            }
            string badgeText = string.IsNullOrEmpty(program.BadgeText) ? "?" : program.BadgeText;
            using (SolidBrush brush = new SolidBrush(Color.White))
            using (StringFormat format = new StringFormat())
            {
                format.Alignment = StringAlignment.Center;
                format.LineAlignment = StringAlignment.Center;
                g.DrawString(badgeText, badgeFont, brush, badge, format);
            }
        }

        int textX = rect.X + 46;
        int textRight = rect.Right - 28;

        Rectangle titleRect = new Rectangle(textX, rect.Y + 5, textRight - textX, 22);
        TextRenderer.DrawText(
            g,
            program.Name,
            titleFont,
            titleRect,
            Color.FromArgb(227, 229, 232),
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);

        string status = program.Status;
        if (string.IsNullOrEmpty(status)) { status = program.Installed ? "Instalado" : "No instalado"; }

        Color statusColor = Color.FromArgb(154, 160, 166);
        if (program.StatusKind == 1) { statusColor = Color.FromArgb(59, 165, 93); }
        else if (program.StatusKind == 2) { statusColor = Color.FromArgb(237, 66, 69); }
        else if (program.StatusKind == 3) { statusColor = Color.FromArgb(230, 160, 40); }
        else if (program.Installed) { statusColor = Color.FromArgb(59, 165, 93); }

        Rectangle detailRect = new Rectangle(textX, rect.Y + 27, textRight - textX, 18);
        TextRenderer.DrawText(
            g,
            status,
            detailFont,
            detailRect,
            statusColor,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);

        int cx = rect.Right - 15;
        int cy = rect.Y + (rect.Height / 2);
        int radius = 9;

        if (program.Selected)
        {
            using (SolidBrush brush = new SolidBrush(Color.FromArgb(59, 165, 93)))
            {
                g.FillEllipse(brush, cx - radius, cy - radius, radius * 2, radius * 2);
            }
            using (Pen pen = new Pen(Color.White, 1.8f))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                g.DrawLines(pen, new PointF[]
                {
                    new PointF(cx - 4, cy),
                    new PointF(cx - 1, cy + 3),
                    new PointF(cx + 4, cy - 3)
                });
            }
        }
        else
        {
            Color ring = hover ? Color.FromArgb(120, 124, 130) : Color.FromArgb(92, 95, 102);
            using (Pen pen = new Pen(ring, 1.4f))
            {
                g.DrawEllipse(pen, cx - radius, cy - radius, radius * 2, radius * 2);
            }
        }
    }

    private static GraphicsPath RoundedRect(Rectangle rect, int radius)
    {
        GraphicsPath path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        EnsureLayout();

        Point content = new Point(e.X - AutoScrollPosition.X, e.Y - AutoScrollPosition.Y);
        string newCard = null;
        string newHeader = null;

        foreach (var entry in cardRects)
        {
            if (entry.Value.Contains(content)) { newCard = entry.Key; break; }
        }
        if (newCard == null)
        {
            foreach (var entry in headerRects)
            {
                if (entry.Value.Contains(content)) { newHeader = entry.Key; break; }
            }
        }

        if (newCard != hoverCard || newHeader != hoverHeader)
        {
            hoverCard = newCard;
            hoverHeader = newHeader;
            Cursor = (newCard != null || newHeader != null) ? Cursors.Hand : Cursors.Default;
            Invalidate();
        }
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (hoverCard != null || hoverHeader != null)
        {
            hoverCard = null;
            hoverHeader = null;
            Cursor = Cursors.Default;
            Invalidate();
        }
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        EnsureLayout();

        Point content = new Point(e.X - AutoScrollPosition.X, e.Y - AutoScrollPosition.Y);

        foreach (var entry in cardRects)
        {
            if (entry.Value.Contains(content))
            {
                ElvisProgram program = programs.FirstOrDefault(p => p.Id == entry.Key);
                if (program != null)
                {
                    program.Selected = !program.Selected;
                    Invalidate();
                    RaiseSelectionChanged();
                }
                return;
            }
        }

        foreach (var entry in headerRects)
        {
            if (entry.Value.Contains(content))
            {
                if (collapsed.Contains(entry.Key)) { collapsed.Remove(entry.Key); }
                else { collapsed.Add(entry.Key); }
                layoutDirty = true;
                Invalidate();
                return;
            }
        }
    }
}
'@

    $references = @()
    try { $references += [System.Windows.Forms.Form].Assembly.Location } catch { }
    try { $references += [System.Drawing.Bitmap].Assembly.Location } catch { }
    try { $references += [System.Linq.Enumerable].Assembly.Location } catch { }

    Add-Type -TypeDefinition $code -ReferencedAssemblies $references -Language CSharp
}

function Load-UiImage {
    param([string]$Path)

    try {
        if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.ico') {
            $icon = New-Object System.Drawing.Icon -ArgumentList $Path
            return $icon.ToBitmap()
        }

        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $stream = New-Object System.IO.MemoryStream
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Position = 0
        return [System.Drawing.Image]::FromStream($stream)
    } catch {
        return $null
    }
}

function Get-UiProgramIcon {
    param($File)

    if ($File.icon) {
        $iconPath = Resolve-LocalPath $File.icon
        if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
            $image = Load-UiImage -Path $iconPath
            if ($image) { return $image }
        }
    }

    $installed = Resolve-InstalledPath -File $File
    if ($installed) {
        try {
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($installed)
            if ($icon) { return $icon.ToBitmap() }
        } catch { }
    }
    return $null
}

function Get-UiBadgeColor {
    param($File)

    $value = [string]$File.badgeColor
    if ($value -match '^#[0-9A-Fa-f]{6}$') {
        try { return [System.Drawing.ColorTranslator]::FromHtml($value) } catch { }
    }

    $palette = @{
        'python'    = '#3776AB'
        'notepadpp' = '#3E9A2E'
        '7zip'      = '#1E88E5'
        'git'       = '#F05033'
        'vlc'       = '#FF7A00'
    }
    $key = ([string]$File.id).ToLowerInvariant()
    if ($palette.ContainsKey($key)) {
        return [System.Drawing.ColorTranslator]::FromHtml($palette[$key])
    }
    return [System.Drawing.Color]::FromArgb(88, 101, 242)
}

function Build-ProgramModels {
    param(
        $Config,
        [string[]]$SelectedIds = @(),
        [hashtable]$StatusMap = @{}
    )

    $models = New-Object 'System.Collections.Generic.List[ElvisProgram]'

    foreach ($file in @($Config.files)) {
        $model = New-Object ElvisProgram
        $model.Id = $file.id
        $model.Name = $file.name
        $model.Category = $file.category
        $model.BadgeText = $file.badgeText
        $model.BadgeColor = Get-UiBadgeColor -File $file
        $model.Icon = Get-UiProgramIcon -File $file
        $model.Selected = ($SelectedIds -contains $file.id)
        $model.Installed = [bool](Resolve-InstalledPath -File $file)

        if ($StatusMap -and $StatusMap.ContainsKey($file.id)) {
            $model.Status = [string]$StatusMap[$file.id].Text
            $model.StatusKind = [int]$StatusMap[$file.id].Kind
        } else {
            $model.Status = if ($model.Installed) { 'Instalado' } else { 'No instalado' }
            $model.StatusKind = if ($model.Installed) { 1 } else { 0 }
        }

        $models.Add($model)
    }

    return ,$models
}

function Show-Gui {
    param($Config)

    Initialize-UiTypes
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $colors = @{
        window      = [System.Drawing.Color]::FromArgb(30, 31, 34)
        topBar      = [System.Drawing.Color]::FromArgb(24, 25, 28)
        sideBar     = [System.Drawing.Color]::FromArgb(36, 37, 40)
        panel       = [System.Drawing.Color]::FromArgb(43, 45, 49)
        border      = [System.Drawing.Color]::FromArgb(47, 49, 54)
        text        = [System.Drawing.Color]::FromArgb(227, 229, 232)
        muted       = [System.Drawing.Color]::FromArgb(154, 160, 166)
        accent      = [System.Drawing.Color]::FromArgb(47, 111, 208)
        accentHover = [System.Drawing.Color]::FromArgb(59, 127, 224)
        green       = [System.Drawing.Color]::FromArgb(59, 165, 93)
        red         = [System.Drawing.Color]::FromArgb(179, 59, 59)
    }

    $script:IsInstalling = $false
    $script:InstalledOnly = $false
    $script:Backend = 'direct'
    $script:InstallProcess = $null
    $script:ProgramStatus = @{}
    $script:TweakChecks = @{}
    $script:TweakModels = @{}

    function New-FlatButton {
        param(
            [string]$Text,
            [int]$X,
            [int]$Y,
            [int]$Width = 190,
            [int]$Height = 34,
            [switch]$Primary
        )

        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Location = New-Object System.Drawing.Point($X, $Y)
        $button.Size = New-Object System.Drawing.Size($Width, $Height)
        $button.FlatStyle = 'Flat'
        $button.FlatAppearance.BorderSize = 0
        $button.Cursor = 'Hand'

        if ($Primary) {
            $button.BackColor = $colors.accent
            $button.ForeColor = [System.Drawing.Color]::White
            $button.Font = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
            $button.FlatAppearance.MouseOverBackColor = $colors.accentHover
            $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(37, 90, 168)
        } else {
            $button.BackColor = $colors.panel
            $button.ForeColor = $colors.text
            $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(53, 55, 60)
            $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(58, 60, 66)
        }

        return $button
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '{0} {1}' -f $Config.appName, $Config.version
    $form.ClientSize = New-Object System.Drawing.Size(1000, 640)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $form.BackColor = $colors.window

    $iconPath = Join-Path $script:ScriptDir 'Resources\ElvisLab.ico'
    if (Test-Path -LiteralPath $iconPath) {
        try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
    }

    $mainHost = New-Object System.Windows.Forms.Panel
    $mainHost.Location = New-Object System.Drawing.Point(204, 50)
    $mainHost.Size = New-Object System.Drawing.Size(796, 546)
    $mainHost.BackColor = $colors.window
    $form.Controls.Add($mainHost)

    # --- Barra superior ------------------------------------------------------
    $topBar = New-Object System.Windows.Forms.Panel
    $topBar.Location = New-Object System.Drawing.Point(0, 0)
    $topBar.Size = New-Object System.Drawing.Size(1000, 50)
    $topBar.BackColor = $colors.topBar
    $form.Controls.Add($topBar)

    $topBorder = New-Object System.Windows.Forms.Panel
    $topBorder.Dock = 'Bottom'
    $topBorder.Height = 1
    $topBorder.BackColor = $colors.border
    $topBar.Controls.Add($topBorder)

    $lblBrand = New-Object System.Windows.Forms.Label
    $lblBrand.Text = $Config.appName
    $lblBrand.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblBrand.ForeColor = $colors.text
    $lblBrand.Location = New-Object System.Drawing.Point(16, 10)
    $lblBrand.Size = New-Object System.Drawing.Size(130, 28)
    $topBar.Controls.Add($lblBrand)

    $brandLine = New-Object System.Windows.Forms.Panel
    $brandLine.Location = New-Object System.Drawing.Point(18, 37)
    $brandLine.Size = New-Object System.Drawing.Size(112, 3)
    $brandLine.BackColor = $colors.accent
    $topBar.Controls.Add($brandLine)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(730, 13)
    $txtSearch.Size = New-Object System.Drawing.Size(254, 24)
    $txtSearch.BackColor = $colors.panel
    $txtSearch.ForeColor = $colors.muted
    $txtSearch.BorderStyle = 'FixedSingle'
    $txtSearch.Text = 'Buscar programas...'
    $topBar.Controls.Add($txtSearch)

    $btnBackendDirect = New-Object System.Windows.Forms.Button
    $btnBackendDirect.Text = 'Directo'
    $btnBackendDirect.Location = New-Object System.Drawing.Point(612, 10)
    $btnBackendDirect.Size = New-Object System.Drawing.Size(58, 30)
    $btnBackendDirect.FlatStyle = 'Flat'
    $btnBackendDirect.FlatAppearance.BorderSize = 0
    $btnBackendDirect.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $btnBackendDirect.Cursor = 'Hand'
    $topBar.Controls.Add($btnBackendDirect)

    $btnBackendWinget = New-Object System.Windows.Forms.Button
    $btnBackendWinget.Text = 'Winget'
    $btnBackendWinget.Location = New-Object System.Drawing.Point(672, 10)
    $btnBackendWinget.Size = New-Object System.Drawing.Size(56, 30)
    $btnBackendWinget.FlatStyle = 'Flat'
    $btnBackendWinget.FlatAppearance.BorderSize = 0
    $btnBackendWinget.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $btnBackendWinget.Cursor = 'Hand'
    $topBar.Controls.Add($btnBackendWinget)

    $backendTip = New-Object System.Windows.Forms.ToolTip
    $backendTip.SetToolTip($btnBackendDirect, 'Instaladores oficiales verificados con SHA256 y/o firma digital.')
    $backendTip.SetToolTip($btnBackendWinget, 'Windows Package Manager: instala y actualiza desde el catalogo de winget.')

    # --- Panel lateral -------------------------------------------------------
    $sideBar = New-Object System.Windows.Forms.Panel
    $sideBar.Location = New-Object System.Drawing.Point(0, 50)
    $sideBar.Size = New-Object System.Drawing.Size(204, 546)
    $sideBar.BackColor = $colors.sideBar
    $form.Controls.Add($sideBar)

    $sideBorder = New-Object System.Windows.Forms.Panel
    $sideBorder.Dock = 'Right'
    $sideBorder.Width = 1
    $sideBorder.BackColor = $colors.border
    $sideBar.Controls.Add($sideBorder)

    # --- Barra de estado -----------------------------------------------------
    $statusBar = New-Object System.Windows.Forms.Panel
    $statusBar.Location = New-Object System.Drawing.Point(0, 596)
    $statusBar.Size = New-Object System.Drawing.Size(1000, 44)
    $statusBar.BackColor = $colors.topBar
    $form.Controls.Add($statusBar)

    $statusBorder = New-Object System.Windows.Forms.Panel
    $statusBorder.Dock = 'Top'
    $statusBorder.Height = 1
    $statusBorder.BackColor = $colors.border
    $statusBar.Controls.Add($statusBorder)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(16, 13)
    $lblStatus.Size = New-Object System.Drawing.Size(424, 20)
    $lblStatus.ForeColor = $colors.text
    $lblStatus.AutoEllipsis = $true
    $lblStatus.Text = 'Listo.'
    $statusBar.Controls.Add($lblStatus)

    $progressTrack = New-Object System.Windows.Forms.Panel
    $progressTrack.Location = New-Object System.Drawing.Point(452, 18)
    $progressTrack.Size = New-Object System.Drawing.Size(300, 8)
    $progressTrack.BackColor = $colors.panel
    $statusBar.Controls.Add($progressTrack)

    $progressFill = New-Object System.Windows.Forms.Panel
    $progressFill.Location = New-Object System.Drawing.Point(0, 0)
    $progressFill.Size = New-Object System.Drawing.Size(0, 8)
    $progressFill.BackColor = $colors.green
    $progressTrack.Controls.Add($progressFill)

    $lblPercent = New-Object System.Windows.Forms.Label
    $lblPercent.Location = New-Object System.Drawing.Point(760, 12)
    $lblPercent.Size = New-Object System.Drawing.Size(52, 20)
    $lblPercent.ForeColor = $colors.muted
    $lblPercent.Text = '0%'
    $statusBar.Controls.Add($lblPercent)

    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Text = 'v' + $Config.version
    $lblVersion.Location = New-Object System.Drawing.Point(916, 13)
    $lblVersion.Size = New-Object System.Drawing.Size(68, 20)
    $lblVersion.TextAlign = 'MiddleRight'
    $lblVersion.ForeColor = $colors.muted
    $statusBar.Controls.Add($lblVersion)

    # --- Contenido por pestanas ----------------------------------------------
    $tabPanels = @{}
    foreach ($tabId in @('install', 'tweaks', 'updates', 'log', 'config')) {
        $panel = New-Object System.Windows.Forms.Panel
        $panel.Dock = 'Fill'
        $panel.BackColor = $colors.window
        $panel.Visible = $false
        $mainHost.Controls.Add($panel)
        $tabPanels[$tabId] = $panel
    }

    $tabInstall = $tabPanels['install']
    $tabTweaks = $tabPanels['tweaks']
    $tabUpdates = $tabPanels['updates']
    $tabLog = $tabPanels['log']
    $tabConfig = $tabPanels['config']
    $tabTweaks.AutoScroll = $true

    # Pestana Instalar
    $cardsView = New-Object ElvisCardsView
    $cardsView.Dock = 'Fill'
    $tabInstall.Controls.Add($cardsView)

    # Pestana Actualizar
    $lblUpdatesTitle = New-Object System.Windows.Forms.Label
    $lblUpdatesTitle.Text = 'Actualizaciones'
    $lblUpdatesTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblUpdatesTitle.ForeColor = $colors.text
    $lblUpdatesTitle.Location = New-Object System.Drawing.Point(24, 20)
    $lblUpdatesTitle.Size = New-Object System.Drawing.Size(500, 30)
    $tabUpdates.Controls.Add($lblUpdatesTitle)

    $lblUpdatesHint = New-Object System.Windows.Forms.Label
    $lblUpdatesHint.Text = 'Actualiza los programas gestionados con winget y abre Windows Update.'
    $lblUpdatesHint.ForeColor = $colors.muted
    $lblUpdatesHint.Location = New-Object System.Drawing.Point(24, 50)
    $lblUpdatesHint.Size = New-Object System.Drawing.Size(740, 20)
    $tabUpdates.Controls.Add($lblUpdatesHint)

    $lblUpdatesApps = New-Object System.Windows.Forms.Label
    $lblUpdatesApps.Text = 'APLICACIONES GESTIONADAS'
    $lblUpdatesApps.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblUpdatesApps.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblUpdatesApps.Location = New-Object System.Drawing.Point(24, 86)
    $lblUpdatesApps.Size = New-Object System.Drawing.Size(400, 18)
    $tabUpdates.Controls.Add($lblUpdatesApps)

    $updatesLines = @()
    foreach ($file in @($Config.files)) {
        $state = if (Resolve-InstalledPath -File $file) { 'instalado' } else { 'no instalado' }
        $updatesLines += ('- {0}: {1}' -f $file.name, $state)
    }

    $lblUpdatesList = New-Object System.Windows.Forms.Label
    $lblUpdatesList.Text = ($updatesLines -join "`r`n")
    $lblUpdatesList.ForeColor = $colors.text
    $lblUpdatesList.Location = New-Object System.Drawing.Point(36, 112)
    $lblUpdatesList.Size = New-Object System.Drawing.Size(720, 112)
    $tabUpdates.Controls.Add($lblUpdatesList)

    $btnUpdatesAll = New-FlatButton -Text 'Actualizar todos los instalados' -X 24 -Y 238 -Width 240 -Height 40 -Primary
    $tabUpdates.Controls.Add($btnUpdatesAll)

    $btnRefreshState = New-FlatButton -Text 'Refrescar estado' -X 276 -Y 238 -Width 160 -Height 40
    $tabUpdates.Controls.Add($btnRefreshState)

    $script:WingetVersion = ''
    if (Test-WingetAvailable) {
        try { $script:WingetVersion = ((& winget --version 2>&1 | Out-String).Trim()) } catch { }
    }

    $lblWingetState = New-Object System.Windows.Forms.Label
    if (Test-WingetAvailable) {
        $lblWingetState.Text = "winget disponible ($script:WingetVersion). Las actualizaciones usan el catalogo oficial de winget."
        $lblWingetState.ForeColor = $colors.green
    } else {
        $lblWingetState.Text = 'winget no esta disponible. Instala App Installer desde Microsoft Store para actualizar y desinstalar.'
        $lblWingetState.ForeColor = [System.Drawing.Color]::FromArgb(230, 160, 40)
    }
    $lblWingetState.Location = New-Object System.Drawing.Point(24, 292)
    $lblWingetState.Size = New-Object System.Drawing.Size(740, 40)
    $tabUpdates.Controls.Add($lblWingetState)

    $lblWindowsUpdate = New-Object System.Windows.Forms.Label
    $lblWindowsUpdate.Text = 'WINDOWS UPDATE'
    $lblWindowsUpdate.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblWindowsUpdate.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblWindowsUpdate.Location = New-Object System.Drawing.Point(24, 356)
    $lblWindowsUpdate.Size = New-Object System.Drawing.Size(400, 18)
    $tabUpdates.Controls.Add($lblWindowsUpdate)

    $btnOpenWindowsUpdate = New-FlatButton -Text 'Abrir Windows Update' -X 24 -Y 382 -Width 210 -Height 40
    $tabUpdates.Controls.Add($btnOpenWindowsUpdate)

    $btnOpenUpdateHistory = New-FlatButton -Text 'Ver historial' -X 246 -Y 382 -Width 150 -Height 40
    $tabUpdates.Controls.Add($btnOpenUpdateHistory)

    $lblUpdatesNote = New-Object System.Windows.Forms.Label
    $lblUpdatesNote.Text = 'WinUtil tambien modifica las politicas de Windows Update. Aqui no se desactivan actualizaciones por seguridad.'
    $lblUpdatesNote.ForeColor = $colors.muted
    $lblUpdatesNote.Location = New-Object System.Drawing.Point(24, 440)
    $lblUpdatesNote.Size = New-Object System.Drawing.Size(740, 40)
    $tabUpdates.Controls.Add($lblUpdatesNote)


    # Pestana Ajustes
    $lblTweaksTitle = New-Object System.Windows.Forms.Label
    $lblTweaksTitle.Text = 'Ajustes del sistema'
    $lblTweaksTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblTweaksTitle.ForeColor = $colors.text
    $lblTweaksTitle.Location = New-Object System.Drawing.Point(24, 20)
    $lblTweaksTitle.Size = New-Object System.Drawing.Size(500, 30)
    $tabTweaks.Controls.Add($lblTweaksTitle)

    $lblTweaksHint = New-Object System.Windows.Forms.Label
    $lblTweaksHint.Text = 'Los ajustes se aplican antes de instalar. Usa un preset o marca los que quieras.'
    $lblTweaksHint.ForeColor = $colors.muted
    $lblTweaksHint.Location = New-Object System.Drawing.Point(24, 50)
    $lblTweaksHint.Size = New-Object System.Drawing.Size(720, 20)
    $tabTweaks.Controls.Add($lblTweaksHint)

    $btnPresetRecommended = New-FlatButton -Text 'Recomendado' -X 18 -Y 78 -Width 136 -Height 32 -Primary
    $btnPresetMinimal = New-FlatButton -Text 'Minimo' -X 162 -Y 78 -Width 120 -Height 32
    $btnPresetAdvanced = New-FlatButton -Text 'Avanzados' -X 290 -Y 78 -Width 136 -Height 32
    $btnPresetAll = New-FlatButton -Text 'Todo' -X 434 -Y 78 -Width 100 -Height 32
    $btnPresetClear = New-FlatButton -Text 'Limpiar' -X 542 -Y 78 -Width 120 -Height 32
    $tabTweaks.Controls.Add($btnPresetRecommended)
    $tabTweaks.Controls.Add($btnPresetMinimal)
    $tabTweaks.Controls.Add($btnPresetAdvanced)
    $tabTweaks.Controls.Add($btnPresetAll)
    $tabTweaks.Controls.Add($btnPresetClear)

    $flowTweaks = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowTweaks.Location = New-Object System.Drawing.Point(18, 120)
    $flowTweaks.Size = New-Object System.Drawing.Size(760, 310)
    $flowTweaks.FlowDirection = 'TopDown'
    $flowTweaks.WrapContents = $false
    $flowTweaks.AutoScroll = $true
    $flowTweaks.BackColor = $colors.window
    $tabTweaks.Controls.Add($flowTweaks)

    $tweakCategories = @($Config.tweaks | ForEach-Object { $_.category } | Select-Object -Unique)
    foreach ($category in $tweakCategories) {
        $header = New-Object System.Windows.Forms.Label
        $header.Text = [string]$category
        $header.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
        $header.ForeColor = [System.Drawing.Color]::FromArgb(90, 169, 230)
        $header.Size = New-Object System.Drawing.Size(736, 24)
        $header.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 4)
        $flowTweaks.Controls.Add($header)

        foreach ($tweak in @($Config.tweaks | Where-Object { $_.category -eq $category })) {
            $row = New-Object System.Windows.Forms.Panel
            $row.Size = New-Object System.Drawing.Size(736, 54)
            $row.BackColor = $colors.panel
            $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)

            $check = New-Object System.Windows.Forms.CheckBox
            $check.Text = $tweak.name
            $check.Tag = $tweak.id
            $check.Checked = [bool]$tweak.enabled
            $check.Location = New-Object System.Drawing.Point(12, 7)
            $check.Size = New-Object System.Drawing.Size(708, 24)
            $check.ForeColor = $colors.text
            $check.BackColor = $colors.panel
            $check.FlatStyle = 'Flat'
            $row.Controls.Add($check)

            if ($tweak.description) {
                $description = New-Object System.Windows.Forms.Label
                $description.Text = $tweak.description
                $description.ForeColor = $colors.muted
                $description.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
                $description.Location = New-Object System.Drawing.Point(34, 30)
                $description.Size = New-Object System.Drawing.Size(690, 18)
                $row.Controls.Add($description)
            }

            $flowTweaks.Controls.Add($row)
            $script:TweakChecks[$tweak.id] = $check
            $script:TweakModels[$tweak.id] = $tweak
        }
    }

    if ($flowTweaks.Controls.Count -eq 0) {
        $lblNoTweaks = New-Object System.Windows.Forms.Label
        $lblNoTweaks.Text = 'No hay ajustes configurados.'
        $lblNoTweaks.ForeColor = $colors.muted
        $lblNoTweaks.AutoSize = $true
        $lblNoTweaks.Location = New-Object System.Drawing.Point(24, 130)
        $tabTweaks.Controls.Add($lblNoTweaks)
    }

    $btnApplyTweaks = New-FlatButton -Text 'Ejecutar ajustes marcados' -X 18 -Y 448 -Width 240 -Height 40 -Primary
    $tabTweaks.Controls.Add($btnApplyTweaks)

    $btnUndoTweaks = New-FlatButton -Text 'Deshacer seleccionados' -X 270 -Y 448 -Width 220 -Height 40
    $tabTweaks.Controls.Add($btnUndoTweaks)

    $lblTweaksFooter = New-Object System.Windows.Forms.Label
    $lblTweaksFooter.Text = 'Ejecutar ajustes no instala programas. El punto de restauracion se ejecuta primero.'
    $lblTweaksFooter.ForeColor = $colors.muted
    $lblTweaksFooter.Location = New-Object System.Drawing.Point(18, 496)
    $lblTweaksFooter.Size = New-Object System.Drawing.Size(740, 20)
    $tabTweaks.Controls.Add($lblTweaksFooter)

    # Pestana Registro
    $lblLogTitle = New-Object System.Windows.Forms.Label
    $lblLogTitle.Text = 'Registro de actividades'
    $lblLogTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblLogTitle.ForeColor = $colors.text
    $lblLogTitle.Location = New-Object System.Drawing.Point(24, 20)
    $lblLogTitle.Size = New-Object System.Drawing.Size(500, 30)
    $tabLog.Controls.Add($lblLogTitle)

    $txtLog = New-Object System.Windows.Forms.RichTextBox
    $txtLog.Location = New-Object System.Drawing.Point(24, 54)
    $txtLog.Size = New-Object System.Drawing.Size(748, 438)
    $txtLog.ReadOnly = $true
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(24, 25, 28)
    $txtLog.ForeColor = $colors.text
    $txtLog.BorderStyle = 'FixedSingle'
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 11)
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.WordWrap = $true
    $txtLog.DetectUrls = $false
    $txtLog.HideSelection = $false
    $tabLog.Controls.Add($txtLog)

    # Pestana Config
    $lblConfigTitle = New-Object System.Windows.Forms.Label
    $lblConfigTitle.Text = 'Configuracion'
    $lblConfigTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblConfigTitle.ForeColor = $colors.text
    $lblConfigTitle.Location = New-Object System.Drawing.Point(24, 20)
    $lblConfigTitle.Size = New-Object System.Drawing.Size(500, 30)
    $tabConfig.Controls.Add($lblConfigTitle)

    $installedCount = 0
    foreach ($file in @($Config.files)) {
        if (Resolve-InstalledPath -File $file) { $installedCount++ }
    }

    $lblConfigInfo = New-Object System.Windows.Forms.Label
    $lblConfigInfo.Location = New-Object System.Drawing.Point(24, 58)
    $lblConfigInfo.Size = New-Object System.Drawing.Size(748, 180)
    $lblConfigInfo.ForeColor = $colors.text
    $lblConfigInfo.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $lblConfigInfo.Text = @"
Archivo de configuracion:
$ConfigPath

Registro de esta sesion:
$($script:LogFile)

Programas: $(@($Config.files).Count) (instalados: $installedCount)
Ajustes: $(@($Config.tweaks).Count)
Accesos directos: $(@($Config.shortcuts).Count)
"@
    $tabConfig.Controls.Add($lblConfigInfo)

    $lblBackendInfo = New-Object System.Windows.Forms.Label
    $lblBackendInfo.Location = New-Object System.Drawing.Point(24, 248)
    $lblBackendInfo.Size = New-Object System.Drawing.Size(748, 24)
    $lblBackendInfo.ForeColor = $colors.muted
    $lblBackendInfo.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $lblBackendInfo.Text = 'Motor actual: Directo (instaladores verificados).'
    $tabConfig.Controls.Add($lblBackendInfo)

    $lblConfigTools = New-Object System.Windows.Forms.Label
    $lblConfigTools.Text = 'HERRAMIENTAS'
    $lblConfigTools.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblConfigTools.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblConfigTools.Location = New-Object System.Drawing.Point(24, 282)
    $lblConfigTools.Size = New-Object System.Drawing.Size(400, 18)
    $tabConfig.Controls.Add($lblConfigTools)

    $btnOpenConfig = New-FlatButton -Text 'Abrir config.json' -X 24 -Y 306 -Width 230
    $btnOpenLogs = New-FlatButton -Text 'Abrir carpeta de registros' -X 264 -Y 306 -Width 230
    $btnConfigRefresh = New-FlatButton -Text 'Refrescar estado' -X 504 -Y 306 -Width 230
    $tabConfig.Controls.Add($btnOpenConfig)
    $tabConfig.Controls.Add($btnOpenLogs)
    $tabConfig.Controls.Add($btnConfigRefresh)

    $btnControlPanel = New-FlatButton -Text 'Panel de control' -X 24 -Y 346 -Width 230
    $btnNetworkPanel = New-FlatButton -Text 'Conexiones de red' -X 264 -Y 346 -Width 230
    $btnSoundPanel = New-FlatButton -Text 'Sonido' -X 504 -Y 346 -Width 230
    $tabConfig.Controls.Add($btnControlPanel)
    $tabConfig.Controls.Add($btnNetworkPanel)
    $tabConfig.Controls.Add($btnSoundPanel)

    $btnPrinterPanel = New-FlatButton -Text 'Impresoras' -X 24 -Y 386 -Width 230
    $btnProgramsPanel = New-FlatButton -Text 'Programas y caracteristicas' -X 264 -Y 386 -Width 230
    $btnRepairWinget = New-FlatButton -Text 'Reparar winget' -X 504 -Y 386 -Width 230
    $tabConfig.Controls.Add($btnPrinterPanel)
    $tabConfig.Controls.Add($btnProgramsPanel)
    $tabConfig.Controls.Add($btnRepairWinget)

    $btnResetNetwork = New-FlatButton -Text 'Reset de red' -X 24 -Y 426 -Width 230
    $btnScanCorruption = New-FlatButton -Text 'Escanear corrupcion' -X 264 -Y 426 -Width 230
    $tabConfig.Controls.Add($btnResetNetwork)
    $tabConfig.Controls.Add($btnScanCorruption)

    $lblConfigNote = New-Object System.Windows.Forms.Label
    $lblConfigNote.Text = 'SFC + DISM abre una consola aparte y puede tardar varios minutos. El reset de red requiere reiniciar.'
    $lblConfigNote.ForeColor = $colors.muted
    $lblConfigNote.Location = New-Object System.Drawing.Point(24, 470)
    $lblConfigNote.Size = New-Object System.Drawing.Size(740, 40)
    $tabConfig.Controls.Add($lblConfigNote)

    # --- Botones laterales ---------------------------------------------------
    $lblActions = New-Object System.Windows.Forms.Label
    $lblActions.Text = 'ACCIONES'
    $lblActions.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblActions.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblActions.Location = New-Object System.Drawing.Point(14, 16)
    $lblActions.Size = New-Object System.Drawing.Size(172, 18)
    $sideBar.Controls.Add($lblActions)

    function New-SidebarButton {
        param([string]$Text, [int]$Y, [switch]$Primary)

        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Location = New-Object System.Drawing.Point(14, $Y)
        $button.Size = New-Object System.Drawing.Size(176, 34)
        $button.FlatStyle = 'Flat'
        $button.FlatAppearance.BorderSize = 0
        $button.TextAlign = 'MiddleLeft'
        $button.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
        $button.Cursor = 'Hand'

        if ($Primary) {
            $button.BackColor = $colors.accent
            $button.ForeColor = [System.Drawing.Color]::White
            $button.Font = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
            $button.FlatAppearance.MouseOverBackColor = $colors.accentHover
            $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(37, 90, 168)
        } else {
            $button.BackColor = $colors.sideBar
            $button.ForeColor = [System.Drawing.Color]::FromArgb(220, 221, 222)
            $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(49, 51, 56)
            $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(58, 60, 66)
        }

        $sideBar.Controls.Add($button)
        return $button
    }

    $btnPrimary = New-SidebarButton -Text 'Instalar seleccionados' -Y 40 -Primary
    $btnUninstall = New-SidebarButton -Text 'Desinstalar' -Y 78
    $btnUpgradeAll = New-SidebarButton -Text 'Actualizar instalados' -Y 114
    $btnShortcuts = New-SidebarButton -Text 'Crear accesos directos' -Y 150
    $btnClean = New-SidebarButton -Text 'Limpiar temporal' -Y 186
    $btnLog = New-SidebarButton -Text 'Abrir registro' -Y 222

    $lblSelection = New-Object System.Windows.Forms.Label
    $lblSelection.Text = 'SELECCION'
    $lblSelection.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblSelection.ForeColor = [System.Drawing.Color]::FromArgb(127, 131, 138)
    $lblSelection.Location = New-Object System.Drawing.Point(14, 262)
    $lblSelection.Size = New-Object System.Drawing.Size(172, 18)
    $sideBar.Controls.Add($lblSelection)

    $btnAll = New-SidebarButton -Text 'Seleccionar todo' -Y 284
    $btnNone = New-SidebarButton -Text 'Quitar seleccion' -Y 320
    $btnExpand = New-SidebarButton -Text 'Expandir categorias' -Y 356
    $btnCollapse = New-SidebarButton -Text 'Contraer categorias' -Y 392
    $btnInstalledOnly = New-SidebarButton -Text 'Solo instalados' -Y 428

    $lblSummary = New-Object System.Windows.Forms.Label
    $lblSummary.Location = New-Object System.Drawing.Point(16, 470)
    $lblSummary.Size = New-Object System.Drawing.Size(174, 64)
    $lblSummary.ForeColor = $colors.muted
    $lblSummary.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $sideBar.Controls.Add($lblSummary)

    # --- Logica de la interfaz ----------------------------------------------
    function Set-UiProgress {
        param([int]$Value)
        if ($Value -lt 0) { $Value = 0 }
        if ($Value -gt 100) { $Value = 100 }
        $progressFill.Width = [int]($progressTrack.Width * $Value / 100)
        $lblPercent.Text = "$Value%"
    }

    function Append-UiLog {
        param([string]$Line)

        $color = [System.Drawing.Color]::FromArgb(200, 202, 205)
        if ($Line -match '\[OK\]') { $color = [System.Drawing.Color]::FromArgb(87, 200, 120) }
        elseif ($Line -match '\[WARN\]') { $color = [System.Drawing.Color]::FromArgb(230, 180, 80) }
        elseif ($Line -match '\[ERROR\]') { $color = [System.Drawing.Color]::FromArgb(240, 110, 110) }

        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.SelectionLength = 0
        $txtLog.SelectionColor = $color
        $txtLog.AppendText($Line + "`r`n")
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    }

    function Add-UiMessage {
        param([string]$Message, [string]$Level = 'INFO')

        Write-LogLine $Message $Level
        Append-UiLog ('[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message)

        try {
            if (Test-Path -LiteralPath $script:LogFile) {
                $script:LogPos = (Get-Item -LiteralPath $script:LogFile).Length
            }
        } catch { }
    }

    function Read-NewLogLines {
        if (-not $script:LogFile -or -not (Test-Path -LiteralPath $script:LogFile)) { return @() }

        $lines = @()
        try {
            $stream = [System.IO.File]::Open($script:LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                if ($stream.Length -lt $script:LogPos) { $script:LogPos = 0 }
                $stream.Position = $script:LogPos
                $remaining = [int]($stream.Length - $stream.Position)
                if ($remaining -gt 0) {
                    $buffer = New-Object byte[] $remaining
                    $read = $stream.Read($buffer, 0, $remaining)
                    $lastNewLine = -1
                    for ($i = $read - 1; $i -ge 0; $i--) {
                        if ($buffer[$i] -eq 10) { $lastNewLine = $i; break }
                    }
                    if ($lastNewLine -ge 0) {
                        $text = $script:Utf8NoBom.GetString($buffer, 0, $lastNewLine + 1)
                        $script:LogPos = $script:LogPos + $lastNewLine + 1
                        $lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
                    }
                }
            } finally {
                $stream.Dispose()
            }
        } catch { }
        return $lines
    }

    function Read-ProgressFile {
        if (-not $script:ProgressFile -or -not (Test-Path -LiteralPath $script:ProgressFile)) { return $null }
        try {
            $json = [System.IO.File]::ReadAllText($script:ProgressFile, $script:Utf8NoBom)
            if ([string]::IsNullOrWhiteSpace($json)) { return $null }
            return ($json | ConvertFrom-Json)
        } catch {
            return $null
        }
    }

    function Update-InstallButton {
        if ($script:IsInstalling) { return }
        $count = $cardsView.SelectedCount
        if ($count -gt 0) {
            $btnPrimary.Text = "Instalar ($count)"
        } else {
            $btnPrimary.Text = 'Instalar'
        }
    }

    function Update-SidebarSummary {
        $installed = 0
        foreach ($file in @($Config.files)) {
            if (Resolve-InstalledPath -File $file) { $installed++ }
        }
        $lblSummary.Text = "{0} programas`n{1} instalados`n{2} ajustes" -f @($Config.files).Count, $installed, @($Config.tweaks).Count
    }

    function Update-UpdatesSummary {
        if (-not $lblUpdatesList) { return }

        $lines = @()
        foreach ($file in @($Config.files)) {
            $state = if (Resolve-InstalledPath -File $file) { 'instalado' } else { 'no instalado' }
            $lines += ('- {0}: {1}' -f $file.name, $state)
        }
        $lblUpdatesList.Text = ($lines -join "`r`n")

        if (Test-WingetAvailable) {
            $lblWingetState.Text = "winget disponible ($($script:WingetVersion)). Las actualizaciones usan el catalogo oficial de winget."
            $lblWingetState.ForeColor = $colors.green
        } else {
            $lblWingetState.Text = 'winget no esta disponible. Instala App Installer desde Microsoft Store para actualizar y desinstalar.'
            $lblWingetState.ForeColor = [System.Drawing.Color]::FromArgb(230, 160, 40)
        }
    }

    function Rebuild-ProgramCards {
        $selection = @($cardsView.GetSelectedIds())
        $models = Build-ProgramModels -Config $Config -SelectedIds $selection -StatusMap $script:ProgramStatus
        $cardsView.SetPrograms($models)
        Update-InstallButton
        Update-SidebarSummary
        Update-UpdatesSummary
    }

    function Update-UiProgress {
        $state = Read-ProgressFile
        if ($null -eq $state) { return }

        $value = 0
        if ($null -ne $state.percent) { $value = [int]$state.percent }
        Set-UiProgress -Value $value

        if ($state.status) { $lblStatus.Text = [string]$state.status }

        $statusMap = @{
            'pending'      = @{ Text = 'En espera'; Kind = 0 }
            'downloading'  = @{ Text = 'Descargando'; Kind = 0 }
            'verifying'    = @{ Text = 'Verificando'; Kind = 0 }
            'installing'   = @{ Text = 'Instalando'; Kind = 0 }
            'upgrading'    = @{ Text = 'Actualizando'; Kind = 0 }
            'uninstalling' = @{ Text = 'Desinstalando'; Kind = 0 }
            'ok'           = @{ Text = 'Instalado'; Kind = 1 }
            'downloaded'   = @{ Text = 'Descargado'; Kind = 1 }
            'updated'      = @{ Text = 'Actualizado'; Kind = 1 }
            'uptodate'     = @{ Text = 'Al dia'; Kind = 1 }
            'uninstalled'  = @{ Text = 'Desinstalado'; Kind = 0 }
            'skipped'      = @{ Text = 'Omitido'; Kind = 3 }
            'warn'         = @{ Text = 'Advertencia'; Kind = 3 }
            'error'        = @{ Text = 'Error'; Kind = 2 }
            'cancelled'    = @{ Text = 'Cancelado'; Kind = 3 }
        }

        foreach ($entry in @($state.items)) {
            $mapped = $statusMap[[string]$entry.status]
            if (-not $mapped) { $mapped = @{ Text = [string]$entry.status; Kind = 0 } }
            $script:ProgramStatus[[string]$entry.id] = @{ Text = $mapped.Text; Kind = $mapped.Kind }
            $cardsView.SetStatus([string]$entry.id, $mapped.Text, $mapped.Kind)
        }
    }

    function Set-RunningState {
        param([bool]$Running)

        $script:IsInstalling = $Running
        $wingetOk = Test-WingetAvailable
        $btnUninstall.Enabled = (-not $Running) -and $wingetOk
        $btnUpgradeAll.Enabled = (-not $Running) -and $wingetOk
        $btnShortcuts.Enabled = -not $Running
        $btnClean.Enabled = -not $Running
        $btnAll.Enabled = -not $Running
        $btnNone.Enabled = -not $Running
        $btnExpand.Enabled = -not $Running
        $btnCollapse.Enabled = -not $Running
        $btnInstalledOnly.Enabled = -not $Running
        $btnApplyTweaks.Enabled = -not $Running
        $btnUndoTweaks.Enabled = -not $Running
        $btnPresetRecommended.Enabled = -not $Running
        $btnPresetMinimal.Enabled = -not $Running
        $btnPresetAdvanced.Enabled = -not $Running
        $btnPresetAll.Enabled = -not $Running
        $btnPresetClear.Enabled = -not $Running
        $btnUpdatesAll.Enabled = (-not $Running) -and $wingetOk
        $btnRefreshState.Enabled = -not $Running
        $btnConfigRefresh.Enabled = -not $Running
        $btnRepairWinget.Enabled = (-not $Running) -and $wingetOk
        $btnResetNetwork.Enabled = -not $Running
        $btnScanCorruption.Enabled = -not $Running
        $btnBackendWinget.Enabled = (-not $Running) -and $wingetOk
        $btnBackendDirect.Enabled = -not $Running
        $cardsView.Enabled = -not $Running
        $flowTweaks.Enabled = -not $Running

        if ($Running) {
            $btnPrimary.Text = 'Cancelar operacion'
            $btnPrimary.BackColor = $colors.red
            $btnPrimary.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(200, 70, 70)
            $btnPrimary.Enabled = $true
        } else {
            $btnPrimary.BackColor = $colors.accent
            $btnPrimary.FlatAppearance.MouseOverBackColor = $colors.accentHover
            $btnPrimary.Enabled = $true
            Update-InstallButton
        }
    }

    function Show-Tab {
        param([string]$Name)

        foreach ($key in $tabPanels.Keys) {
            $tabPanels[$key].Visible = ($key -eq $Name)
        }
        foreach ($key in $tabButtons.Keys) {
            $button = $tabButtons[$key]
            if ($key -eq $Name) {
                $button.BackColor = $colors.accent
                $button.ForeColor = [System.Drawing.Color]::White
            } else {
                $button.BackColor = $colors.topBar
                $button.ForeColor = $colors.muted
            }
        }

        $txtSearch.Enabled = ($Name -eq 'install')
    }

    function Update-BackendUi {
        $direct = ($script:Backend -eq 'direct')

        if ($direct) {
            $btnBackendDirect.BackColor = $colors.accent
            $btnBackendDirect.ForeColor = [System.Drawing.Color]::White
            $btnBackendWinget.BackColor = $colors.topBar
            $btnBackendWinget.ForeColor = $colors.muted
            $lblBackendInfo.Text = 'Motor actual: Directo (instaladores oficiales verificados con SHA256 y/o firma).'
        } else {
            $btnBackendDirect.BackColor = $colors.topBar
            $btnBackendDirect.ForeColor = $colors.muted
            $btnBackendWinget.BackColor = $colors.accent
            $btnBackendWinget.ForeColor = [System.Drawing.Color]::White
            $lblBackendInfo.Text = 'Motor actual: Winget (instala y actualiza desde el catalogo de Windows Package Manager).'
        }
    }

    function Set-UiBackend {
        param([string]$Name)

        if ($Name -eq 'winget' -and -not (Test-WingetAvailable)) {
            [System.Windows.Forms.MessageBox]::Show('winget no esta disponible en este equipo. Instala App Installer desde Microsoft Store.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $script:Backend = $Name
        Update-BackendUi
    }

    function Get-SelectedTweakIds {
        $ids = @()
        foreach ($key in $script:TweakChecks.Keys) {
            if ($script:TweakChecks[$key].Checked) { $ids += $key }
        }
        return $ids
    }

    function Set-TweakPreset {
        param([string]$Name)

        foreach ($key in $script:TweakChecks.Keys) {
            $model = $script:TweakModels[$key]
            $checked = switch ($Name) {
                'recommended' { $model.category -eq 'Esenciales' }
                'minimal' { $key -in @('restorepoint', 'telemetry') }
                'advanced' { $model.category -eq 'Avanzados' }
                'all' { $true }
                'clear' { $false }
                default { $false }
            }
            $script:TweakChecks[$key].Checked = [bool]$checked
        }
    }

    function Start-ElvisJob {
        param(
            [string[]]$ExtraArguments,
            [string]$InitialStatus,
            [switch]$OpenLogTab
        )

        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return $false }

        $runId = [guid]::NewGuid().ToString('N')
        $runDir = Join-Path $env:TEMP "ElvisLab\run_$runId"
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null

        $script:ProgressFile = Join-Path $runDir 'progress.json'
        $script:CancelFile = Join-Path $runDir 'cancel.flag'

        try {
            $launch = Get-HostLaunchCommand
            $arguments = New-Object System.Collections.Generic.List[string]
            foreach ($part in $launch.Prefix) { $arguments.Add([string]$part) }
            $arguments.Add('-Headless')
            $arguments.Add('-ConfigPath'); $arguments.Add(('"{0}"' -f $ConfigPath))
            $arguments.Add('-ProgressFile'); $arguments.Add(('"{0}"' -f $script:ProgressFile))
            $arguments.Add('-CancelFile'); $arguments.Add(('"{0}"' -f $script:CancelFile))
            if ($script:LogFile) {
                $arguments.Add('-LogFile'); $arguments.Add(('"{0}"' -f $script:LogFile))
            }
            foreach ($arg in $ExtraArguments) { $arguments.Add([string]$arg) }

            $script:InstallProcess = Start-Process -FilePath $launch.FileName -ArgumentList ($arguments -join ' ') -PassThru -WindowStyle Hidden
        } catch {
            Add-UiMessage "No se pudo iniciar el proceso: $($_.Exception.Message)" 'ERROR'
            return $false
        }

        Set-RunningState -Running $true
        Set-UiProgress -Value 0
        $lblStatus.Text = $InitialStatus
        if ($OpenLogTab) { Show-Tab -Name 'log' }
        $timer.Start()
        return $true
    }

    # --- Pestanas ------------------------------------------------------------
    $tabButtons = @{}
    $tabDefinitions = @(
        @{ id = 'install'; text = 'Instalar' },
        @{ id = 'tweaks'; text = 'Ajustes' },
        @{ id = 'updates'; text = 'Actualizar' },
        @{ id = 'log'; text = 'Registro' },
        @{ id = 'config'; text = 'Config' }
    )

    $tabX = 152
    foreach ($tab in $tabDefinitions) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $tab.text
        $button.Location = New-Object System.Drawing.Point($tabX, 10)
        $button.Size = New-Object System.Drawing.Size(88, 30)
        $button.FlatStyle = 'Flat'
        $button.FlatAppearance.BorderSize = 0
        $button.BackColor = $colors.topBar
        $button.ForeColor = $colors.muted
        $button.Cursor = 'Hand'
        $button.Tag = $tab.id
        $button.Add_Click({
            param($sender, $eventArgs)
            Show-Tab -Name ([string]$sender.Tag)
        })
        $topBar.Controls.Add($button)
        $tabButtons[$tab.id] = $button
        $tabX += 92
    }

    # --- Datos iniciales -----------------------------------------------------
    $cardsView.SetPrograms((Build-ProgramModels -Config $Config -SelectedIds @() -StatusMap $script:ProgramStatus))
    Update-InstallButton
    Update-SidebarSummary

    $script:SearchPlaceholder = 'Buscar programas...'
    $txtSearch.Add_GotFocus({
        if ($txtSearch.Text -eq $script:SearchPlaceholder) {
            $txtSearch.Text = ''
            $txtSearch.ForeColor = [System.Drawing.Color]::FromArgb(227, 229, 232)
        }
    })
    $txtSearch.Add_LostFocus({
        if ([string]::IsNullOrWhiteSpace($txtSearch.Text)) {
            $txtSearch.Text = $script:SearchPlaceholder
            $txtSearch.ForeColor = [System.Drawing.Color]::FromArgb(154, 160, 166)
        }
    })
    $txtSearch.Add_TextChanged({
        if ($txtSearch.Text -eq $script:SearchPlaceholder) {
            $cardsView.SetFilter('')
        } else {
            $cardsView.SetFilter($txtSearch.Text)
        }
    })

    $cardsView.Add_SelectionChanged({
        Update-InstallButton
    })

    # --- Timer ---------------------------------------------------------------
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        foreach ($line in (Read-NewLogLines)) { Append-UiLog $line }
        Update-UiProgress

        if (-not $script:InstallProcess) { return }
        if (-not $script:InstallProcess.HasExited) { return }

        [System.Threading.Thread]::Sleep(150)
        foreach ($line in (Read-NewLogLines)) { Append-UiLog $line }
        Update-UiProgress

        $process = $script:InstallProcess
        $exitCode = $process.ExitCode
        $script:InstallProcess = $null
        $timer.Stop()
        $process.Dispose()

        $final = Read-ProgressFile
        $finalStatus = ''
        if ($final -and $final.status) { $finalStatus = [string]$final.status }

        if ($exitCode -eq 0) {
            if (-not $finalStatus) { $finalStatus = 'Operacion completada.' }
            $lblStatus.Text = $finalStatus
            if (-not $final) { Add-UiMessage $finalStatus 'OK' }
        } elseif ($exitCode -eq 3) {
            if (-not $finalStatus) { $finalStatus = 'Operacion cancelada.' }
            $lblStatus.Text = $finalStatus
            if (-not $final) { Add-UiMessage $finalStatus 'WARN' }
        } else {
            if (-not $finalStatus) { $finalStatus = "La operacion termino con codigo $exitCode. Revisa el registro." }
            $lblStatus.Text = $finalStatus
            if (-not $final) { Add-UiMessage $finalStatus 'ERROR' }
        }

        Set-RunningState -Running $false
        Rebuild-ProgramCards
    })

    # --- Acciones ------------------------------------------------------------
    $btnPrimary.Add_Click({
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) {
            try {
                [System.IO.File]::WriteAllText($script:CancelFile, 'cancel', $script:Utf8NoBom)
            } catch { }
            $btnPrimary.Enabled = $false
            $lblStatus.Text = 'Cancelando... (se detiene al terminar el paso actual)'
            Add-UiMessage 'Cancelacion solicitada. Se detendra al terminar el paso actual.' 'WARN'
            return
        }

        $selectedIds = @($cardsView.GetSelectedIds())
        if ($selectedIds.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Selecciona al menos un programa.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $tweakIds = @(Get-SelectedTweakIds)
        $extra = @('-Backend', $script:Backend, '-Install', ('"{0}"' -f ($selectedIds -join ',')))
        if ($tweakIds.Count -gt 0) {
            $extra += @('-Tweaks', ('"{0}"' -f ($tweakIds -join ',')))
        } else {
            $extra += '-NoTweaks'
        }

        if (Start-ElvisJob -ExtraArguments $extra -InitialStatus 'Iniciando instalacion...' -OpenLogTab) {
            Add-UiMessage ("Instalando {0} programa(s) y {1} ajuste(s) con motor {2}." -f $selectedIds.Count, $tweakIds.Count, $script:Backend) 'INFO'
        }
    })

    function Start-UpgradeAll {
        if (-not (Test-WingetAvailable)) {
            [System.Windows.Forms.MessageBox]::Show('winget no esta disponible. Instala App Installer desde Microsoft Store.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return }

        $answer = [System.Windows.Forms.MessageBox]::Show('Se actualizaran con winget los programas gestionados que esten instalados. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        if (Start-ElvisJob -ExtraArguments @('-Upgrade') -InitialStatus 'Buscando actualizaciones...' -OpenLogTab) {
            Add-UiMessage 'Actualizando programas gestionados con winget...' 'INFO'
        }
    }

    $btnUninstall.Add_Click({
        if (-not (Test-WingetAvailable)) {
            [System.Windows.Forms.MessageBox]::Show('winget no esta disponible. Instala App Installer desde Microsoft Store.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return }

        $selectedIds = @($cardsView.GetSelectedIds())
        if ($selectedIds.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Selecciona al menos un programa.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $answer = [System.Windows.Forms.MessageBox]::Show(("Se desinstalaran {0} programa(s) con winget:`r`n`r`n{1}`r`n`r`nContinuar?" -f $selectedIds.Count, ($selectedIds -join ', ')), 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $extra = @('-Uninstall', '-Install', ('"{0}"' -f ($selectedIds -join ',')))
        if (Start-ElvisJob -ExtraArguments $extra -InitialStatus 'Desinstalando programas...' -OpenLogTab) {
            Add-UiMessage ("Desinstalando {0} programa(s) con winget..." -f $selectedIds.Count) 'INFO'
        }
    })

    $btnUpgradeAll.Add_Click({ Start-UpgradeAll })

    $btnPresetRecommended.Add_Click({ Set-TweakPreset -Name 'recommended' })
    $btnPresetMinimal.Add_Click({ Set-TweakPreset -Name 'minimal' })
    $btnPresetAdvanced.Add_Click({ Set-TweakPreset -Name 'advanced' })
    $btnPresetAll.Add_Click({ Set-TweakPreset -Name 'all' })
    $btnPresetClear.Add_Click({ Set-TweakPreset -Name 'clear' })

    $btnApplyTweaks.Add_Click({
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return }

        $tweakIds = @(Get-SelectedTweakIds)
        if ($tweakIds.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Marca al menos un ajuste.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $extra = @('-ApplyOnly', '-Tweaks', ('"{0}"' -f ($tweakIds -join ',')))
        if (Start-ElvisJob -ExtraArguments $extra -InitialStatus 'Aplicando ajustes...') {
            Add-UiMessage ("Aplicando {0} ajuste(s)..." -f $tweakIds.Count) 'INFO'
        }
    })

    $btnUndoTweaks.Add_Click({
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) { return }

        $tweakIds = @(Get-SelectedTweakIds)
        if ($tweakIds.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Marca al menos un ajuste.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $answer = [System.Windows.Forms.MessageBox]::Show('Se desharan los ajustes seleccionados que lo permitan. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $extra = @('-UndoTweaks', '-Tweaks', ('"{0}"' -f ($tweakIds -join ',')))
        if (Start-ElvisJob -ExtraArguments $extra -InitialStatus 'Restaurando ajustes...') {
            Add-UiMessage ("Restaurando {0} ajuste(s)..." -f $tweakIds.Count) 'INFO'
        }
    })

    $btnInstalledOnly.Add_Click({
        $script:InstalledOnly = -not $script:InstalledOnly
        $cardsView.SetInstalledOnly($script:InstalledOnly)
        if ($script:InstalledOnly) {
            $btnInstalledOnly.BackColor = $colors.accent
            $btnInstalledOnly.ForeColor = [System.Drawing.Color]::White
        } else {
            $btnInstalledOnly.BackColor = $colors.sideBar
            $btnInstalledOnly.ForeColor = [System.Drawing.Color]::FromArgb(220, 221, 222)
        }
    })

    $btnUpdatesAll.Add_Click({ Start-UpgradeAll })

    $btnRefreshState.Add_Click({
        Rebuild-ProgramCards
        Add-UiMessage 'Estado de instalacion actualizado.' 'INFO'
    })

    $btnOpenWindowsUpdate.Add_Click({
        try {
            Start-Process -FilePath 'ms-settings:windowsupdate'
        } catch {
            Add-UiMessage "No se pudo abrir Windows Update: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnOpenUpdateHistory.Add_Click({
        try {
            Start-Process -FilePath 'ms-settings:windowsupdate-history'
        } catch {
            Add-UiMessage "No se pudo abrir el historial de actualizaciones: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnShortcuts.Add_Click({
        Add-UiMessage 'Creando accesos directos...' 'INFO'
        $created = 0
        $skipped = 0
        foreach ($shortcut in @($Config.shortcuts)) {
            try {
                if (New-ShortcutItem -Shortcut $shortcut -Config $Config) { $created++ } else { $skipped++ }
            } catch {
                Add-UiMessage "ERROR al crear '$($shortcut.name)': $($_.Exception.Message)" 'ERROR'
            }
        }
        if ($created -gt 0) {
            Add-UiMessage "OK: $created acceso(s) directo(s) creado(s)." 'OK'
        } else {
            Add-UiMessage 'No se creo ningun acceso directo. Instala primero los programas.' 'WARN'
        }
        if ($skipped -gt 0) {
            Add-UiMessage "$skipped acceso(s) omitido(s) porque el programa no esta instalado." 'WARN'
        }
        Update-SidebarSummary
    })

    $btnClean.Add_Click({
        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) {
            [System.Windows.Forms.MessageBox]::Show('Hay una instalacion en curso. Espera a que termine.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $tempRoot = Join-Path $env:TEMP 'ElvisLab'
        try {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
            Add-UiMessage 'Carpeta temporal limpiada. Los accesos directos no dependen de ella.' 'OK'
        } catch {
            Add-UiMessage "No se pudo limpiar la carpeta temporal: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnLog.Add_Click({
        if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
            try {
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:LogFile)
            } catch {
                Add-UiMessage "No se pudo abrir el registro: $($_.Exception.Message)" 'ERROR'
            }
        } else {
            Add-UiMessage 'Todavia no hay un archivo de registro.' 'WARN'
        }
    })

    $btnAll.Add_Click({ $cardsView.SelectAll() })
    $btnNone.Add_Click({ $cardsView.ClearSelection() })
    $btnExpand.Add_Click({ $cardsView.ExpandAll() })
    $btnCollapse.Add_Click({ $cardsView.CollapseAll() })

    $btnOpenConfig.Add_Click({
        try {
            Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $ConfigPath)
        } catch {
            Add-UiMessage "No se pudo abrir config.json: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnOpenLogs.Add_Click({
        try {
            $folder = Split-Path -Parent $script:LogFile
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder)
        } catch {
            Add-UiMessage "No se pudo abrir la carpeta de registros: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnConfigRefresh.Add_Click({
        Rebuild-ProgramCards
        Add-UiMessage 'Estado de instalacion actualizado.' 'INFO'
    })

    $btnControlPanel.Add_Click({
        try { Start-Process -FilePath 'control.exe' } catch { Add-UiMessage "No se pudo abrir el Panel de control: $($_.Exception.Message)" 'ERROR' }
    })

    $btnNetworkPanel.Add_Click({
        try { Start-Process -FilePath 'ncpa.cpl' } catch { Add-UiMessage "No se pudieron abrir las conexiones de red: $($_.Exception.Message)" 'ERROR' }
    })

    $btnSoundPanel.Add_Click({
        try { Start-Process -FilePath 'mmsys.cpl' } catch { Add-UiMessage "No se pudieron abrir los ajustes de sonido: $($_.Exception.Message)" 'ERROR' }
    })

    $btnPrinterPanel.Add_Click({
        try { Start-Process -FilePath 'control.exe' -ArgumentList 'printers' } catch { Add-UiMessage "No se pudieron abrir las impresoras: $($_.Exception.Message)" 'ERROR' }
    })

    $btnProgramsPanel.Add_Click({
        try { Start-Process -FilePath 'appwiz.cpl' } catch { Add-UiMessage "No se pudo abrir Programas y caracteristicas: $($_.Exception.Message)" 'ERROR' }
    })

    $btnRepairWinget.Add_Click({
        if (-not (Test-WingetAvailable)) {
            [System.Windows.Forms.MessageBox]::Show('winget no esta disponible en este equipo.', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        try {
            $result = Invoke-WingetCommand -Arguments @('source', 'update') -Quiet
            if ($result.ExitCode -eq 0) {
                Add-UiMessage 'Fuentes de winget actualizadas correctamente.' 'OK'
            } else {
                Add-UiMessage "winget source update termino con codigo $($result.ExitCode)." 'WARN'
            }
        } catch {
            Add-UiMessage "No se pudo reparar winget: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnResetNetwork.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show('Se restableceran la pila IP y Winsock. Necesitaras reiniciar. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $ipOutput = (& netsh int ip reset 2>&1 | Out-String)
            $ipCode = $LASTEXITCODE
            $winsockOutput = (& netsh winsock reset 2>&1 | Out-String)
            $winsockCode = $LASTEXITCODE
            Add-UiMessage ("Reset de red: IP codigo {0}, Winsock codigo {1}. Reinicia el equipo." -f $ipCode, $winsockCode) $(if ($ipCode -eq 0 -and $winsockCode -eq 0) { 'OK' } else { 'WARN' })
        } catch {
            Add-UiMessage "No se pudo restablecer la red: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnScanCorruption.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show('SFC + DISM puede tardar mucho tiempo. Se abrira una consola aparte. Continuar?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $command = 'sfc /scannow; DISM /Online /Cleanup-Image /RestoreHealth'
            Start-Process -FilePath 'powershell.exe' -ArgumentList ("-NoExit -ExecutionPolicy Bypass -Command `"$command`"")
            Add-UiMessage 'Se abrio una consola con SFC + DISM.' 'INFO'
        } catch {
            Add-UiMessage "No se pudo iniciar el escaneo: $($_.Exception.Message)" 'ERROR'
        }
    })

    $btnBackendDirect.Add_Click({ Set-UiBackend -Name 'direct' })
    $btnBackendWinget.Add_Click({ Set-UiBackend -Name 'winget' })

    if (-not (Test-WingetAvailable)) {
        $btnBackendWinget.Enabled = $false
        $btnUninstall.Enabled = $false
        $btnUpgradeAll.Enabled = $false
        $btnUpdatesAll.Enabled = $false
        $btnRepairWinget.Enabled = $false
    }

    Update-BackendUi
    Update-UpdatesSummary

    $form.Add_FormClosing({
        param($sender, $eventArgs)

        if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) {
            $answer = [System.Windows.Forms.MessageBox]::Show('Hay una operacion en curso. Si sales, el proceso continuara en segundo plano. Deseas salir?', 'ElvisLab', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                $eventArgs.Cancel = $true
                return
            }
            try { [System.IO.File]::WriteAllText($script:CancelFile, 'cancel', $script:Utf8NoBom) } catch { }
        }
    })

    Show-Tab -Name 'install'
    $lblStatus.Text = 'Listo. Selecciona los programas y pulsa Instalar.'
    Add-UiMessage ('Listo. Configuracion: {0}' -f $ConfigPath) 'INFO'

    $form.Add_Shown({ $form.Activate() })
    [void]$form.ShowDialog()
}

# ----------------------------------------------------------------------------
# Auto-test
# ----------------------------------------------------------------------------

function Invoke-SelfTest {
    param($Config)

    $ok = $true
    $admin = Test-IsAdmin

    Write-LogLine '=== ElvisLab SelfTest ===' 'INFO'
    Write-LogLine ("PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition) 'INFO'
    Write-LogLine ("Proceso de 64 bits: {0}" -f [Environment]::Is64BitProcess) 'INFO'
    Write-LogLine ("Administrador: {0}" -f $admin) 'INFO'
    Write-LogLine ("Directorio del script: {0}" -f $script:ScriptDir) 'INFO'
    Write-LogLine ("Archivo de registro: {0}" -f $script:LogFile) 'INFO'

    $ps2exe = Get-Command ps2exe -ErrorAction SilentlyContinue
    if (-not $ps2exe) { $ps2exe = Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue }
    Write-LogLine ("ps2exe disponible: {0}" -f [bool]$ps2exe) 'INFO'

    $wingetOk = Test-WingetAvailable
    $wingetVersionText = ''
    if ($wingetOk) {
        try { $wingetVersionText = ((& winget --version 2>&1 | Out-String).Trim()) } catch { }
    }
    Write-LogLine ("winget disponible: {0} {1}" -f $wingetOk, $wingetVersionText) 'INFO'

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

# ----------------------------------------------------------------------------
# Compilacion con ps2exe
# ----------------------------------------------------------------------------

function Invoke-BuildExe {
    param($Config)

    $command = Get-Command ps2exe -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue }
    if (-not $command) {
        Write-LogLine 'ps2exe no esta instalado. Ejecuta: Install-Module ps2exe -Scope CurrentUser -Force' 'ERROR'
        return 1
    }
    if (-not $PSCommandPath) {
        Write-LogLine 'No se puede compilar: no se conoce la ruta del script .ps1.' 'ERROR'
        return 1
    }

    $outputPath = Join-Path $script:ScriptDir 'ElvisLab.exe'
    $parameters = @{
        inputFile  = $PSCommandPath
        outputFile = $outputPath
        noConsole  = $true
        requireAdmin = $true
        STA        = $true
        x64        = $true
        title      = $Config.appName
        description = 'Instalador de programas y ajustes para Windows'
        product    = $Config.appName
        version    = '1.3.0.0'
    }

    $iconPath = Join-Path $script:ScriptDir 'Resources\ElvisLab.ico'
    if (Test-Path -LiteralPath $iconPath) { $parameters['iconFile'] = $iconPath }

    $accepted = @{}
    foreach ($key in $parameters.Keys) {
        if ($command.Parameters.ContainsKey($key)) { $accepted[$key] = $parameters[$key] }
    }

    Write-LogLine ("Compilando {0} con ps2exe..." -f $outputPath) 'INFO'
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
    }
}

# ----------------------------------------------------------------------------
# Elevacion y relanzamiento
# ----------------------------------------------------------------------------

function Get-HostLaunchCommand {
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($exe).ToLowerInvariant()
    $isPowerShell = $baseName -in @('powershell', 'pwsh')

    $prefix = New-Object System.Collections.Generic.List[string]
    if ($isPowerShell) {
        if (-not $PSCommandPath) { throw 'No se conoce la ruta del script para relanzar el proceso.' }
        $prefix.Add('-NoProfile')
        $prefix.Add('-ExecutionPolicy'); $prefix.Add('Bypass')
        $prefix.Add('-WindowStyle'); $prefix.Add('Hidden')
        if ($baseName -eq 'pwsh') { $prefix.Add('-STA') }
        $prefix.Add('-File'); $prefix.Add(('"{0}"' -f $PSCommandPath))
    }

    return [pscustomobject]@{
        FileName     = $exe
        IsPowerShell = $isPowerShell
        Prefix       = @($prefix)
    }
}

function Start-ElevatedProcess {
    $launch = Get-HostLaunchCommand
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($part in $launch.Prefix) { $arguments.Add([string]$part) }

    $arguments.Add('-ConfigPath'); $arguments.Add(('"{0}"' -f $ConfigPath))
    if ($Headless) { $arguments.Add('-Headless') }
    if ($Install -and @($Install).Count -gt 0) {
        $arguments.Add('-Install')
        $arguments.Add(('"{0}"' -f (@($Install) -join ',')))
    }
    if ($NoTweaks) {
        $arguments.Add('-NoTweaks')
    } elseif ($Tweaks -and @($Tweaks).Count -gt 0) {
        $arguments.Add('-Tweaks')
        $arguments.Add(('"{0}"' -f (@($Tweaks) -join ',')))
    }
    if ($Shortcuts) { $arguments.Add('-Shortcuts') }
    if ($DryRun) { $arguments.Add('-DryRun') }
    if ($Backend -and $Backend -ne 'direct') { $arguments.Add('-Backend'); $arguments.Add($Backend) }
    if ($ApplyOnly) { $arguments.Add('-ApplyOnly') }
    if ($UndoTweaks) { $arguments.Add('-UndoTweaks') }
    if ($Upgrade) { $arguments.Add('-Upgrade') }
    if ($Uninstall) { $arguments.Add('-Uninstall') }
    if ($ProgressFile) { $arguments.Add('-ProgressFile'); $arguments.Add(('"{0}"' -f $ProgressFile)) }
    if ($CancelFile) { $arguments.Add('-CancelFile'); $arguments.Add(('"{0}"' -f $CancelFile)) }
    if ($LogFile) { $arguments.Add('-LogFile'); $arguments.Add(('"{0}"' -f $LogFile)) }

    Start-Process -FilePath $launch.FileName -ArgumentList ($arguments -join ' ') -Verb RunAs | Out-Null
}

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
