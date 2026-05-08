[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = "$env:ProgramData\AppDeployment\client.config.json",

    [switch]$WhatIfInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ObjectValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )

    $line = "{0} [{1}] {2}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line

    if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
}

function ConvertTo-VersionOrNull {
    param([AllowNull()][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }

    $parsedVersion = $null
    if ([version]::TryParse($Version, [ref]$parsedVersion)) { return $parsedVersion }

    $matches = [regex]::Matches($Version, "\d+")
    if ($matches.Count -eq 0) { return $null }

    $parts = @()
    foreach ($match in $matches) {
        $parts += [int]$match.Value
        if ($parts.Count -eq 4) { break }
    }
    while ($parts.Count -lt 4) { $parts += 0 }

    try { return New-Object System.Version -ArgumentList $parts[0], $parts[1], $parts[2], $parts[3] }
    catch { return $null }
}

function Resolve-PackageSource {
    param(
        [Parameter(Mandatory = $true)][string]$SharePath,
        [Parameter(Mandatory = $true)][string]$Source
    )
    if ([System.IO.Path]::IsPathRooted($Source)) { return $Source }
    return Join-Path $SharePath $Source
}

function Get-RegistryInstalledPackage {
    param(
        [AllowNull()][string]$ProductCode,
        [AllowNull()][string]$Name
    )

    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    if (-not [string]::IsNullOrWhiteSpace($ProductCode)) {
        foreach ($root in $roots) {
            $path = Join-Path $root $ProductCode
            if (Test-Path -LiteralPath $path) {
                $item = Get-ItemProperty -LiteralPath $path
                return [pscustomobject]@{
                    ProductCode  = $ProductCode
                    Name         = Get-ObjectValue -Object $item -Name "DisplayName"
                    Version      = Get-ObjectValue -Object $item -Name "DisplayVersion"
                    RegistryPath = $path
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        foreach ($root in $roots) {
            $keys = Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue
            foreach ($key in $keys) {
                try { $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop }
                catch { continue }

                $displayName = Get-ObjectValue -Object $item -Name "DisplayName"
                if ($displayName -eq $Name) {
                    return [pscustomobject]@{
                        ProductCode  = Get-ObjectValue -Object $item -Name "PSChildName"
                        Name         = $displayName
                        Version      = Get-ObjectValue -Object $item -Name "DisplayVersion"
                        RegistryPath = $key.PSPath
                    }
                }
            }
        }
    }

    return $null
}

function Test-ShouldInstallPackage {
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [AllowNull()][object]$InstalledPackage,
        [bool]$AllowDowngrade
    )

    if ([bool](Get-ObjectValue -Object $Package -Name "forceInstall" -Default $false)) {
        return [pscustomobject]@{ ShouldInstall = $true; Reason = "forceInstall staat aan" }
    }

    if ($null -eq $InstalledPackage) {
        return [pscustomobject]@{ ShouldInstall = $true; Reason = "niet geinstalleerd" }
    }

    $targetVersionText = Get-ObjectValue -Object $Package -Name "version"
    $currentVersionText = Get-ObjectValue -Object $InstalledPackage -Name "Version"
    $targetVersion = ConvertTo-VersionOrNull -Version $targetVersionText
    $currentVersion = ConvertTo-VersionOrNull -Version $currentVersionText

    if ($null -eq $targetVersion -or $null -eq $currentVersion) {
        return [pscustomobject]@{ ShouldInstall = $false; Reason = "al geinstalleerd; versie niet vergelijkbaar" }
    }

    if ($targetVersion -gt $currentVersion) {
        return [pscustomobject]@{ ShouldInstall = $true; Reason = "update beschikbaar $currentVersionText -> $targetVersionText" }
    }

    if ($AllowDowngrade -and $targetVersion -ne $currentVersion) {
        return [pscustomobject]@{ ShouldInstall = $true; Reason = "versie afwijkt $currentVersionText -> $targetVersionText" }
    }

    return [pscustomobject]@{ ShouldInstall = $false; Reason = "al op versie $currentVersionText" }
}

function Copy-PackageToCache {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][string]$PackageId
    )

    $packageCachePath = Join-Path $CachePath $PackageId
    New-Item -ItemType Directory -Path $packageCachePath -Force | Out-Null
    $targetPath = Join-Path $packageCachePath (Split-Path -Path $SourcePath -Leaf)
    Copy-Item -LiteralPath $SourcePath -Destination $targetPath -Force
    return $targetPath
}

function Invoke-MsiInstall {
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][int[]]$SuccessExitCodes,
        [bool]$PreviewOnly
    )

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $msiLogPath = Join-Path $LogPath ("msi-{0}-{1}.log" -f $PackageId, $timestamp)
    $argumentLine = "/i `"$MsiPath`" $Arguments /L*v `"$msiLogPath`""

    if ($PreviewOnly) {
        Write-Log "Preview: msiexec.exe $argumentLine"
        return 0
    }

    Write-Log "Start installatie: $PackageId"
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $argumentLine -Wait -PassThru -WindowStyle Hidden
    $exitCode = [int]$process.ExitCode

    if ($SuccessExitCodes -contains $exitCode) {
        if ($exitCode -eq 3010 -or $exitCode -eq 1641) {
            Write-Log "Installatie gelukt met reboot-indicatie. Package=$PackageId ExitCode=$exitCode MsiLog=$msiLogPath" "WARN"
        } else {
            Write-Log "Installatie gelukt. Package=$PackageId ExitCode=$exitCode MsiLog=$msiLogPath"
        }
        return $exitCode
    }

    Write-Log "Installatie mislukt. Package=$PackageId ExitCode=$exitCode MsiLog=$msiLogPath" "ERROR"
    return $exitCode
}

# ── Config laden ─────────────────────────────────────────────────────────────

$script:LogFile = $null

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configbestand niet gevonden: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$sharePath = Get-ObjectValue -Object $config -Name "SharePath"
if ([string]::IsNullOrWhiteSpace($sharePath)) { throw "Config mist verplichte waarde: SharePath" }

$manifestFile        = Get-ObjectValue -Object $config -Name "ManifestFile"        -Default "apps.json"
$defaultMsiArguments = Get-ObjectValue -Object $config -Name "DefaultMsiArguments" -Default "/qn /norestart"
$cachePath           = Get-ObjectValue -Object $config -Name "CachePath"           -Default "$env:ProgramData\AppDeployment\Cache"
$logPath             = Get-ObjectValue -Object $config -Name "LogPath"             -Default "$env:ProgramData\AppDeployment\Logs"
$copyToCache         = [bool](Get-ObjectValue -Object $config -Name "CopyToCache"  -Default $true)
$allowDowngrade      = [bool](Get-ObjectValue -Object $config -Name "AllowDowngrade" -Default $false)
$successExitCodes    = [int[]]@(Get-ObjectValue -Object $config -Name "SuccessExitCodes" -Default @(0, 3010, 1641))

New-Item -ItemType Directory -Path $logPath  -Force | Out-Null
New-Item -ItemType Directory -Path $cachePath -Force | Out-Null
$script:LogFile = Join-Path $logPath ("agent-{0}.log" -f (Get-Date -Format "yyyyMMdd"))

# Status- en triggerpad (relatief aan share of absoluut)
function Resolve-ShareRelativePath {
    param([string]$ConfigValue, [string]$Default)
    if ([string]::IsNullOrWhiteSpace($ConfigValue)) { return $Default }
    if ([System.IO.Path]::IsPathRooted($ConfigValue)) { return $ConfigValue }
    return Join-Path $sharePath $ConfigValue
}

$statusPath  = Resolve-ShareRelativePath -ConfigValue (Get-ObjectValue -Object $config -Name "StatusPath"  -Default $null) -Default (Join-Path $sharePath "status")
$triggerPath = Resolve-ShareRelativePath -ConfigValue (Get-ObjectValue -Object $config -Name "TriggerPath" -Default $null) -Default (Join-Path $sharePath "triggers")

# ── Trigger check ─────────────────────────────────────────────────────────────

$computerName    = $env:COMPUTERNAME
$triggeredDeploy = $false
$triggerFile     = Join-Path $triggerPath "$computerName.trigger"

if (Test-Path -LiteralPath $triggerFile -ErrorAction SilentlyContinue) {
    Write-Log "Deployment trigger gevonden voor $computerName"
    try { Remove-Item -LiteralPath $triggerFile -Force -ErrorAction SilentlyContinue } catch {}
    $triggeredDeploy = $true
}

# ── Manifest laden ────────────────────────────────────────────────────────────

$manifestPath = if ([System.IO.Path]::IsPathRooted($manifestFile)) {
    $manifestFile
} else {
    Join-Path $sharePath $manifestFile
}

Write-Log "Deployment gestart. Config=$ConfigPath Manifest=$manifestPath Triggered=$triggeredDeploy"

if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Log "Manifest niet gevonden: $manifestPath" "ERROR"
    exit 2
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$packages = @($manifest.packages)

# ── Deployment loop ───────────────────────────────────────────────────────────

$packageResults   = [System.Collections.Generic.List[object]]::new()
$packagesInstalled = 0
$packagesSkipped   = 0
$packagesFailed    = 0
$rebootRequired    = $false

foreach ($package in $packages) {
    $packageId   = Get-ObjectValue -Object $package -Name "id"
    $packageName = Get-ObjectValue -Object $package -Name "name" -Default $packageId
    $enabled     = [bool](Get-ObjectValue -Object $package -Name "enabled"  -Default $true)
    $required    = [bool](Get-ObjectValue -Object $package -Name "required" -Default $true)

    if (-not $enabled) {
        Write-Log "Overslaan: $packageName is uitgeschakeld"
        $packagesSkipped++
        $packageResults.Add([ordered]@{ id = $packageId; name = $packageName; action = "skipped"; reason = "uitgeschakeld" })
        continue
    }

    if (-not $required) {
        Write-Log "Overslaan: $packageName is niet verplicht"
        $packagesSkipped++
        $packageResults.Add([ordered]@{ id = $packageId; name = $packageName; action = "skipped"; reason = "niet verplicht" })
        continue
    }

    $productCode      = Get-ObjectValue -Object $package -Name "productCode"
    $installedPackage = Get-RegistryInstalledPackage -ProductCode $productCode -Name $packageName
    $decision         = Test-ShouldInstallPackage -Package $package -InstalledPackage $installedPackage -AllowDowngrade $allowDowngrade

    if (-not $decision.ShouldInstall) {
        Write-Log "Overslaan: $packageName ($($decision.Reason))"
        $packagesSkipped++
        $packageResults.Add([ordered]@{ id = $packageId; name = $packageName; action = "skipped"; reason = $decision.Reason })
        continue
    }

    $source = Get-ObjectValue -Object $package -Name "source"
    if ([string]::IsNullOrWhiteSpace($source)) {
        Write-Log "Overslaan: $packageName mist source" "ERROR"
        $packagesFailed++
        $packageResults.Add([ordered]@{ id = $packageId; name = $packageName; action = "failed"; reason = "source ontbreekt" })
        continue
    }

    $sourcePath = Resolve-PackageSource -SharePath $sharePath -Source $source
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Log "Bronbestand niet gevonden voor ${packageName}: $sourcePath" "ERROR"
        $packagesFailed++
        $packageResults.Add([ordered]@{ id = $packageId; name = $packageName; action = "failed"; reason = "bronbestand niet gevonden" })
        continue
    }

    $installPath = $sourcePath
    if ($copyToCache) {
        try {
            $installPath = Copy-PackageToCache -SourcePath $sourcePath -CachePath $cachePath -PackageId $packageId
        } catch {
            Write-Log "Kan $packageName niet naar cache kopieren: $($_.Exception.Message)" "ERROR"
            $packagesFailed++
            $packageResults.Add([ordered]@{ id = $packageId; name = $packageName; action = "failed"; reason = "cache fout" })
            continue
        }
    }

    $arguments = Get-ObjectValue -Object $package -Name "arguments" -Default $defaultMsiArguments
    $exitCode  = Invoke-MsiInstall -MsiPath $installPath -PackageId $packageId -Arguments $arguments -LogPath $logPath -SuccessExitCodes $successExitCodes -PreviewOnly ([bool]$WhatIfInstall)

    if (-not ($successExitCodes -contains $exitCode)) {
        $packagesFailed++
        $packageResults.Add([ordered]@{ id = $packageId; name = $packageName; action = "failed"; reason = "exitcode $exitCode" })
        continue
    }

    $packagesInstalled++
    if ($exitCode -eq 3010 -or $exitCode -eq 1641) { $rebootRequired = $true }
    $packageResults.Add([ordered]@{
        id      = $packageId
        name    = $packageName
        action  = "installed"
        version = (Get-ObjectValue -Object $package -Name "version")
        reason  = $decision.Reason
    })
}

Write-Log "Deployment afgerond. Geinstalleerd=$packagesInstalled Overgeslagen=$packagesSkipped Mislukt=$packagesFailed"

# ── Status schrijven naar share ───────────────────────────────────────────────

try {
    New-Item -ItemType Directory -Path $statusPath -Force -ErrorAction SilentlyContinue | Out-Null
    $statusFile = Join-Path $statusPath "$computerName.json"

    $osInfo = $null
    try { $osInfo = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue } catch {}

    $deployResult = if ($packagesFailed -gt 0 -and $packagesInstalled -gt 0) { "partial" }
                    elseif ($packagesFailed -gt 0) { "failed" }
                    elseif ($packagesInstalled -gt 0) { "installed" }
                    else { "upToDate" }

    $status = [ordered]@{
        computerName      = $computerName
        lastSeenUtc       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        deploymentResult  = $deployResult
        packagesChecked   = $packages.Count
        packagesInstalled = $packagesInstalled
        packagesSkipped   = $packagesSkipped
        packagesFailed    = $packagesFailed
        rebootRequired    = $rebootRequired
        triggeredDeploy   = $triggeredDeploy
        packages          = @($packageResults)
        osCaption         = if ($osInfo) { $osInfo.Caption } else { "" }
        osBuildNumber     = if ($osInfo) { $osInfo.BuildNumber } else { "" }
        agentVersion      = "1.1"
    }

    $status | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statusFile -Encoding UTF8
    Write-Log "Status geschreven: $statusFile"
} catch {
    Write-Log "Kan status niet schrijven naar share: $($_.Exception.Message)" "WARN"
}
