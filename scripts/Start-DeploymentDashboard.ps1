[CmdletBinding()]
param(
    [string]$SharePath,
    [string]$ConfigPath   = "C:\ProgramData\AppDeployment\server.config.json",
    [string]$ManifestFile = "apps.json",
    [string]$LogPath      = "C:\ProgramData\AppDeployment\Logs",
    [int]$Port            = 8080,
    [switch]$NoOpenBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (Test-Path -LiteralPath $ConfigPath) {
    $sc = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($SharePath) -and $sc.SharePath) { $SharePath   = $sc.SharePath }
    if ($Port -eq 8080 -and $sc.Port)                                { $Port        = [int]$sc.Port }
    if ($sc.LogPath)                                                  { $LogPath     = $sc.LogPath }
    if ($sc.ManifestFile)                                             { $ManifestFile = $sc.ManifestFile }
}

if ([string]::IsNullOrWhiteSpace($SharePath)) {
    throw "SharePath is verplicht. Geef -SharePath op of stel in via $ConfigPath"
}

$manifestPath = if ([System.IO.Path]::IsPathRooted($ManifestFile)) { $ManifestFile }
                else { Join-Path $SharePath $ManifestFile }
$statusPath   = Join-Path $SharePath "status"
$triggerPath  = Join-Path $SharePath "triggers"
$scriptsDir   = $PSScriptRoot

# ── Hulpfuncties ──────────────────────────────────────────────────────────────

function Send-Response {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse]$Response,
        [string]$Body = "", [string]$ContentType = "application/json; charset=utf-8", [int]$StatusCode = 200
    )
    $Response.StatusCode = $StatusCode; $Response.ContentType = $ContentType
    $b = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Response.ContentLength64 = $b.Length; $Response.OutputStream.Write($b, 0, $b.Length)
    $Response.OutputStream.Close()
}

function Read-Body { param($Request)
    (New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
}

function Get-ManifestContent {
    if (-not (Test-Path -LiteralPath $manifestPath)) { return '{"schemaVersion":1,"packages":[]}' }
    return Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
}

function Save-ManifestContent { param([string]$Json)
    ($Json | ConvertFrom-Json) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

function Get-ClientsJson {
    $clients = @()
    if (Test-Path -LiteralPath $statusPath) {
        foreach ($f in Get-ChildItem -LiteralPath $statusPath -Filter "*.json" -File -ErrorAction SilentlyContinue) {
            try {
                $c = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $dt = [datetime]::Parse($c.lastSeenUtc,[System.Globalization.CultureInfo]::InvariantCulture,[System.Globalization.DateTimeStyles]::RoundtripKind)
                $min = [int]([datetime]::UtcNow - $dt).TotalMinutes
                $c | Add-Member -NotePropertyName "online"     -NotePropertyValue ($min -le 90) -Force
                $c | Add-Member -NotePropertyName "minutesAgo" -NotePropertyValue $min          -Force
                $clients += $c
            } catch {}
        }
    }
    $parts = $clients | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }
    return '[' + ($parts -join ',') + ']'
}

function Get-LogLines { param([int]$MaxLines = 200)
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) { return @("Logpad niet gevonden: $LogPath") }
    $files = Get-ChildItem -LiteralPath $LogPath -Filter "agent-*.log" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $files) { return @("Geen logbestanden gevonden.") }
    $all = @(); foreach ($f in $files) { $all += @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue); if ($all.Count -ge $MaxLines) { break } }
    return @($all | Select-Object -Last $MaxLines)
}

function Get-ServerConfig {
    if (Test-Path -LiteralPath $ConfigPath) { return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 }
    return @{ SharePath=$SharePath; ManifestFile=$ManifestFile; LogPath=$LogPath; Port=$Port } | ConvertTo-Json
}

function Save-ServerConfig { param([string]$Json)
    $dir = Split-Path $ConfigPath -Parent
    if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($Json | ConvertFrom-Json) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

# ── Setup-functies ────────────────────────────────────────────────────────────

function Get-SetupStatus {
    $smbShare = $null
    try { $smbShare = Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $SharePath -or $_.Path -eq ($SharePath.TrimEnd('\')) } } catch {}

    $statusDir  = Join-Path $SharePath "status"
    $triggerDir = Join-Path $SharePath "triggers"

    $statusWritable = $false
    if (Test-Path -LiteralPath $statusDir) {
        $tf = Join-Path $statusDir "_setup_write_test.tmp"
        try { Set-Content -LiteralPath $tf -Value "x" -Encoding UTF8 -ErrorAction Stop; Remove-Item $tf -Force; $statusWritable = $true } catch {}
    }

    $task = Get-ScheduledTask -TaskName "WinAppDeploy Dashboard" -ErrorAction SilentlyContinue

    # UNC-pad voor clientinstallatie
    $computerName = $env:COMPUTERNAME
    $smbName = if ($smbShare) { $smbShare.Name } else { "AppDeployment" }
    $installSharePath = "\\$computerName\$smbName"

    return @{
        shareDirExists   = [bool](Test-Path -LiteralPath $SharePath)
        smbShareExists   = ($null -ne $smbShare)
        smbShareName     = if ($smbShare) { $smbShare.Name } else { "" }
        statusDirExists  = [bool](Test-Path -LiteralPath $statusDir)
        triggerDirExists = [bool](Test-Path -LiteralPath $triggerDir)
        statusWritable   = $statusWritable
        manifestExists   = [bool](Test-Path -LiteralPath $manifestPath)
        serviceRunning   = ($null -ne $task -and $task.State -eq "Running")
        serviceExists    = ($null -ne $task)
        sharePath        = $SharePath
        installCmd       = ".\scripts\Install-AppDeploymentAgent.ps1 -SharePath `"$installSharePath`" -RunNow"
        computerName     = $computerName
    } | ConvertTo-Json -Compress
}

function Invoke-SetupCreateDirs {
    New-Item -ItemType Directory -Path $SharePath           -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $SharePath "status")   -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $SharePath "triggers") -Force | Out-Null
    return "Mappen aangemaakt: $SharePath\{status,triggers}"
}

function Invoke-SetupCreateShare { param([string]$Name = "AppDeployment", [string]$ReadAccess = "Domain Computers")
    $existing = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
    if ($existing) { return "Share '$Name' bestaat al op pad '$($existing.Path)'" }
    New-SmbShare -Name $Name -Path $SharePath -ReadAccess $ReadAccess | Out-Null
    return "Share '$Name' aangemaakt (leestoegang: $ReadAccess)"
}

function Invoke-SetupSetPermissions { param([string]$Account = "Domain Computers")
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($Account,"Modify","ContainerInherit,ObjectInherit","None","Allow")
    foreach ($p in @((Join-Path $SharePath "status"), (Join-Path $SharePath "triggers"))) {
        if (Test-Path -LiteralPath $p) { $acl = Get-Acl -Path $p; $acl.AddAccessRule($rule); Set-Acl -Path $p -AclObject $acl }
    }
    return "Schrijftoegang ingesteld voor '$Account' op status en triggers"
}

function Invoke-ManifestRegenerateWithDiff { param([switch]$DisabledByDefault)
    $sf = Join-Path $scriptsDir "New-AppDeploymentManifest.ps1"
    if (-not (Test-Path -LiteralPath $sf)) { throw "Script niet gevonden: $sf" }
    $before = @{}
    if (Test-Path -LiteralPath $manifestPath) {
        try { foreach ($p in @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).packages)) { if ($p.source) { $before[$p.source] = $p.version } } } catch {}
    }
    $output = if ($DisabledByDefault) { & $sf -SharePath $SharePath -DisabledByDefault 2>&1 | Out-String }
              else                    { & $sf -SharePath $SharePath 2>&1 | Out-String }
    $packages = @()
    if (Test-Path -LiteralPath $manifestPath) {
        foreach ($p in @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).packages)) {
            $isNew = -not $before.ContainsKey($p.source)
            $packages += [ordered]@{ name=$p.name; version=$p.version; source=$p.source; isNew=$isNew; isUpdated=(-not $isNew -and $before[$p.source] -ne $p.version) }
        }
    }
    return [ordered]@{ success=$true; output=$output.Trim(); total=$packages.Count; added=@($packages|Where-Object{$_.isNew}).Count; updated=@($packages|Where-Object{$_.isUpdated}).Count; packages=$packages }
}

# ── HTML ──────────────────────────────────────────────────────────────────────

$html = @'
<!DOCTYPE html>
<html lang="nl">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WinAppDeploy</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f1f5f9;color:#1e293b;min-height:100vh}
header{background:#1e3a8a;color:#fff;padding:.75rem 1.75rem;display:flex;align-items:center;justify-content:space-between;box-shadow:0 2px 6px rgba(0,0,0,.3)}
.hdr{display:flex;align-items:center;gap:.6rem}
.hdr h1{font-size:1.05rem;font-weight:700}
.live{background:#22c55e;color:#fff;font-size:.6rem;font-weight:800;padding:2px 8px;border-radius:999px;letter-spacing:.06em}
.live::before{content:'● '}
.hdr-sub{font-size:.7rem;color:#93c5fd;font-family:Consolas,monospace}
nav{background:#1e3a8a;border-top:1px solid rgba(255,255,255,.1);padding:0 1.75rem;display:flex}
.tab{background:none;border:none;color:rgba(255,255,255,.55);padding:.6rem 1rem;font-size:.8rem;font-weight:500;cursor:pointer;border-bottom:2px solid transparent;transition:.15s}
.tab:hover{color:#fff}.tab.on{color:#fff;border-bottom-color:#60a5fa}
main{padding:1.25rem 1.75rem;max-width:1400px}
.pane{display:none}.pane.on{display:block}

/* Stats */
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:.875rem;margin-bottom:1.25rem}
.sc{background:#fff;border-radius:9px;padding:1rem 1.25rem;box-shadow:0 1px 3px rgba(0,0,0,.08);border-left:3px solid #e2e8f0}
.sc.b{border-color:#3b82f6}.sc.g{border-color:#22c55e}.sc.a{border-color:#f59e0b}.sc.r{border-color:#ef4444}
.sc-l{font-size:.68rem;color:#64748b;font-weight:600;text-transform:uppercase;letter-spacing:.05em;margin-bottom:.2rem}
.sc-v{font-size:1.9rem;font-weight:800;line-height:1}
.b .sc-v{color:#3b82f6}.g .sc-v{color:#22c55e}.a .sc-v{color:#f59e0b}.r .sc-v{color:#ef4444}

/* Panels */
.panel{background:#fff;border-radius:9px;box-shadow:0 1px 3px rgba(0,0,0,.08);overflow:hidden;margin-bottom:1.25rem}
.ph{padding:.8rem 1.25rem;border-bottom:1px solid #f1f5f9;display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:.5rem}
.ph h2{font-size:.88rem;font-weight:600}
.acts{display:flex;gap:.4rem;flex-wrap:wrap;align-items:center}
.two-col{display:grid;grid-template-columns:1fr 1fr;gap:1.25rem}

/* Buttons */
.btn{display:inline-flex;align-items:center;gap:4px;padding:.35rem .8rem;border-radius:5px;border:none;cursor:pointer;font-size:.76rem;font-weight:500;transition:background .12s,transform .1s;white-space:nowrap}
.btn:active{transform:scale(.97)}.btn:disabled{opacity:.5;cursor:not-allowed;transform:none}
.bpri{background:#2563eb;color:#fff}.bpri:hover:not(:disabled){background:#1d4ed8}
.bsuc{background:#22c55e;color:#fff}.bsuc:hover:not(:disabled){background:#16a34a}
.bsec{background:#f1f5f9;color:#334155;border:1px solid #e2e8f0}.bsec:hover:not(:disabled){background:#e2e8f0}
.bdgr{background:#fee2e2;color:#b91c1c;border:1px solid #fecaca}.bdgr:hover:not(:disabled){background:#fecaca}
.bwrn{background:#fef9c3;color:#854d0e;border:1px solid #fde68a}.bwrn:hover:not(:disabled){background:#fde68a}

/* Table */
table{width:100%;border-collapse:collapse}
th{padding:.5rem .875rem;text-align:left;font-size:.67rem;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:.05em;background:#f8fafc;white-space:nowrap}
td{padding:.6rem .875rem;border-top:1px solid #f1f5f9;font-size:.82rem;vertical-align:middle}
tr:hover td{background:#fafbff}

/* Toggles */
.toggle{position:relative;display:inline-block;width:36px;height:20px;flex-shrink:0}
.toggle input{opacity:0;width:0;height:0}
.sl{position:absolute;cursor:pointer;inset:0;background:#cbd5e1;border-radius:20px;transition:.18s}
.sl::before{position:absolute;content:'';height:14px;width:14px;left:3px;bottom:3px;background:#fff;border-radius:50%;transition:.18s;box-shadow:0 1px 2px rgba(0,0,0,.2)}
input:checked+.sl{background:#3b82f6}
input:checked+.sl::before{transform:translateX(16px)}

/* Badges */
.badge{display:inline-block;font-size:.67rem;padding:1px 7px;border-radius:999px;font-weight:600;white-space:nowrap}
.b-ok{background:#dcfce7;color:#15803d}.b-warn{background:#fef9c3;color:#854d0e}.b-err{background:#fee2e2;color:#b91c1c}.b-gray{background:#f1f5f9;color:#64748b}.b-blue{background:#dbeafe;color:#1d4ed8}
.ver-b{background:#ede9fe;color:#6d28d9;font-family:Consolas,monospace}
.nb{background:#dcfce7;color:#15803d;font-size:.62rem;font-weight:700;padding:1px 6px;border-radius:999px}
.ub{background:#fef9c3;color:#854d0e;font-size:.62rem;font-weight:700;padding:1px 6px;border-radius:999px}

/* Setup checklist */
.setup-grid{display:grid;grid-template-columns:1fr 1fr;gap:1.25rem}
.chk-list{padding:.5rem 0}
.chk-row{display:flex;align-items:center;justify-content:space-between;padding:.6rem 1.25rem;border-bottom:1px solid #f8fafc;gap:.75rem}
.chk-row:last-child{border-bottom:none}
.chk-left{display:flex;align-items:center;gap:.6rem;flex:1;min-width:0}
.chk-icon{width:22px;height:22px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:.75rem;flex-shrink:0}
.chk-icon.ok{background:#dcfce7;color:#15803d}.chk-icon.fail{background:#fee2e2;color:#b91c1c}.chk-icon.spin-c{background:#dbeafe;color:#2563eb}
.chk-text{font-size:.82rem;font-weight:500}.chk-detail{font-size:.7rem;color:#94a3b8;margin-top:1px}

/* Install cmd box */
.cmd-box{background:#0f172a;color:#e2e8f0;font-family:Consolas,monospace;font-size:.78rem;padding:.875rem 1rem;border-radius:7px;word-break:break-all;line-height:1.6;position:relative}
.cmd-copy{position:absolute;top:.5rem;right:.5rem}

/* Inline input for args */
.arg-input{width:100%;padding:.3rem .5rem;border:1px solid #e2e8f0;border-radius:4px;font-family:Consolas,monospace;font-size:.75rem;color:#334155;background:#f8fafc}
.arg-input:focus{outline:none;border-color:#3b82f6;background:#fff}

/* Log */
.log-body{height:480px;overflow-y:auto;padding:.75rem 1rem;background:#0f172a;font-family:Consolas,monospace;font-size:.7rem;line-height:1.55}
.ll{margin-bottom:1px;white-space:pre-wrap;word-break:break-all}
.ll.I{color:#94a3b8}.ll.W{color:#fbbf24}.ll.E{color:#f87171}

/* Settings form */
.form-row{display:grid;grid-template-columns:180px 1fr;align-items:center;gap:.75rem;padding:.6rem 1.25rem;border-bottom:1px solid #f8fafc}
.form-row:last-child{border-bottom:none}
.form-row label{font-size:.8rem;font-weight:500;color:#374151}
.form-row input{width:100%;padding:.38rem .6rem;border:1px solid #d1d5db;border-radius:5px;font-size:.82rem}
.form-row input:focus{outline:none;border-color:#3b82f6;box-shadow:0 0 0 2px #dbeafe}
.form-foot{padding:.75rem 1.25rem;display:flex;gap:.5rem}
.info-box{margin:.75rem 1.25rem;background:#eff6ff;border:1px solid #bfdbfe;border-radius:6px;padding:.65rem 1rem;font-size:.78rem;color:#1e40af}

/* Status dot */
.dot{width:9px;height:9px;border-radius:50%;display:inline-block;flex-shrink:0}
.dot.on{background:#22c55e;box-shadow:0 0 0 2px #dcfce7}.dot.off{background:#94a3b8}
.ci{display:flex;align-items:center;gap:.5rem}

/* Modal */
.overlay{position:fixed;inset:0;background:rgba(15,23,42,.45);z-index:1100;display:flex;align-items:center;justify-content:center;opacity:0;pointer-events:none;transition:opacity .2s}
.overlay.show{opacity:1;pointer-events:all}
.modal{background:#fff;border-radius:10px;width:540px;max-width:92vw;max-height:82vh;display:flex;flex-direction:column;box-shadow:0 20px 48px rgba(0,0,0,.25)}
.modal-hd{padding:.875rem 1.25rem;border-bottom:1px solid #f1f5f9;display:flex;align-items:center;justify-content:space-between}
.modal-hd h3{font-size:.95rem;font-weight:600}
.modal-bd{padding:1.1rem 1.25rem;overflow-y:auto;flex:1}
.modal-ft{padding:.7rem 1.25rem;border-top:1px solid #f1f5f9;display:flex;justify-content:flex-end;gap:.5rem}
.rg-stats{display:grid;grid-template-columns:repeat(3,1fr);gap:.75rem;margin-bottom:1rem}
.rg-stat{text-align:center;background:#f8fafc;border-radius:8px;padding:.7rem .5rem}
.rg-v{font-size:1.75rem;font-weight:800;line-height:1}.rg-l{font-size:.68rem;color:#64748b;margin-top:3px}
.rg-v.blue{color:#3b82f6}.rg-v.green{color:#22c55e}.rg-v.amber{color:#f59e0b}
.pkg-diff{border:1px solid #f1f5f9;border-radius:7px;overflow:hidden;margin-bottom:.75rem}
.pd-row{display:flex;align-items:center;justify-content:space-between;padding:.4rem .9rem;border-bottom:1px solid #f8fafc;font-size:.8rem}
.pd-row:last-child{border-bottom:none}
.rg-log{background:#0f172a;color:#94a3b8;font-family:Consolas,monospace;font-size:.7rem;padding:.6rem .8rem;border-radius:6px;white-space:pre-wrap;word-break:break-all;margin-top:.75rem}
.opt-row{display:flex;align-items:center;gap:.4rem;font-size:.75rem;color:#64748b;cursor:pointer}
.opt-row input{cursor:pointer}

/* Toast */
.toast{position:fixed;bottom:1.25rem;right:1.25rem;color:#fff;padding:.55rem 1.1rem;border-radius:7px;font-size:.78rem;font-weight:500;opacity:0;transition:opacity .22s;pointer-events:none;z-index:1200}
.toast.show{opacity:1}.t-ok{background:#15803d}.t-err{background:#dc2626}
@keyframes spin{to{transform:rotate(360deg)}}
.spin{display:inline-block;animation:spin .7s linear infinite}
.empty{text-align:center;color:#94a3b8;padding:2.5rem;font-size:.85rem}
p.hint{font-size:.78rem;color:#64748b;padding:.75rem 1.25rem;line-height:1.5}
</style>
</head>
<body>
<header>
  <div class="hdr"><h1>&#9881; WinAppDeploy</h1><span class="live">LIVE</span></div>
  <span class="hdr-sub" id="hdr-sub"></span>
</header>
<nav>
  <button class="tab on"  onclick="tab('setup')">&#9881; Setup</button>
  <button class="tab"     onclick="tab('clients')">&#128187; Clients</button>
  <button class="tab"     onclick="tab('pakketten')">&#128230; Pakketten</button>
  <button class="tab"     onclick="tab('logs')">&#128196; Logs</button>
  <button class="tab"     onclick="tab('instellingen')">&#9965; Instellingen</button>
</nav>
<main>

<!-- ═══ SETUP ═══ -->
<div class="pane on" id="pane-setup">
  <div class="setup-grid">
    <div>
      <div class="panel">
        <div class="ph">
          <h2>&#9989; Servercontrole</h2>
          <button class="btn bsec" onclick="loadSetup()">&#8635; Vernieuwen</button>
        </div>
        <div id="chk-list" class="chk-list"><div class="empty">Laden...</div></div>
      </div>
    </div>
    <div>
      <div class="panel">
        <div class="ph"><h2>&#128187; Client installeren</h2></div>
        <p class="hint">Voer dit commando uit op elke clientcomputer als <strong>administrator</strong>:</p>
        <div style="padding:0 1.25rem 1.25rem">
          <div class="cmd-box" id="install-cmd-box">
            <span id="install-cmd">Laden...</span>
            <button class="btn bsec cmd-copy" onclick="copyCmd()" title="Kopiëren">&#128203;</button>
          </div>
        </div>
        <p class="hint" style="padding-top:0">Na installatie draait de agent automatisch en verschijnt de computer in de <strong>Clients</strong>-tab.</p>
      </div>
      <div class="panel">
        <div class="ph"><h2>&#128203; Pre-check script</h2></div>
        <p class="hint">Controleer handmatig of alles correct is geconfigureerd via PowerShell:</p>
        <div style="padding:0 1.25rem 1.25rem">
          <div class="cmd-box">
            <span>.\scripts\Pre-Check.ps1 -SharePath "D:\AppDeployment" -Role Server</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- ═══ CLIENTS ═══ -->
<div class="pane" id="pane-clients">
  <div class="stats">
    <div class="sc b"><div class="sc-l">Totaal clients</div><div class="sc-v" id="cs-total">—</div></div>
    <div class="sc g"><div class="sc-l">Online</div><div class="sc-v" id="cs-online">—</div></div>
    <div class="sc a"><div class="sc-l">Reboot vereist</div><div class="sc-v" id="cs-reboot">—</div></div>
    <div class="sc r"><div class="sc-l">Fouten</div><div class="sc-v" id="cs-failed">—</div></div>
  </div>
  <div class="panel">
    <div class="ph">
      <h2>&#128187; Clientstatus</h2>
      <div class="acts">
        <button class="btn bsec" onclick="loadClients()">&#8635; Vernieuwen</button>
        <button class="btn bpri" onclick="deployAll()">&#9654; Alle online deployen</button>
      </div>
    </div>
    <div style="overflow-x:auto">
      <table>
        <thead><tr><th></th><th>Computer</th><th>OS</th><th>Gezien</th><th>Deployment</th><th>Pakketten</th><th>Actie</th></tr></thead>
        <tbody id="clients-tb"><tr><td colspan="7" class="empty">Laden...</td></tr></tbody>
      </table>
    </div>
  </div>
</div>

<!-- ═══ PAKKETTEN ═══ -->
<div class="pane" id="pane-pakketten">
  <div class="panel">
    <div class="ph">
      <h2>&#128230; Pakketten</h2>
      <div class="acts">
        <button class="btn bsec" onclick="loadManifest()">&#8635; Vernieuwen</button>
        <label class="opt-row"><input type="checkbox" id="chk-disabled">Nieuw uitschakelen</label>
        <button class="btn bsec" id="btn-regen" onclick="doRegen()">&#9660; Opnieuw genereren</button>
        <button class="btn bsuc" id="btn-save" onclick="doSave()" disabled>&#10003; Opslaan</button>
      </div>
    </div>
    <div style="overflow-x:auto">
      <table>
        <thead><tr><th>Naam</th><th>Versie</th><th>Installatie-argumenten</th><th>Ingeschakeld</th><th>Verplicht</th><th></th></tr></thead>
        <tbody id="pkg-tb"><tr><td colspan="6" class="empty">Laden...</td></tr></tbody>
      </table>
    </div>
  </div>
</div>

<!-- ═══ LOGS ═══ -->
<div class="pane" id="pane-logs">
  <div class="panel">
    <div class="ph">
      <h2>&#128196; Agent logs</h2>
      <button class="btn bsec" onclick="loadLogs()">&#8635; Vernieuwen</button>
    </div>
    <div class="log-body" id="log-body"><div class="ll I">Laden...</div></div>
  </div>
</div>

<!-- ═══ INSTELLINGEN ═══ -->
<div class="pane" id="pane-instellingen">
  <div class="two-col">
    <div class="panel">
      <div class="ph"><h2>&#9881; Serverconfiguratie</h2></div>
      <div class="form-row"><label>Share pad</label><input id="cfg-share" type="text" placeholder="\\SERVER\AppDeployment"></div>
      <div class="form-row"><label>Manifest bestand</label><input id="cfg-manifest" type="text" placeholder="apps.json"></div>
      <div class="form-row"><label>Log map</label><input id="cfg-logpath" type="text"></div>
      <div class="form-row"><label>Poort</label><input id="cfg-port" type="number" style="width:100px"></div>
      <div class="info-box">&#8505; Een poortwijziging vereist een herstart van de dashboardservice.</div>
      <div class="form-foot">
        <button class="btn bsuc" onclick="saveCfg()">&#10003; Opslaan</button>
        <button class="btn bsec" onclick="loadCfg()">&#8635; Opnieuw laden</button>
      </div>
    </div>
    <div class="panel">
      <div class="ph"><h2>&#128203; Service</h2></div>
      <div class="form-row"><label>Dashboard URL</label><input readonly id="svc-url" type="text"></div>
      <div class="form-row"><label>Manifest</label><input readonly id="svc-manifest" type="text"></div>
      <div class="form-row"><label>Status map</label><input readonly id="svc-status" type="text"></div>
      <div class="form-row"><label>Trigger map</label><input readonly id="svc-trigger" type="text"></div>
    </div>
  </div>
  <div class="panel">
    <div class="ph"><h2>&#128736; Share-rechten instellen</h2></div>
    <p class="hint">Stel schrijftoegang in voor clients op de submappen <code>status</code> en <code>triggers</code>. Standaard voor domeinomgevingen.</p>
    <div class="form-row"><label>Account</label><input id="perm-account" type="text" value="Domain Computers" style="max-width:280px"></div>
    <div class="form-foot">
      <button class="btn bpri" onclick="setPermissions()">&#128736; Rechten instellen</button>
    </div>
  </div>
</div>

</main>

<!-- Regen modal -->
<div class="overlay" id="regen-overlay">
  <div class="modal">
    <div class="modal-hd"><h3>&#9660; Manifest gegenereerd</h3><button class="btn bsec" style="padding:.25rem .5rem" onclick="closeModal()">&#10005;</button></div>
    <div class="modal-bd" id="regen-body"></div>
    <div class="modal-ft"><button class="btn bsuc" onclick="closeModal()">&#10003; Sluiten</button></div>
  </div>
</div>

<!-- Setup action modal -->
<div class="overlay" id="action-overlay">
  <div class="modal">
    <div class="modal-hd"><h3 id="action-title">Bezig...</h3></div>
    <div class="modal-bd" id="action-body"><div class="empty"><span class="spin">&#8635;</span> Bezig...</div></div>
    <div class="modal-ft"><button class="btn bsuc" id="action-close" onclick="closeActionModal()" disabled>&#10003; Sluiten</button></div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
var M=null,dirty=false,CL=[],SV={};

function esc(s){if(s==null)return'';return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function toast(msg,t){var e=document.getElementById('toast');e.textContent=msg;e.className='toast show '+(t||'t-ok');clearTimeout(e._t);e._t=setTimeout(function(){e.className='toast';},3000);}

function tab(name){
  ['setup','clients','pakketten','logs','instellingen'].forEach(function(n,i){
    document.querySelectorAll('.tab')[i].classList.toggle('on',n===name);
    document.getElementById('pane-'+n).classList.toggle('on',n===name);
  });
  if(name==='setup')     loadSetup();
  if(name==='clients')   loadClients();
  if(name==='pakketten') loadManifest();
  if(name==='logs')      loadLogs();
  if(name==='instellingen'){loadCfg();loadSvcInfo();}
}

// ── Setup ─────────────────────────────────────────────────────────────────────
async function loadSetup(){
  try{
    var r=await fetch('/api/setup');SV=await r.json();
    document.getElementById('install-cmd').textContent=SV.installCmd||'(Share niet geconfigureerd)';
    renderChecklist();
  }catch(e){document.getElementById('chk-list').innerHTML='<div class="empty">Fout: '+esc(e.message)+'</div>';}
}

function renderChecklist(){
  var items=[
    {label:'Share map bestaat',       detail:SV.sharePath,           ok:SV.shareDirExists,   action:'create-dirs',  btnLabel:'Aanmaken'},
    {label:'SMB share geconfigureerd',detail:SV.smbShareName||'',    ok:SV.smbShareExists,   action:'create-share', btnLabel:'Share aanmaken'},
    {label:"Submap 'status' bestaat", detail:'',                     ok:SV.statusDirExists,  action:'create-dirs',  btnLabel:'Aanmaken'},
    {label:"Submap 'triggers' bestaat",detail:'',                    ok:SV.triggerDirExists, action:'create-dirs',  btnLabel:'Aanmaken'},
    {label:'Schrijftoegang clients',  detail:'status + triggers',    ok:SV.statusWritable,   action:'set-perms',    btnLabel:'Rechten instellen'},
    {label:'Manifest apps.json',      detail:'',                     ok:SV.manifestExists,   action:'regen',        btnLabel:'Genereren'},
    {label:'Dashboard service actief',detail:'',                     ok:SV.serviceRunning,   action:'none',         btnLabel:''}
  ];
  var html=items.map(function(it){
    var icon=it.ok?'<div class="chk-icon ok">&#10003;</div>':'<div class="chk-icon fail">&#10005;</div>';
    var btn='';
    if(!it.ok&&it.btnLabel){
      if(it.action==='regen') btn='<button class="btn bwrn" onclick="tab(\'pakketten\')">'+esc(it.btnLabel)+'</button>';
      else btn='<button class="btn bpri" onclick="runSetupAction(\''+it.action+'\')">'+esc(it.btnLabel)+'</button>';
    }
    if(it.ok&&it.detail) btn='<span class="badge b-ok">'+esc(it.detail||'OK')+'</span>';
    return '<div class="chk-row"><div class="chk-left">'+icon+'<div><div class="chk-text">'+esc(it.label)+'</div>'+(it.detail&&!it.ok?'<div class="chk-detail">'+esc(it.detail)+'</div>':'')+'</div></div>'+btn+'</div>';
  }).join('');
  document.getElementById('chk-list').innerHTML=html;
}

async function runSetupAction(action){
  document.getElementById('action-title').textContent=action==='create-dirs'?'Mappen aanmaken':action==='create-share'?'Share aanmaken':'Rechten instellen';
  document.getElementById('action-body').innerHTML='<div class="empty"><span class="spin">&#8635;</span> Bezig...</div>';
  document.getElementById('action-close').disabled=true;
  document.getElementById('action-overlay').classList.add('show');
  try{
    var r=await fetch('/api/setup/'+action,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({})});
    var j=await r.json();
    var icon=j.success?'<span style="color:#15803d;font-size:1.5rem">&#10003;</span>':'<span style="color:#dc2626;font-size:1.5rem">&#10005;</span>';
    document.getElementById('action-body').innerHTML='<div style="text-align:center;padding:1.5rem">'+icon+'<p style="margin-top:.75rem;font-size:.85rem">'+esc(j.message)+'</p></div>';
    if(j.success){toast(j.message);loadSetup();}else toast(j.message,'t-err');
  }catch(e){document.getElementById('action-body').innerHTML='<div style="text-align:center;padding:1.5rem;color:#dc2626">&#10005; '+esc(e.message)+'</div>';}
  document.getElementById('action-close').disabled=false;
}

function closeActionModal(){document.getElementById('action-overlay').classList.remove('show');}

function copyCmd(){
  var t=document.getElementById('install-cmd').textContent;
  navigator.clipboard.writeText(t).then(function(){toast('Commando gekopieerd');}).catch(function(){toast('Kopiëren mislukt','t-err');});
}

// ── Clients ───────────────────────────────────────────────────────────────────
async function loadClients(){
  try{
    var r=await fetch('/api/clients');CL=await r.json();
    CL.sort(function(a,b){if(a.online!==b.online)return a.online?-1:1;return(a.computerName||'').localeCompare(b.computerName||'');});
    var tb=document.getElementById('clients-tb');
    if(!CL.length){tb.innerHTML='<tr><td colspan="7" class="empty">Geen clients gevonden. Installeer de agent op een client en wacht op de eerste run.</td></tr>';updateClientStats();return;}
    tb.innerHTML=CL.map(function(c,i){
      var seen=c.minutesAgo<2?'Zojuist':c.minutesAgo<60?c.minutesAgo+' min':Math.round(c.minutesAgo/60)+' uur';
      var res=c.deploymentResult||'';
      var badge=res==='upToDate'?'<span class="badge b-ok">Up-to-date</span>':res==='installed'?'<span class="badge b-ok">Geinstalleerd</span>':res==='partial'?'<span class="badge b-warn">Deels</span>':res==='failed'?'<span class="badge b-err">Mislukt</span>':'<span class="badge b-gray">—</span>';
      var reboot=c.rebootRequired?'<span class="badge b-warn" style="margin-left:3px">&#9888; Reboot</span>':'';
      return '<tr>'
        +'<td><span class="dot '+(c.online?'on':'off')+'"></span></td>'
        +'<td style="font-weight:600">'+esc(c.computerName)+'</td>'
        +'<td style="font-size:.75rem;color:#64748b">'+esc(c.osCaption||'')+'</td>'
        +'<td style="color:#64748b;font-size:.77rem">'+esc(seen)+' geleden</td>'
        +'<td>'+badge+reboot+'</td>'
        +'<td style="font-size:.75rem;color:#64748b">'+(c.packagesInstalled||0)+' geinstalleerd &nbsp;'+(c.packagesFailed>0?'<span style="color:#dc2626">'+c.packagesFailed+' fout</span>':'')+'</td>'
        +'<td><div class="acts"><button class="btn bpri" onclick="deployClient('+i+')">&#9654; Deploy</button><button class="btn bsec" onclick="showPkgs('+i+')" title="Pakketstatus">&#128269;</button></div></td>'
        +'</tr>';
    }).join('');
    updateClientStats();
  }catch(e){toast('Fout bij laden clients: '+e.message,'t-err');}
}

function updateClientStats(){
  var p=CL,t=p.length,o=p.filter(function(c){return c.online;}).length;
  document.getElementById('cs-total').textContent=t;
  document.getElementById('cs-online').textContent=o;
  document.getElementById('cs-reboot').textContent=p.filter(function(c){return c.rebootRequired;}).length;
  document.getElementById('cs-failed').textContent=p.filter(function(c){return c.packagesFailed>0;}).length;
  document.getElementById('hdr-sub').textContent=o+'/'+t+' online';
}

async function deployClient(i){
  var c=CL[i];if(!c)return;
  try{
    var r=await fetch('/api/clients/'+encodeURIComponent(c.computerName)+'/deploy',{method:'POST'});
    var j=await r.json();
    toast(j.success?(j.immediate?'Direct uitgevoerd: ':'Trigger aangemaakt: ')+c.computerName:'Fout: '+j.message,j.success?'t-ok':'t-err');
  }catch(e){toast('Fout: '+e.message,'t-err');}
}

async function deployAll(){
  var online=CL.filter(function(c){return c.online;});
  if(!online.length){toast('Geen online clients','t-err');return;}
  for(var i=0;i<CL.length;i++){if(CL[i].online)await deployClient(i);}
  toast(online.length+' clients getriggerd');
}

function showPkgs(i){
  var c=CL[i];if(!c||!c.packages)return;
  alert('Pakketstatus '+c.computerName+':\n\n'+c.packages.map(function(p){return(p.action==='installed'?'[INST] ':'[----] ')+p.name+(p.version?' v'+p.version:'')+(p.reason?' — '+p.reason:'');}).join('\n'));
}

// ── Pakketten ─────────────────────────────────────────────────────────────────
async function loadManifest(){
  try{
    var r=await fetch('/api/manifest');M=await r.json();
    renderPkgs();dirty=false;document.getElementById('btn-save').disabled=true;
  }catch(e){toast('Fout bij laden: '+e.message,'t-err');}
}

function renderPkgs(){
  var tb=document.getElementById('pkg-tb');
  if(!M||!M.packages||!M.packages.length){tb.innerHTML='<tr><td colspan="6" class="empty">Geen pakketten in manifest. Gebruik Opnieuw genereren om MSI-bestanden te scannen.</td></tr>';return;}
  tb.innerHTML=M.packages.map(function(p,i){return'<tr>'
    +'<td><div style="font-weight:600">'+esc(p.name||p.id)+'</div><div style="font-size:.68rem;color:#94a3b8;font-family:Consolas,monospace;margin-top:1px">'+esc(p.source||'')+'</div></td>'
    +'<td>'+(p.version?'<span class="badge ver-b">'+esc(p.version)+'</span>':'<span style="color:#cbd5e1">—</span>')+'</td>'
    +'<td><input class="arg-input" value="'+esc(p.arguments||'')+'" placeholder="/qn /norestart" oninput="setArg('+i+',this.value)"></td>'
    +'<td><label class="toggle"><input type="checkbox"'+(p.enabled?' checked':'')+' onchange="tog('+i+',\'enabled\',this.checked)"><span class="sl"></span></label></td>'
    +'<td><label class="toggle"><input type="checkbox"'+(p.required?' checked':'')+' onchange="tog('+i+',\'required\',this.checked)"><span class="sl"></span></label></td>'
    +'<td><button class="btn bdgr" onclick="delPkg('+i+')" title="Pakket verwijderen">&#128465;</button></td>'
    +'</tr>';}).join('');
}

function tog(i,f,v){M.packages[i][f]=v;markDirty();}
function setArg(i,v){M.packages[i].arguments=v;markDirty();}
function delPkg(i){if(!confirm('Pakket "'+M.packages[i].name+'" verwijderen uit het manifest?'))return;M.packages.splice(i,1);renderPkgs();markDirty();}
function markDirty(){dirty=true;document.getElementById('btn-save').disabled=false;}

async function doSave(){
  var btn=document.getElementById('btn-save');btn.disabled=true;
  try{
    var r=await fetch('/api/manifest',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(M)});
    var j=await r.json();
    if(j.success){toast('Manifest opgeslagen');dirty=false;}else{toast('Fout bij opslaan','t-err');btn.disabled=false;}
  }catch(e){toast('Fout: '+e.message,'t-err');btn.disabled=false;}
}

async function doRegen(){
  var btn=document.getElementById('btn-regen');btn.disabled=true;btn.innerHTML='<span class="spin">&#8635;</span> Bezig...';
  var dis=document.getElementById('chk-disabled').checked;
  try{
    var r=await fetch('/api/regenerate',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({disabledByDefault:dis})});
    var j=await r.json();
    if(j.success){showRegenModal(j);await loadManifest();}else toast('Fout: '+j.message,'t-err');
  }catch(e){toast('Fout: '+e.message,'t-err');}
  finally{btn.disabled=false;btn.innerHTML='&#9660; Opnieuw genereren';}
}

function showRegenModal(j){
  var total=j.total||0,added=j.added||0,updated=j.updated||0;
  var rows=(j.packages||[]).map(function(p){return'<div class="pd-row"><span style="font-weight:500">'+esc(p.name||p.source)+(p.version?'<span style="color:#94a3b8;font-family:Consolas;font-size:.7rem;margin-left:.4rem">v'+esc(p.version)+'</span>':'')+'</span>'+(p.isNew?'<span class="nb">NIEUW</span>':p.isUpdated?'<span class="ub">BIJGEWERKT</span>':'')+'</div>';}).join('');
  document.getElementById('regen-body').innerHTML=
    '<div class="rg-stats"><div class="rg-stat"><div class="rg-v blue">'+total+'</div><div class="rg-l">Totaal</div></div><div class="rg-stat"><div class="rg-v green">'+added+'</div><div class="rg-l">Nieuw</div></div><div class="rg-stat"><div class="rg-v amber">'+updated+'</div><div class="rg-l">Bijgewerkt</div></div></div>'
    +(rows?'<div class="pkg-diff">'+rows+'</div>':'')
    +(j.output?'<div class="rg-log">'+esc(j.output)+'</div>':'');
  document.getElementById('regen-overlay').classList.add('show');
}
function closeModal(){document.getElementById('regen-overlay').classList.remove('show');}

// ── Logs ──────────────────────────────────────────────────────────────────────
async function loadLogs(){
  try{
    var r=await fetch('/api/logs'),lines=await r.json();
    var lb=document.getElementById('log-body');
    if(!lines||!lines.length){lb.innerHTML='<div class="ll I" style="color:#475569">Geen logregels.</div>';return;}
    lb.innerHTML=lines.map(function(l){var c=l.indexOf('[ERROR]')>=0?'E':l.indexOf('[WARN]')>=0?'W':'I';return'<div class="ll '+c+'">'+esc(l)+'</div>';}).join('');
    lb.scrollTop=lb.scrollHeight;
  }catch(e){document.getElementById('log-body').innerHTML='<div class="ll E">'+esc(e.message)+'</div>';}
}

// ── Instellingen ──────────────────────────────────────────────────────────────
async function loadCfg(){
  try{
    var r=await fetch('/api/config'),c=await r.json();
    document.getElementById('cfg-share').value=c.SharePath||'';
    document.getElementById('cfg-manifest').value=c.ManifestFile||'apps.json';
    document.getElementById('cfg-logpath').value=c.LogPath||'';
    document.getElementById('cfg-port').value=c.Port||8080;
  }catch(e){toast('Fout bij laden config','t-err');}
}

async function loadSvcInfo(){
  try{
    var r=await fetch('/api/info'),info=await r.json();
    document.getElementById('svc-url').value='http://localhost:'+info.port;
    document.getElementById('svc-manifest').value=info.manifestPath||'';
    document.getElementById('svc-status').value=info.statusPath||'';
    document.getElementById('svc-trigger').value=info.triggerPath||'';
  }catch(e){}
}

async function saveCfg(){
  var cfg={SharePath:document.getElementById('cfg-share').value,ManifestFile:document.getElementById('cfg-manifest').value,LogPath:document.getElementById('cfg-logpath').value,Port:parseInt(document.getElementById('cfg-port').value)||8080};
  try{
    var r=await fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(cfg)});
    var j=await r.json();
    if(j.success)toast('Configuratie opgeslagen');else toast('Fout bij opslaan','t-err');
  }catch(e){toast('Fout: '+e.message,'t-err');}
}

async function setPermissions(){
  var account=document.getElementById('perm-account').value.trim();
  if(!account){toast('Voer een accountnaam in','t-err');return;}
  try{
    var r=await fetch('/api/setup/set-perms',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({account:account})});
    var j=await r.json();
    toast(j.success?j.message:'Fout: '+j.message,j.success?'t-ok':'t-err');
    if(j.success)loadSetup();
  }catch(e){toast('Fout: '+e.message,'t-err');}
}

// Init
loadSetup();
setInterval(loadClients,60000);
setInterval(loadLogs,30000);
</script>
</body>
</html>
'@

# ── HTTP server ───────────────────────────────────────────────────────────────

$url = "http://localhost:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($url)
try { $listener.Start() } catch { throw "Kan server niet starten op poort ${Port}: $($_.Exception.Message)" }

Write-Host ""; Write-Host "  WinAppDeploy Dashboard  —  $url"; Write-Host "  Ctrl+C om te stoppen."; Write-Host ""
if (-not $NoOpenBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        $context = $null
        try { $context = $listener.GetContext() }
        catch [System.Net.HttpListenerException] { if (-not $listener.IsListening) { break }; continue }

        $req = $context.Request; $res = $context.Response
        $method = $req.HttpMethod; $path = $req.Url.LocalPath

        try {
            if     ($method -eq "GET"  -and $path -eq "/")                { Send-Response $res $html "text/html; charset=utf-8" }
            elseif ($method -eq "GET"  -and $path -eq "/api/setup")       { Send-Response $res (Get-SetupStatus) }
            elseif ($method -eq "POST" -and $path -eq "/api/setup/create-dirs") {
                try   { $msg = Invoke-SetupCreateDirs; Send-Response $res (@{success=$true;message=$msg}|ConvertTo-Json -Compress) }
                catch { Send-Response $res (@{success=$false;message=$_.Exception.Message}|ConvertTo-Json -Compress) }
            }
            elseif ($method -eq "POST" -and $path -eq "/api/setup/create-share") {
                try   { $msg = Invoke-SetupCreateShare; Send-Response $res (@{success=$true;message=$msg}|ConvertTo-Json -Compress) }
                catch { Send-Response $res (@{success=$false;message=$_.Exception.Message}|ConvertTo-Json -Compress) }
            }
            elseif ($method -eq "POST" -and $path -eq "/api/setup/set-perms") {
                try {
                    $body = Read-Body $req
                    $account = if ($body) { ($body|ConvertFrom-Json).account } else { "Domain Computers" }
                    if ([string]::IsNullOrWhiteSpace($account)) { $account = "Domain Computers" }
                    $msg = Invoke-SetupSetPermissions -Account $account
                    Send-Response $res (@{success=$true;message=$msg}|ConvertTo-Json -Compress)
                } catch { Send-Response $res (@{success=$false;message=$_.Exception.Message}|ConvertTo-Json -Compress) }
            }
            elseif ($method -eq "GET"  -and $path -eq "/api/manifest")    { Send-Response $res (Get-ManifestContent) }
            elseif ($method -eq "POST" -and $path -eq "/api/manifest")    { Save-ManifestContent (Read-Body $req); Send-Response $res '{"success":true}' }
            elseif ($method -eq "POST" -and $path -eq "/api/regenerate")  {
                try {
                    $dis = $false
                    try { $b = Read-Body $req; if ($b) { $dis = [bool]($b|ConvertFrom-Json).disabledByDefault } } catch {}
                    $diff = Invoke-ManifestRegenerateWithDiff -DisabledByDefault:$dis
                    $parts = $diff.packages | ForEach-Object { $_ | ConvertTo-Json -Compress }
                    $pkgJ = '[' + ($parts -join ',') + ']'
                    Send-Response $res ('{"success":true,"output":'+($diff.output|ConvertTo-Json)+',"total":'+$diff.total+',"added":'+$diff.added+',"updated":'+$diff.updated+',"packages":'+$pkgJ+'}')
                } catch { Send-Response $res (@{success=$false;message=$_.Exception.Message}|ConvertTo-Json -Compress) }
            }
            elseif ($method -eq "GET"  -and $path -eq "/api/clients")     { Send-Response $res (Get-ClientsJson) }
            elseif ($method -eq "POST" -and $path -match "^/api/clients/([^/]+)/deploy$") {
                $clientName = [uri]::UnescapeDataString($Matches[1])
                New-Item -ItemType Directory -Path $triggerPath -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $triggerPath "$clientName.trigger") -Value (Get-Date).ToString("o") -Encoding UTF8
                $immediate = $false
                try { Invoke-Command -ComputerName $clientName -FilePath (Join-Path $scriptsDir "AppDeploymentAgent.ps1") -ErrorAction Stop; $immediate = $true; Remove-Item (Join-Path $triggerPath "$clientName.trigger") -Force -ErrorAction SilentlyContinue } catch {}
                Send-Response $res (@{success=$true;immediate=$immediate;message=if($immediate){"Direct uitgevoerd"}else{"Trigger aangemaakt"}}|ConvertTo-Json -Compress)
            }
            elseif ($method -eq "GET"  -and $path -eq "/api/logs")        {
                $lines = @(Get-LogLines -MaxLines 200)
                $parts = $lines | ForEach-Object { $_ | ConvertTo-Json }
                Send-Response $res ('[' + ($parts -join ',') + ']')
            }
            elseif ($method -eq "GET"  -and $path -eq "/api/config")      { Send-Response $res (Get-ServerConfig) }
            elseif ($method -eq "POST" -and $path -eq "/api/config")      { Save-ServerConfig (Read-Body $req); Send-Response $res '{"success":true}' }
            elseif ($method -eq "GET"  -and $path -eq "/api/info")        {
                Send-Response $res (@{port=$Port;manifestPath=$manifestPath;statusPath=$statusPath;triggerPath=$triggerPath;sharePath=$SharePath}|ConvertTo-Json -Compress)
            }
            else { Send-Response $res '{"error":"Not Found"}' "application/json" 404 }
        } catch {
            try { Send-Response $res (@{error=$_.Exception.Message}|ConvertTo-Json -Compress) "application/json" 500 } catch {}
        }
    }
} finally { $listener.Stop(); Write-Host "Dashboard gestopt." }
