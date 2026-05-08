[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SharePath,

    [ValidateNotNullOrEmpty()]
    [string]$ManifestFile = "apps.json",

    [ValidateRange(5, 1440)]
    [int]$ScheduleMinutes = 60,

    [ValidateNotNullOrEmpty()]
    [string]$InstallRoot = "$env:ProgramData\AppDeployment",

    [ValidateNotNullOrEmpty()]
    [string]$DefaultMsiArguments = "/qn /norestart",

    [switch]$NoCache,

    [switch]$RunNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $administratorRole = [Security.Principal.WindowsBuiltInRole]::Administrator

    if (-not $principal.IsInRole($administratorRole)) {
        throw "Voer dit script uit als administrator."
    }
}

Assert-Administrator

$agentSourcePath = Join-Path $PSScriptRoot "AppDeploymentAgent.ps1"
if (-not (Test-Path -LiteralPath $agentSourcePath)) {
    throw "Agent script niet gevonden naast installer: $agentSourcePath"
}

$logsPath = Join-Path $InstallRoot "Logs"
$cachePath = Join-Path $InstallRoot "Cache"
$agentTargetPath = Join-Path $InstallRoot "AppDeploymentAgent.ps1"
$configPath = Join-Path $InstallRoot "client.config.json"
$taskName = "WinAppDeploy Agent"

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
New-Item -ItemType Directory -Path $cachePath -Force | Out-Null

Copy-Item -LiteralPath $agentSourcePath -Destination $agentTargetPath -Force

$config = [ordered]@{
    SharePath           = $SharePath
    ManifestFile        = $ManifestFile
    DefaultMsiArguments = $DefaultMsiArguments
    CachePath           = $cachePath
    LogPath             = $logsPath
    CopyToCache         = (-not $NoCache.IsPresent)
    AllowDowngrade      = $false
    SuccessExitCodes    = @(0, 3010, 1641)
}

$config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8

$taskArgument = "-NoProfile -ExecutionPolicy Bypass -File `"$agentTargetPath`" -ConfigPath `"$configPath`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgument
$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $ScheduleMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($startupTrigger, $repeatTrigger) -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Agent geinstalleerd in: $InstallRoot"
Write-Host "Config geschreven: $configPath"
Write-Host "Scheduled task geregistreerd: $taskName"

if ($RunNow) {
    Start-ScheduledTask -TaskName $taskName
    Write-Host "Scheduled task gestart."
}
