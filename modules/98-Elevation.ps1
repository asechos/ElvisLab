# ============================================================================
# ElvisLab - Elevacion y relanzamiento
# ============================================================================

function Get-HostLaunchCommand {
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($exe).ToLowerInvariant()
    $isPowerShell = $baseName -in @('powershell', 'pwsh')

    $prefix = New-Object System.Collections.Generic.List[string]
    if ($isPowerShell) {
        if (-not $script:EntryScriptPath) { throw 'No se conoce la ruta del script para relanzar el proceso.' }
        $prefix.Add('-NoProfile')
        $prefix.Add('-ExecutionPolicy'); $prefix.Add('Bypass')
        $prefix.Add('-WindowStyle'); $prefix.Add('Hidden')
        if ($baseName -eq 'pwsh') { $prefix.Add('-STA') }
        $prefix.Add('-File'); $prefix.Add(('"{0}"' -f $script:EntryScriptPath))
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
    if ($HideConsole) { $arguments.Add('-HideConsole') }
    if ($Backend -and $Backend -ne 'direct') { $arguments.Add('-Backend'); $arguments.Add($Backend) }
    if ($ApplyOnly) { $arguments.Add('-ApplyOnly') }
    if ($UndoTweaks) { $arguments.Add('-UndoTweaks') }
    if ($Upgrade) { $arguments.Add('-Upgrade') }
    if ($UpgradeAll) { $arguments.Add('-UpgradeAll') }
    if ($WindowsUpdate) { $arguments.Add('-WindowsUpdate') }
    if ($Uninstall) { $arguments.Add('-Uninstall') }
    if ($ProgressFile) { $arguments.Add('-ProgressFile'); $arguments.Add(('"{0}"' -f $ProgressFile)) }
    if ($CancelFile) { $arguments.Add('-CancelFile'); $arguments.Add(('"{0}"' -f $CancelFile)) }
    if ($LogFile) { $arguments.Add('-LogFile'); $arguments.Add(('"{0}"' -f $LogFile)) }

    Start-Process -FilePath $launch.FileName -ArgumentList ($arguments -join ' ') -Verb RunAs | Out-Null
}
