#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SharePath,

    [string]$ConfigPath   = "C:\ProgramData\AppDeployment\server.config.json",
    [string]$ManifestFile = "apps.json",
    [string]$LogPath      = "C:\ProgramData\AppDeployment\Logs",
    [int]$Port            = 8080,
    [string]$TaskName     = "WinAppDeploy Dashboard",
    [switch]$StartNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Config schrijven ──────────────────────────────────────────────────────────

$configDir = Split-Path $ConfigPath -Parent
New-Item -ItemType Directory -Path $configDir -Force | Out-Null

$serverConfig = [ordered]@{
    SharePath    = $SharePath
    ManifestFile = $ManifestFile
    LogPath      = $LogPath
    Port         = $Port
}
$serverConfig | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Write-Host "Configuratie geschreven: $ConfigPath"

# ── Scheduled task registreren ────────────────────────────────────────────────

$dashboardScript = Join-Path $PSScriptRoot "Start-DeploymentDashboard.ps1"
if (-not (Test-Path -LiteralPath $dashboardScript)) {
    throw "Dashboard script niet gevonden: $dashboardScript"
}

$psArgs = "-NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dashboardScript`" -ConfigPath `"$ConfigPath`" -NoOpenBrowser"

$action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([timespan]::Zero) `
    -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 2) `
    -StartWhenAvailable $true `
    -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Bestaande taak verwijderd."
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
Write-Host "Scheduled task geregistreerd: '$TaskName'"

if ($StartNow) {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
    $state = (Get-ScheduledTask -TaskName $TaskName).State
    Write-Host "Dashboard gestart (status: $state)"
}

Write-Host ""
Write-Host "  Installatie voltooid"
Write-Host "  ===================="
Write-Host "  Task     : $TaskName"
Write-Host "  Config   : $ConfigPath"
Write-Host "  Dashboard: http://localhost:$Port/"
Write-Host ""
Write-Host "  Het dashboard start automatisch bij het opstarten van Windows."
Write-Host "  Gebruik -StartNow om direct te starten, of:"
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
