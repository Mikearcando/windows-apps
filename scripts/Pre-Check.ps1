[CmdletBinding()]
param(
    [string]$SharePath,

    [ValidateSet("Server", "Client", "Beide")]
    [string]$Role = "Beide"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

$script:FailCount = 0
$script:WarnCount = 0
$script:PassCount = 0

# ── Uitvoerhulpfuncties ───────────────────────────────────────────────────────

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("  " + ([string][char]0x2500) * $Title.Length) -ForegroundColor DarkGray
}

function Write-Ok {
    param([string]$Label, [string]$Detail = "")
    Write-Host "  " -NoNewline
    Write-Host " OK " -BackgroundColor DarkGreen -ForegroundColor White -NoNewline
    Write-Host "  $Label" -ForegroundColor White
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    $script:PassCount++
}

function Write-Fail {
    param([string]$Label, [string]$Detail = "", [string]$Fix = "")
    Write-Host "  " -NoNewline
    Write-Host "FOUT" -BackgroundColor DarkRed -ForegroundColor White -NoNewline
    Write-Host "  $Label" -ForegroundColor Red
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    if ($Fix)    { Write-Host "         >> $Fix" -ForegroundColor Yellow }
    $script:FailCount++
}

function Write-Warn {
    param([string]$Label, [string]$Detail = "", [string]$Fix = "")
    Write-Host "  " -NoNewline
    Write-Host "WARN" -BackgroundColor DarkYellow -ForegroundColor Black -NoNewline
    Write-Host "  $Label" -ForegroundColor Yellow
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    if ($Fix)    { Write-Host "         >> $Fix" -ForegroundColor Yellow }
    $script:WarnCount++
}

function Write-Info {
    param([string]$Label, [string]$Detail = "")
    Write-Host "  " -NoNewline
    Write-Host "INFO" -BackgroundColor DarkCyan -ForegroundColor Black -NoNewline
    Write-Host "  $Label" -ForegroundColor DarkCyan
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
}

function Check {
    param(
        [string]$Label,
        [bool]$Passed,
        [string]$Detail = "",
        [string]$Fix = "",
        [switch]$WarnOnly
    )
    if ($Passed) { Write-Ok  -Label $Label -Detail $Detail }
    elseif ($WarnOnly) { Write-Warn -Label $Label -Detail $Detail -Fix $Fix }
    else { Write-Fail -Label $Label -Detail $Detail -Fix $Fix }
    return $Passed
}

# ── Header ────────────────────────────────────────────────────────────────────

Clear-Host
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "   WinAppDeploy — Pre-installatiecontrole" -ForegroundColor White
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "  Computer : $env:COMPUTERNAME" -ForegroundColor DarkGray
Write-Host "  Datum    : $(Get-Date -Format 'dd-MM-yyyy HH:mm')" -ForegroundColor DarkGray
Write-Host "  Rol      : $Role" -ForegroundColor DarkGray
if ($SharePath) {
    Write-Host "  SharePath: $SharePath" -ForegroundColor DarkGray
}

# ── Algemene controles ────────────────────────────────────────────────────────

Write-Section "Algemeen"

# PowerShell versie
$psVer = $PSVersionTable.PSVersion
$psOk  = $psVer.Major -gt 5 -or ($psVer.Major -eq 5 -and $psVer.Minor -ge 1)
Check "PowerShell versie ($($psVer.Major).$($psVer.Minor))" $psOk `
    -Fix "Installeer Windows Management Framework 5.1 of hoger"

if ($psVer.Major -ge 7) {
    Write-Warn "PowerShell 7 gedetecteerd" `
        "New-AppDeploymentManifest.ps1 vereist PowerShell 5.1 (powershell.exe)." `
        "Gebruik: powershell.exe -File .\scripts\New-AppDeploymentManifest.ps1 -SharePath '$SharePath'"
}

# Beheerderrechten
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Check "Beheerderrechten" $isAdmin `
    -Fix "Start PowerShell opnieuw: rechtermuisknop op PowerShell → Als administrator uitvoeren"

# ── Scriptbestanden ───────────────────────────────────────────────────────────

Write-Section "Scriptbestanden"

$requiredScripts = @(
    "New-AppDeploymentManifest.ps1"
    "AppDeploymentAgent.ps1"
    "Install-AppDeploymentAgent.ps1"
    "Uninstall-AppDeploymentAgent.ps1"
    "Start-DeploymentDashboard.ps1"
    "Install-DashboardService.ps1"
    "Uninstall-DashboardService.ps1"
    "Pre-Check.ps1"
)

$allScriptsOk = $true
foreach ($script in $requiredScripts) {
    $path = Join-Path $PSScriptRoot $script
    $ok   = Test-Path -LiteralPath $path
    if (-not $ok) { $allScriptsOk = $false }
    Check $script $ok -Fix "Controleer of het bestand aanwezig is in de scripts\ map"
}

# ── Servercontroles ───────────────────────────────────────────────────────────

if ($Role -eq "Server" -or $Role -eq "Beide") {
    Write-Section "Server"

    # Windows Installer COM (vereist voor manifest genereren)
    $comOk = $false
    try {
        $inst = New-Object -ComObject WindowsInstaller.Installer -ErrorAction Stop
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($inst)
        $comOk = $true
    } catch {}
    Check "Windows Installer COM beschikbaar" $comOk `
        -Fix "Windows Installer ontbreekt of is beschadigd. Controleer via: Get-Service msiserver"

    if (-not [string]::IsNullOrWhiteSpace($SharePath)) {
        # Share map zelf
        $shareExists = Test-Path -LiteralPath $SharePath
        Check "Share map bestaat ($SharePath)" $shareExists `
            -Fix "Maak aan: New-Item -ItemType Directory -Path '$SharePath' -Force"

        if ($shareExists) {
            # SMB share (alleen bij lokaal pad controleren)
            if (-not $SharePath.StartsWith("\\")) {
                $smbShare = Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $SharePath }
                Check "SMB share geconfigureerd" ($null -ne $smbShare) `
                    -Fix "Maak share: New-SmbShare -Name 'AppDeployment' -Path '$SharePath' -ReadAccess 'Domain Computers'" `
                    -WarnOnly
            }

            # Submappen
            $statusPath  = Join-Path $SharePath "status"
            $triggerPath = Join-Path $SharePath "triggers"

            Check "Submap 'status' bestaat" (Test-Path -LiteralPath $statusPath) `
                -Fix "Maak aan: New-Item -ItemType Directory -Path '$statusPath'"
            Check "Submap 'triggers' bestaat" (Test-Path -LiteralPath $triggerPath) `
                -Fix "Maak aan: New-Item -ItemType Directory -Path '$triggerPath'"

            # Schrijftoegang status map testen
            if (Test-Path -LiteralPath $statusPath) {
                $testFile = Join-Path $statusPath "_precheck_write_test.tmp"
                $writeOk  = $false
                try {
                    Set-Content -LiteralPath $testFile -Value "test" -Encoding UTF8 -ErrorAction Stop
                    Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
                    $writeOk = $true
                } catch {}
                Check "Submap 'status' schrijfbaar (huidig account)" $writeOk `
                    -Fix "Pas ACL aan (zie README sectie Sharetoegang)" -WarnOnly
            }

            # Manifest aanwezig
            $manifestPath = Join-Path $SharePath "apps.json"
            Check "Manifest apps.json aanwezig" (Test-Path -LiteralPath $manifestPath) `
                -Fix "Genereer manifest: powershell.exe -File .\scripts\New-AppDeploymentManifest.ps1 -SharePath '$SharePath'"

            if (Test-Path -LiteralPath $manifestPath) {
                # Manifest geldig JSON
                $manifestOk = $false
                try {
                    $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                    $manifestOk = $null -ne $m.packages
                    if ($manifestOk) {
                        Write-Info "Manifest bevat $(@($m.packages).Count) pakket(ten)"
                    }
                } catch {}
                Check "Manifest apps.json is geldig" $manifestOk `
                    -Fix "Genereer het manifest opnieuw via het dashboard of via New-AppDeploymentManifest.ps1"
            }
        }
    } else {
        Write-Warn "Geen -SharePath opgegeven" "Share-gerelateerde controles worden overgeslagen." `
            "Voer opnieuw uit met: .\Pre-Check.ps1 -SharePath 'D:\AppDeployment' -Role Server"
    }

    # Dashboard service (scheduled task)
    Write-Section "Dashboard service"

    $task = Get-ScheduledTask -TaskName "WinAppDeploy Dashboard" -ErrorAction SilentlyContinue
    $taskOk = Check "Scheduled task 'WinAppDeploy Dashboard' geregistreerd" ($null -ne $task) `
        -Fix "Installeer: .\scripts\Install-DashboardService.ps1 -SharePath '$SharePath' -StartNow"

    if ($taskOk) {
        $running = $task.State -eq "Running"
        Check "Dashboard service actief (status: $($task.State))" $running `
            -Fix "Start: Start-ScheduledTask -TaskName 'WinAppDeploy Dashboard'"

        # Server config
        $cfgPath = "C:\ProgramData\AppDeployment\server.config.json"
        Check "Serverconfiguratie aanwezig ($cfgPath)" (Test-Path -LiteralPath $cfgPath) `
            -Fix "Voer Install-DashboardService.ps1 opnieuw uit of maak het bestand handmatig aan"

        # HTTP bereikbaar
        if ($running) {
            $httpOk = $false
            try {
                $r = Invoke-WebRequest -Uri "http://localhost:8080/" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                $httpOk = $r.StatusCode -eq 200
            } catch {}
            Check "Dashboard bereikbaar op http://localhost:8080" $httpOk `
                -Fix "Controleer of de service draait en poort 8080 vrij is"
        }
    }
}

# ── Clientcontroles ───────────────────────────────────────────────────────────

if ($Role -eq "Client" -or $Role -eq "Beide") {
    Write-Section "Client"

    $installDir = "$env:ProgramData\AppDeployment"

    # Installatiemap
    Check "Installatiemap aanwezig ($installDir)" (Test-Path -LiteralPath $installDir) `
        -Fix "Voer Install-AppDeploymentAgent.ps1 uit op de client"

    # Agent script
    $agentScript = Join-Path $installDir "AppDeploymentAgent.ps1"
    Check "Agent script aanwezig" (Test-Path -LiteralPath $agentScript) `
        -Fix "Voer Install-AppDeploymentAgent.ps1 opnieuw uit"

    # Client config
    $clientCfg = Join-Path $installDir "client.config.json"
    $cfgExists  = Test-Path -LiteralPath $clientCfg
    Check "Clientconfiguratie aanwezig (client.config.json)" $cfgExists `
        -Fix "Voer Install-AppDeploymentAgent.ps1 opnieuw uit"

    if ($cfgExists) {
        $cfgOk = $false
        $cfgShare = ""
        try {
            $cfg = Get-Content -LiteralPath $clientCfg -Raw | ConvertFrom-Json
            $cfgShare = $cfg.SharePath
            $cfgOk = -not [string]::IsNullOrWhiteSpace($cfgShare)
        } catch {}
        Check "Clientconfiguratie bevat SharePath" $cfgOk `
            -Fix "Bewerk $clientCfg en stel SharePath in op het UNC-pad van de server"
        if ($cfgOk) { Write-Info "SharePath in config: $cfgShare" }
    }

    # Log map
    $logPath = "$env:ProgramData\AppDeployment\Logs"
    Check "Log map aanwezig" (Test-Path -LiteralPath $logPath) -WarnOnly `
        -Fix "Wordt automatisch aangemaakt bij de eerste agentrun"

    # Scheduled task agent
    $agentTask = Get-ScheduledTask -TaskName "WinAppDeploy Agent" -ErrorAction SilentlyContinue
    $taskOk    = Check "Scheduled task 'WinAppDeploy Agent' geregistreerd" ($null -ne $agentTask) `
        -Fix "Voer Install-AppDeploymentAgent.ps1 opnieuw uit als administrator"

    if ($taskOk) {
        $validState = @("Ready","Running") -contains $agentTask.State
        Check "Agent task heeft geldige status ($($agentTask.State))" $validState `
            -Fix "Controleer de task in Taakplanner en start hem handmatig als test"
    }

    # Share bereikbaar vanuit client
    $checkShare = if (-not [string]::IsNullOrWhiteSpace($SharePath)) { $SharePath }
                  elseif ($cfgShare) { $cfgShare }
                  else { $null }

    if ($checkShare) {
        Write-Section "Sharetoegang (client)"

        $shareOk = Check "Share bereikbaar ($checkShare)" (Test-Path -LiteralPath $checkShare) `
            -Fix "Controleer netwerktoegang en sharerechten op de server"

        if ($shareOk) {
            $mfPath = Join-Path $checkShare "apps.json"
            Check "Manifest apps.json leesbaar" (Test-Path -LiteralPath $mfPath) `
                -Fix "Genereer het manifest op de server: New-AppDeploymentManifest.ps1 -SharePath '$checkShare'"

            # Status map schrijfbaar
            $statusPath = Join-Path $checkShare "status"
            if (Test-Path -LiteralPath $statusPath) {
                $testFile = Join-Path $statusPath "_precheck_$env:COMPUTERNAME.tmp"
                $writeOk  = $false
                try {
                    Set-Content -LiteralPath $testFile -Value "test" -Encoding UTF8 -ErrorAction Stop
                    Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
                    $writeOk = $true
                } catch {}
                Check "Status map schrijfbaar (\\...\status)" $writeOk `
                    -Fix "Vraag de serverbeheerder om schrijftoegang op de status map (zie README)"
            } else {
                Check "Status map aanwezig (\\...\status)" $false `
                    -Fix "Laat de serverbeheerder de status map aanmaken op de share"
            }

            # Triggers map schrijfbaar
            $triggerPath = Join-Path $checkShare "triggers"
            if (Test-Path -LiteralPath $triggerPath) {
                $testFile = Join-Path $triggerPath "_precheck_$env:COMPUTERNAME.tmp"
                $writeOk  = $false
                try {
                    Set-Content -LiteralPath $testFile -Value "test" -Encoding UTF8 -ErrorAction Stop
                    Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
                    $writeOk = $true
                } catch {}
                Check "Triggers map schrijfbaar (\\...\triggers)" $writeOk `
                    -Fix "Vraag de serverbeheerder om schrijftoegang op de triggers map (zie README)"
            } else {
                Check "Triggers map aanwezig (\\...\triggers)" $false `
                    -Fix "Laat de serverbeheerder de triggers map aanmaken op de share"
            }
        }
    } else {
        Write-Warn "Geen SharePath bekend" `
            "Sharecontroles worden overgeslagen." `
            "Voer opnieuw uit met: .\Pre-Check.ps1 -SharePath '\\SERVER\AppDeployment' -Role Client"
    }
}

# ── Samenvatting ──────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "   Resultaat" -ForegroundColor White
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host ""

if ($script:PassCount -gt 0) {
    Write-Host "   Geslaagd  : $($script:PassCount)" -ForegroundColor Green
}
if ($script:WarnCount -gt 0) {
    Write-Host "   Waarsch.  : $($script:WarnCount)" -ForegroundColor Yellow
}
if ($script:FailCount -gt 0) {
    Write-Host "   Mislukt   : $($script:FailCount)" -ForegroundColor Red
}

Write-Host ""

if ($script:FailCount -eq 0 -and $script:WarnCount -eq 0) {
    Write-Host "   Alles in orde! WinAppDeploy is correct geconfigureerd." -ForegroundColor Green
} elseif ($script:FailCount -eq 0) {
    Write-Host "   Klaar met waarschuwingen. Controleer de punten hierboven." -ForegroundColor Yellow
} else {
    Write-Host "   Er zijn $($script:FailCount) probleem/problemen gevonden." -ForegroundColor Red
    Write-Host "   Volg de >> aanwijzingen hierboven om ze op te lossen." -ForegroundColor Yellow
}

Write-Host ""

exit $script:FailCount
