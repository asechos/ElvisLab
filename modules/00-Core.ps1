# ============================================================================
# ElvisLab - Utilidades base, rutas, registro y logging
# ============================================================================

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

function Hide-ElvisConsole {
    try {
        if (-not ('ElvisConsoleWindow' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ElvisConsoleWindow {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
        }
        $handle = [ElvisConsoleWindow]::GetConsoleWindow()
        if ($handle -ne [IntPtr]::Zero) {
            [ElvisConsoleWindow]::ShowWindow($handle, 0) | Out-Null
        }
    } catch { }
}

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
