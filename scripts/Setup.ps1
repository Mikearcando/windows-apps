#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet("Server", "Client", "Auto")]
    [string]$Mode = "Auto",

    [string]$SharePath,
    [string]$ShareName     = "AppDeployment",
    [string]$AccessAccount,
    [int]$Port             = 8080,
    [switch]$StartNow,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ScriptsDir = $PSScriptRoot
$script:Errors     = @()

# ── Uitvoer ───────────────────────────────────────────────────────────────────

function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  +--------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |        WinAppDeploy  Setup           |" -ForegroundColor Cyan
    Write-Host "  |  Versie 1.0  -  $env:COMPUTERNAME$((' ' * [Math]::Max(0,17-$env:COMPUTERNAME.Length)))|" -ForegroundColor Cyan
    Write-Host "  +--------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section { param([string]$T)
    Write-Host ""; Write-Host "  $T" -ForegroundColor White
    Write-Host ("  " + ("-" * $T.Length)) -ForegroundColor DarkGray
}

function Write-Ok   { param([string]$T) Write-Host "   [OK]  $T" -ForegroundColor Green }
function Write-Fail { param([string]$T) Write-Host "   [!!]  $T" -ForegroundColor Red }
function Write-Info { param([string]$T) Write-Host "    >>   $T" -ForegroundColor DarkGray }
function Write-Warn { param([string]$T) Write-Host "   [??]  $T" -ForegroundColor Yellow }

function Read-Input {
    param([string]$Prompt, [string]$Default = "")
    $hint = if ($Default) { " [$Default]" } else { "" }
    Write-Host "  > $Prompt$hint : " -ForegroundColor Cyan -NoNewline
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim()
}

function Confirm-Action {
    param([string]$Prompt)
    if ($Force) { return $true }
    Write-Host "  > $Prompt [J/n] : " -ForegroundColor Yellow -NoNewline
    $r = Read-Host
    return ($r -eq "" -or $r -match "^[jJyY]")
}

function Show-Summary {
    param([hashtable]$Settings)
    Write-Host ""
    Write-Host "  +--------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host "  |  Instellingen                                    |" -ForegroundColor White
    Write-Host "  +--------------------------------------------------+" -ForegroundColor DarkGray
    foreach ($kv in $Settings.GetEnumerator() | Sort-Object Name) {
        $k = $kv.Name.PadRight(18)
        $v = [string]$kv.Value
        if ($v.Length -gt 28) { $v = $v.Substring(0,25) + "..." }
        Write-Host "  |  $k : $($v.PadRight(28)) |" -ForegroundColor Gray
    }
    Write-Host "  +--------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host ""
}

function Require-Script {
    param([string]$Name)
    $path = Join-Path $script:ScriptsDir $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Script niet gevonden: $path`n  Zorg dat Setup.ps1 in de scripts-map staat naast de andere scripts."
    }
    return $path
}

function Run-Step {
    param([string]$Label, [scriptblock]$Action)
    try {
        & $Action | Out-Null
        Write-Ok $Label
        return $true
    } catch {
        Write-Fail "$Label"
        Write-Info $_.Exception.Message
        $script:Errors += $Label
        return $false
    }
}

# ── Systeeminfo ophalen ───────────────────────────────────────────────────────

function Get-SystemInfo {
    $info = @{
        ComputerName = $env:COMPUTERNAME
        IsDomain     = $false
        Domain       = ""
        BestDrive    = "C"
    }

    try {
        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs) {
            $info.IsDomain = [bool]$cs.PartOfDomain
            $info.Domain   = if ($cs.PartOfDomain) { $cs.Domain } else { "" }
        }
    } catch {}

    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match "^[C-Z]$" -and $_.Free -ne $null -and $_.Free -gt 500MB } |
                  Sort-Object Free -Descending
        if ($drives) { $info.BestDrive = $drives[0].Name }
    } catch {}

    return $info
}

# ── Mode kiezen ───────────────────────────────────────────────────────────────

function Select-SetupMode {
    Write-Host "  Wat wil je doen?" -ForegroundColor White
    Write-Host ""
    Write-Host "   [1]  Server  — share, rechten, manifest en dashboard installeren" -ForegroundColor Cyan
    Write-Host "   [2]  Client  — deployment agent installeren op deze computer" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  > Keuze [1/2] : " -ForegroundColor Yellow -NoNewline
    $choice = (Read-Host).Trim()
    switch ($choice) {
        "1" { return "Server" }
        "2" { return "Client" }
        default { Write-Warn "Ongeldige keuze, probeer opnieuw."; return Select-SetupMode }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  SERVER SETUP
# ══════════════════════════════════════════════════════════════════════════════

function Start-ServerSetup {
    $sys = Get-SystemInfo

    Write-Section "Serverinstellingen opgeven"

    if ($sys.IsDomain) {
        Write-Ok "Domein gedetecteerd: $($sys.Domain)"
    } else {
        Write-Warn "Geen domein — werkgroepomgeving gedetecteerd."
    }

    # Lokaal pad voor de share
    $defaultLocalPath = "$($sys.BestDrive):\AppDeployment"
    $localPath = if (-not [string]::IsNullOrWhiteSpace($SharePath)) {
        Write-Info "Share pad: $SharePath"
        $SharePath
    } else {
        Read-Input "Lokaal pad voor de share" $defaultLocalPath
    }

    # SMB share-naam
    $smbName = Read-Input "SMB share-naam" $ShareName

    # Toegangsaccount
    $defaultAccount = if ($sys.IsDomain) { "Domain Computers" } else { "Everyone" }
    $account = if (-not [string]::IsNullOrWhiteSpace($AccessAccount)) {
        Write-Info "Account: $AccessAccount"
        $AccessAccount
    } else {
        Read-Input "Account voor schrijftoegang (status + triggers)" $defaultAccount
    }

    # Poort
    $portNum = $Port
    if (-not $Force) {
        $portInput = Read-Input "Dashboard poort" "$portNum"
        if ($portInput -match "^\d+$") { $portNum = [int]$portInput }
    }

    $uncPath = "\\$($sys.ComputerName)\$smbName"

    Show-Summary @{
        "Lokaal pad"   = $localPath
        "Share naam"   = $smbName
        "UNC pad"      = $uncPath
        "Account"      = $account
        "Poort"        = $portNum
        "Dashboard"    = "http://localhost:$portNum"
    }

    if (-not (Confirm-Action "Starten met installatie?")) {
        Write-Host "  Geannuleerd." -ForegroundColor Yellow; return
    }

    # ── Stap 1: Mappen aanmaken ───────────────────────────────────────────────

    Write-Section "Stap 1: Mappen aanmaken"
    Run-Step "Map aangemaakt: $localPath" {
        New-Item -ItemType Directory -Path $localPath                    -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $localPath "status")   -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $localPath "triggers") -Force | Out-Null
    }

    # ── Stap 2: SMB share ─────────────────────────────────────────────────────

    Write-Section "Stap 2: SMB share"
    $existing = Get-SmbShare -Name $smbName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Info "Share '$smbName' bestaat al op pad: $($existing.Path)"
        if ($existing.Path -ne $localPath -and $existing.Path -ne ($localPath.TrimEnd('\'))) {
            Write-Warn "Share wijst naar een ander pad. Verwijder de share handmatig en start opnieuw als je dit wilt wijzigen."
        } else {
            Write-Ok "Bestaande share hergebruikt"
        }
    } else {
        Run-Step "SMB share '$smbName' aangemaakt (leestoegang: $account)" {
            New-SmbShare -Name $smbName -Path $localPath -ReadAccess $account | Out-Null
        }
    }

    # ── Stap 3: Schrijftoegang ────────────────────────────────────────────────

    Write-Section "Stap 3: Schrijftoegang instellen"
    Run-Step "Schrijftoegang voor '$account' op status + triggers" {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $account, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
        foreach ($sub in @("status","triggers")) {
            $p = Join-Path $localPath $sub
            if (Test-Path -LiteralPath $p) {
                $acl = Get-Acl -Path $p
                $acl.AddAccessRule($rule)
                Set-Acl -Path $p -AclObject $acl
            }
        }
    }

    # ── Stap 4: Manifest genereren ────────────────────────────────────────────

    Write-Section "Stap 4: Manifest genereren"
    $manifestScript = Require-Script "New-AppDeploymentManifest.ps1"
    $msiFiles = @(Get-ChildItem -LiteralPath $localPath -Recurse -Filter "*.msi" -File -ErrorAction SilentlyContinue)

    if ($msiFiles.Count -gt 0) {
        Run-Step "Manifest gegenereerd ($($msiFiles.Count) MSI-bestanden gevonden)" {
            $out = powershell.exe -NonInteractive -ExecutionPolicy Bypass -File $manifestScript -SharePath $localPath 2>&1
            $out | ForEach-Object { Write-Info $_ }
        }
    } else {
        Write-Warn "Geen MSI-bestanden gevonden — manifest overgeslagen."
        Write-Info "Plaats MSI-bestanden in $localPath en gebruik het dashboard (Pakketten > Opnieuw genereren)."
    }

    # ── Stap 5: Dashboard service ─────────────────────────────────────────────

    Write-Section "Stap 5: Dashboard installeren"
    $dashScript = Require-Script "Install-DashboardService.ps1"
    $doStart = $StartNow -or (Confirm-Action "Dashboard direct starten?")

    Run-Step "Dashboard service geregistreerd als scheduled task" {
        $psArgs = "-NonInteractive -ExecutionPolicy Bypass -File `"$dashScript`" -SharePath `"$uncPath`" -Port $portNum"
        if ($doStart) { $psArgs += " -StartNow" }
        $proc = Start-Process powershell.exe -ArgumentList $psArgs -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) { throw "Install-DashboardService.ps1 eindigde met exitcode $($proc.ExitCode)" }
    }

    # ── Resultaat ─────────────────────────────────────────────────────────────

    Write-Host ""
    if ($script:Errors.Count -eq 0) {
        Write-Host "  +--------------------------------------------------+" -ForegroundColor Green
        Write-Host "  |   Server installatie geslaagd!                   |" -ForegroundColor Green
        Write-Host "  +--------------------------------------------------+" -ForegroundColor Green
    } else {
        Write-Host "  +--------------------------------------------------+" -ForegroundColor Yellow
        Write-Host "  |   Installatie voltooid met waarschuwingen         |" -ForegroundColor Yellow
        Write-Host "  +--------------------------------------------------+" -ForegroundColor Yellow
        foreach ($e in $script:Errors) { Write-Warn "Niet geslaagd: $e" }
    }
    Write-Host ""
    Write-Host "  Dashboard  : http://localhost:$portNum" -ForegroundColor Cyan
    Write-Host "  Share      : $uncPath" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Client installeren — voer uit op elke client als administrator:" -ForegroundColor White
    Write-Host ""
    Write-Host "  powershell.exe -File .\scripts\Setup.ps1" -ForegroundColor Yellow
    Write-Host "  (kies [2] Client op de clientcomputer)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Of direct:" -ForegroundColor DarkGray
    Write-Host "  .\scripts\Install-AppDeploymentAgent.ps1 -SharePath `"$uncPath`" -RunNow" -ForegroundColor DarkGray
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  CLIENT SETUP
# ══════════════════════════════════════════════════════════════════════════════

function Start-ClientSetup {
    $sys = Get-SystemInfo

    Write-Section "Clientinstellingen opgeven"

    # Auto-discovery: zoek naar een AppDeployment share op de DC of via NetBIOS
    $discovered = ""
    if ($sys.IsDomain -and [string]::IsNullOrWhiteSpace($SharePath)) {
        Write-Info "Zoeken naar AppDeployment share in domein $($sys.Domain)..."
        try {
            $dc = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).FindDomainController().Name
            $testPath = "\\$dc\AppDeployment"
            if (Test-Path -LiteralPath $testPath -ErrorAction SilentlyContinue) {
                $discovered = $testPath
                Write-Ok "Share automatisch gevonden: $discovered"
            }
        } catch {}
    }

    # Share pad ophalen
    $uncPath = if (-not [string]::IsNullOrWhiteSpace($SharePath)) {
        Write-Info "Share pad: $SharePath"
        $SharePath
    } elseif ($discovered) {
        $ans = Read-Input "UNC-pad naar de share" $discovered
        $ans
    } else {
        Read-Input "UNC-pad naar de server share (bv \\SERVER\AppDeployment)" ""
    }

    if ([string]::IsNullOrWhiteSpace($uncPath)) {
        Write-Fail "Geen share pad opgegeven. Installatie afgebroken."
        return
    }

    # Bereikbaarheid testen
    Write-Info "Verbinding testen: $uncPath"
    $reachable = Test-Path -LiteralPath $uncPath -ErrorAction SilentlyContinue
    if ($reachable) {
        Write-Ok "Share bereikbaar"
    } else {
        Write-Warn "Share niet bereikbaar: $uncPath"
        Write-Info "Mogelijke oorzaken: servernaam klopt niet, geen netwerktoegang, of share bestaat nog niet."
        if (-not (Confirm-Action "Toch doorgaan met installatie?")) {
            Write-Host "  Geannuleerd." -ForegroundColor Yellow; return
        }
    }

    Show-Summary @{
        "Share pad"    = $uncPath
        "Install map"  = "C:\ProgramData\AppDeployment"
        "Scheduled task" = "WinAppDeploy Agent"
        "Interval"     = "60 minuten"
    }

    if (-not (Confirm-Action "Agent installeren op $($sys.ComputerName)?")) {
        Write-Host "  Geannuleerd." -ForegroundColor Yellow; return
    }

    # ── Stap 1: Agent installeren ─────────────────────────────────────────────

    Write-Section "Stap 1: Agent installeren"
    $installScript = Require-Script "Install-AppDeploymentAgent.ps1"
    $doRun = $StartNow -or (Confirm-Action "Agent direct uitvoeren na installatie?")

    Run-Step "Agent geinstalleerd en scheduled task geregistreerd" {
        $psArgs = "-NonInteractive -ExecutionPolicy Bypass -File `"$installScript`" -SharePath `"$uncPath`""
        if ($doRun) { $psArgs += " -RunNow" }
        $proc = Start-Process powershell.exe -ArgumentList $psArgs -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) { throw "Install-AppDeploymentAgent.ps1 eindigde met exitcode $($proc.ExitCode)" }
    }

    # ── Resultaat ─────────────────────────────────────────────────────────────

    Write-Host ""
    if ($script:Errors.Count -eq 0) {
        Write-Host "  +--------------------------------------------------+" -ForegroundColor Green
        Write-Host "  |   Client installatie geslaagd!                   |" -ForegroundColor Green
        Write-Host "  +--------------------------------------------------+" -ForegroundColor Green
    } else {
        Write-Host "  +--------------------------------------------------+" -ForegroundColor Yellow
        Write-Host "  |   Installatie voltooid met waarschuwingen         |" -ForegroundColor Yellow
        Write-Host "  +--------------------------------------------------+" -ForegroundColor Yellow
        foreach ($e in $script:Errors) { Write-Warn "Niet geslaagd: $e" }
    }
    Write-Host ""
    Write-Host "  Computer   : $($sys.ComputerName)" -ForegroundColor Cyan
    Write-Host "  Share      : $uncPath" -ForegroundColor Cyan
    Write-Host "  Logs       : C:\ProgramData\AppDeployment\Logs\" -ForegroundColor Cyan
    Write-Host ""
    if ($doRun) {
        Write-Host "  De agent is uitgevoerd en de computer verschijnt in het dashboard." -ForegroundColor Gray
    } else {
        Write-Host "  De agent draait automatisch elke 60 minuten (en bij elke reboot)." -ForegroundColor Gray
    }
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  HOOFDPROGRAMMA
# ══════════════════════════════════════════════════════════════════════════════

Write-Header

$resolvedMode = $Mode
if ($resolvedMode -eq "Auto") {
    $resolvedMode = Select-SetupMode
}

switch ($resolvedMode) {
    "Server" { Start-ServerSetup }
    "Client" { Start-ClientSetup }
}
