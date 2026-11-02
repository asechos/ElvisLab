# ============================================================================
# ElvisLab - Genera los paquetes para publicar
# ============================================================================
[CmdletBinding()]
param(
    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $root 'dist' }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

function New-ElvisLabZip {
    param(
        [string]$Destination,
        [string[]]$Items
    )

    $stage = Join-Path $env:TEMP ('ElvisLab-package-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    try {
        foreach ($item in $Items) {
            $source = Join-Path $root $item
            if (-not (Test-Path -LiteralPath $source)) {
                throw "No se encontro $source"
            }
            Copy-Item -LiteralPath $source -Destination $stage -Recurse -Force
        }

        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Force
        }
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Destination -Force
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$sourceZip = Join-Path $OutputDir 'ElvisLab.zip'
$sourceItems = @('ElvisLab.ps1', 'config.json', 'modules')
if (Test-Path -LiteralPath (Join-Path $root 'Resources')) { $sourceItems += 'Resources' }
New-ElvisLabZip -Destination $sourceZip -Items $sourceItems
Write-Host "OK: $sourceZip" -ForegroundColor Green

$exePath = Join-Path $root 'ElvisLab.exe'
$exeConfigPath = Join-Path $root 'ElvisLab.exe.config'
if ((Test-Path -LiteralPath $exePath) -and (Test-Path -LiteralPath $exeConfigPath)) {
    $portableZip = Join-Path $OutputDir 'ElvisLab-portable.zip'
    $portableItems = @('ElvisLab.exe', 'ElvisLab.exe.config', 'config.json')
    if (Test-Path -LiteralPath (Join-Path $root 'Resources')) { $portableItems += 'Resources' }
    New-ElvisLabZip -Destination $portableZip -Items $portableItems
    Write-Host "OK: $portableZip" -ForegroundColor Green
}

Get-ChildItem -Path $OutputDir -Filter '*.zip' | Select-Object Name, Length | Format-Table -AutoSize
