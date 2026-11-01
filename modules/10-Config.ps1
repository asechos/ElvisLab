# ============================================================================
# ElvisLab - Lectura y validacion de config.json
# ============================================================================

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
