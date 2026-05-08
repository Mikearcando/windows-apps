[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SharePath,

    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [ValidateNotNullOrEmpty()]
    [string]$DefaultArguments = "/qn /norestart",

    [switch]$DisabledByDefault
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ObjectValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $baseFullPath = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $baseFullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFullPath = $baseFullPath + [System.IO.Path]::DirectorySeparatorChar
    }

    $targetFullPath = [System.IO.Path]::GetFullPath($TargetPath)
    $baseUri = New-Object System.Uri($baseFullPath)
    $targetUri = New-Object System.Uri($targetFullPath)

    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace("/", "\")
}

function Get-SafePackageId {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$SeenIds
    )

    $baseId = $Name.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    $baseId = $baseId.Trim("-")
    if ([string]::IsNullOrWhiteSpace($baseId)) {
        $baseId = "package"
    }

    $candidate = $baseId
    $counter = 2
    while ($SeenIds.ContainsKey($candidate)) {
        $candidate = "{0}-{1}" -f $baseId, $counter
        $counter++
    }

    $SeenIds[$candidate] = $true
    return $candidate
}

function Get-MsiProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Database,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $view = $null
    $record = $null

    try {
        $query = "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'"
        $view = $Database.OpenView($query)
        $view.Execute()
        $record = $view.Fetch()

        if ($null -eq $record) {
            return $null
        }

        return [string]$record.StringData(1)
    }
    finally {
        if ($null -ne $view) {
            $view.Close()
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)
        }

        if ($null -ne $record) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($record)
        }
    }
}

function Get-MsiMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Installer
    )

    $database = $null

    try {
        $database = $Installer.OpenDatabase($Path, 0)
        return [pscustomobject]@{
            ProductName    = Get-MsiProperty -Database $database -Name "ProductName"
            ProductVersion = Get-MsiProperty -Database $database -Name "ProductVersion"
            ProductCode    = Get-MsiProperty -Database $database -Name "ProductCode"
            UpgradeCode    = Get-MsiProperty -Database $database -Name "UpgradeCode"
        }
    }
    finally {
        if ($null -ne $database) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($database)
        }
    }
}

if (-not (Test-Path -LiteralPath $SharePath)) {
    throw "SharePath bestaat niet of is niet bereikbaar: $SharePath"
}

$resolvedSharePath = (Resolve-Path -LiteralPath $SharePath).Path
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $resolvedSharePath "apps.json"
}

$existingBySource = @{}
if (Test-Path -LiteralPath $OutputPath) {
    $existingManifest = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
    foreach ($package in @($existingManifest.packages)) {
        $source = Get-ObjectValue -Object $package -Name "source"
        if (-not [string]::IsNullOrWhiteSpace($source)) {
            $existingBySource[$source] = $package
        }
    }
}

$installer = $null
try {
    $installer = New-Object -ComObject WindowsInstaller.Installer
}
catch {
    throw "Kan Windows Installer COM-object niet starten. Draai dit script op Windows met Windows Installer beschikbaar. Fout: $($_.Exception.Message)"
}

$seenIds = @{}
$packages = @()
$msiFiles = Get-ChildItem -LiteralPath $resolvedSharePath -Recurse -Filter "*.msi" -File | Sort-Object FullName

foreach ($file in $msiFiles) {
    $relativeSource = Get-RelativePath -BasePath $resolvedSharePath -TargetPath $file.FullName
    $existingPackage = $existingBySource[$relativeSource]

    try {
        $metadata = Get-MsiMetadata -Path $file.FullName -Installer $installer
    }
    catch {
        Write-Warning "Kan MSI metadata niet lezen voor '$($file.FullName)': $($_.Exception.Message)"
        $metadata = [pscustomobject]@{
            ProductName    = $file.BaseName
            ProductVersion = $null
            ProductCode    = $null
            UpgradeCode    = $null
        }
    }

    $name = Get-ObjectValue -Object $metadata -Name "ProductName" -Default $file.BaseName
    $existingId = Get-ObjectValue -Object $existingPackage -Name "id"
    $id = if ([string]::IsNullOrWhiteSpace($existingId)) {
        Get-SafePackageId -Name $name -SeenIds $seenIds
    }
    else {
        $seenIds[$existingId] = $true
        $existingId
    }

    $packages += [ordered]@{
        id          = $id
        name        = $name
        version     = Get-ObjectValue -Object $metadata -Name "ProductVersion"
        productCode = Get-ObjectValue -Object $metadata -Name "ProductCode"
        upgradeCode = Get-ObjectValue -Object $metadata -Name "UpgradeCode"
        source      = $relativeSource
        arguments   = Get-ObjectValue -Object $existingPackage -Name "arguments" -Default $DefaultArguments
        enabled     = [bool](Get-ObjectValue -Object $existingPackage -Name "enabled" -Default (-not $DisabledByDefault.IsPresent))
        required    = [bool](Get-ObjectValue -Object $existingPackage -Name "required" -Default $true)
    }
}

$manifest = [ordered]@{
    schemaVersion   = 1
    generatedAtUtc  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    packageCount    = $packages.Count
    packages        = $packages
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Manifest geschreven: $OutputPath ($($packages.Count) package(s))"

if ($null -ne $installer) {
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
}
