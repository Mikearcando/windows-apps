[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$InstallRoot = "$env:ProgramData\AppDeployment",

    [switch]$KeepLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$taskName = "WinAppDeploy Agent"

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($taskName, "Unregister scheduled task")) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Scheduled task verwijderd: $taskName"
    }
}

if (Test-Path -LiteralPath $InstallRoot) {
    if ($KeepLogs) {
        $agentPath = Join-Path $InstallRoot "AppDeploymentAgent.ps1"
        $configPath = Join-Path $InstallRoot "client.config.json"
        $cachePath = Join-Path $InstallRoot "Cache"

        foreach ($path in @($agentPath, $configPath, $cachePath)) {
            if (Test-Path -LiteralPath $path) {
                if ($PSCmdlet.ShouldProcess($path, "Remove")) {
                    Remove-Item -LiteralPath $path -Recurse -Force
                }
            }
        }

        Write-Host "Agent verwijderd; logs behouden in: $(Join-Path $InstallRoot 'Logs')"
    }
    else {
        if ($PSCmdlet.ShouldProcess($InstallRoot, "Remove install root")) {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force
            Write-Host "Installatiemap verwijderd: $InstallRoot"
        }
    }
}
