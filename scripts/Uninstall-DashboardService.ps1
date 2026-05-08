#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$TaskName = "WinAppDeploy Dashboard"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host "Taak '$TaskName' niet gevonden, niets te verwijderen."
    return
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false

Write-Host "Dashboardservice verwijderd: '$TaskName'"
