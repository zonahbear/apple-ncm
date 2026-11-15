#requires -Version 5.1
param([ValidateSet('Preflight','Install','Run','Rollback','Diagnostics')][string]$Action = 'Preflight')
$ErrorActionPreference = 'Stop'
try {
    $scriptPath = Join-Path $PSScriptRoot 'AppleNcm.ps1'
    if ($Action -in @('Install','Run','Rollback')) {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f $scriptPath,$Action
        $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Operation exited with code $($p.ExitCode). Review the administrator window/log." }
    } else { & $scriptPath -Action $Action }
} catch { Write-Host $_.Exception.Message -ForegroundColor Red }
Write-Host 'Press Enter to close.'
$null = Read-Host
