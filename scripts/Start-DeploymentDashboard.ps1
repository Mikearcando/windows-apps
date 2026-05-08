[CmdletBinding()]
param(
    [string]$SharePath,

    [string]$ConfigPath = "C:\ProgramData\AppDeployment\server.config.json",

    [string]$ManifestFile = "apps.json",

    [string]$LogPath = "C:\ProgramData\AppDeployment\Logs",

    [int]$Port = 8080,

    [switch]$NoOpenBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Config laden vanuit bestand (gebruikt door de service); directe parameters winnen
if (Test-Path -LiteralPath $ConfigPath) {
    $serverCfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($SharePath))    { $SharePath   = $serverCfg.SharePath }
    if ($Port -eq 8080 -and $serverCfg.Port)         { $Port        = [int]$serverCfg.Port }
    if ($serverCfg.LogPath)                          { $LogPath     = $serverCfg.LogPath }
    if ($serverCfg.ManifestFile)                     { $ManifestFile = $serverCfg.ManifestFile }
}

if ([string]::IsNullOrWhiteSpace($SharePath)) {
    throw "SharePath is verplicht. Geef -SharePath op of stel in via $ConfigPath"
}

$manifestPath = if ([System.IO.Path]::IsPathRooted($ManifestFile)) { $ManifestFile }
                else { Join-Path $SharePath $ManifestFile }
$statusPath   = Join-Path $SharePath "status"
$triggerPath  = Join-Path $SharePath "triggers"
$scriptsDir   = $PSScriptRoot

function Send-Response {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse]$Response,
        [string]$Body = "",
        [string]$ContentType = "application/json; charset=utf-8",
        [int]$StatusCode = 200
    )
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $buf = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Response.ContentLength64 = $buf.Length
    $Response.OutputStream.Write($buf, 0, $buf.Length)
    $Response.OutputStream.Close()
}

function Get-ManifestContent {
    if (-not (Test-Path -LiteralPath $manifestPath)) { return '{"schemaVersion":1,"packages":[]}' }
    return Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
}

function Save-ManifestContent {
    param([string]$Json)
    $parsed = $Json | ConvertFrom-Json
    $formatted = $parsed | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $manifestPath -Value $formatted -Encoding UTF8
}

function Get-ClientsJson {
    $clients = @()
    if (Test-Path -LiteralPath $statusPath) {
        foreach ($file in Get-ChildItem -LiteralPath $statusPath -Filter "*.json" -File -ErrorAction SilentlyContinue) {
            try {
                $c = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $lastSeen = [datetime]::Parse($c.lastSeenUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                $minutesAgo = [int]([datetime]::UtcNow - $lastSeen).TotalMinutes
                # Online = gezien binnen 90 minuten
                $online = $minutesAgo -le 90
                $c | Add-Member -NotePropertyName "online"     -NotePropertyValue $online     -Force
                $c | Add-Member -NotePropertyName "minutesAgo" -NotePropertyValue $minutesAgo -Force
                $clients += $c
            } catch { }
        }
    }
    $jsonParts = $clients | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }
    return '[' + ($jsonParts -join ',') + ']'
}

function Get-LogLines {
    param([int]$MaxLines = 200)
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) {
        return @("Log pad niet gevonden: $LogPath")
    }
    $files = Get-ChildItem -LiteralPath $LogPath -Filter "agent-*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($files.Count -eq 0) { return @("Geen logbestanden gevonden in: $LogPath") }
    $all = @()
    foreach ($f in $files) {
        $all += @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($all.Count -ge $MaxLines) { break }
    }
    return @($all | Select-Object -Last $MaxLines)
}

function Get-ServerConfig {
    if (Test-Path -LiteralPath $ConfigPath) {
        return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    }
    return (@{ SharePath = $SharePath; ManifestFile = $ManifestFile; LogPath = $LogPath; Port = $Port } | ConvertTo-Json)
}

function Save-ServerConfig {
    param([string]$Json)
    $parsed = $Json | ConvertFrom-Json
    $dir = Split-Path $ConfigPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $parsed | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Invoke-ManifestRegenerate {
    $scriptFile = Join-Path $scriptsDir "New-AppDeploymentManifest.ps1"
    if (-not (Test-Path -LiteralPath $scriptFile)) { throw "Script niet gevonden: $scriptFile" }
    $output = & $scriptFile -SharePath $SharePath 2>&1 | Out-String
    return $output.Trim()
}

# ── HTML dashboard ────────────────────────────────────────────────────────────

$html = @'
<!DOCTYPE html>
<html lang="nl">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WinAppDeploy</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f1f5f9;color:#1e293b}
header{background:#1e3a8a;color:#fff;padding:.8rem 1.75rem;display:flex;align-items:center;justify-content:space-between}
.hdr{display:flex;align-items:center;gap:.6rem}
.hdr h1{font-size:1.05rem;font-weight:700}
.live{background:#22c55e;color:#fff;font-size:.6rem;font-weight:800;padding:2px 8px;border-radius:999px;letter-spacing:.06em}
.live::before{content:'● '}
.hdr-sub{font-size:.7rem;color:#93c5fd;font-family:Consolas,monospace}
nav{background:#1e3a8a;border-top:1px solid rgba(255,255,255,.12);padding:0 1.75rem;display:flex;gap:0}
.tab{background:transparent;border:none;color:rgba(255,255,255,.6);padding:.65rem 1.1rem;font-size:.82rem;font-weight:500;cursor:pointer;border-bottom:2px solid transparent;transition:.15s}
.tab:hover{color:#fff}.tab.on{color:#fff;border-bottom-color:#60a5fa}
main{padding:1.25rem 1.75rem;max-width:1400px}
.pane{display:none}.pane.on{display:block}
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:.875rem;margin-bottom:1.25rem}
.sc{background:#fff;border-radius:9px;padding:1.1rem 1.25rem;box-shadow:0 1px 3px rgba(0,0,0,.08);border-left:3px solid transparent}
.sc.b{border-color:#3b82f6}.sc.g{border-color:#22c55e}.sc.a{border-color:#f59e0b}.sc.r{border-color:#ef4444}
.sc-l{font-size:.7rem;color:#64748b;font-weight:600;text-transform:uppercase;letter-spacing:.05em;margin-bottom:.2rem}
.sc-v{font-size:2rem;font-weight:800;line-height:1}
.b .sc-v{color:#3b82f6}.g .sc-v{color:#22c55e}.a .sc-v{color:#f59e0b}.r .sc-v{color:#ef4444}
.panel{background:#fff;border-radius:9px;box-shadow:0 1px 3px rgba(0,0,0,.08);overflow:hidden;margin-bottom:1.25rem}
.ph{padding:.8rem 1.25rem;border-bottom:1px solid #f1f5f9;display:flex;align-items:center;justify-content:space-between}
.ph h2{font-size:.88rem;font-weight:600}
.acts{display:flex;gap:.4rem;flex-wrap:wrap}
.btn{display:inline-flex;align-items:center;gap:4px;padding:.35rem .8rem;border-radius:5px;border:none;cursor:pointer;font-size:.76rem;font-weight:500;transition:background .12s,transform .1s;white-space:nowrap}
.btn:active{transform:scale(.97)}.btn:disabled{opacity:.5;cursor:not-allowed;transform:none}
.bpri{background:#2563eb;color:#fff}.bpri:hover:not(:disabled){background:#1d4ed8}
.bsuc{background:#22c55e;color:#fff}.bsuc:hover:not(:disabled){background:#16a34a}
.bsec{background:#f1f5f9;color:#334155;border:1px solid #e2e8f0}.bsec:hover:not(:disabled){background:#e2e8f0}
.bdgr{background:#fee2e2;color:#b91c1c;border:1px solid #fecaca}.bdgr:hover:not(:disabled){background:#fecaca}
table{width:100%;border-collapse:collapse}
th{padding:.5rem .9rem;text-align:left;font-size:.67rem;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:.05em;background:#f8fafc;white-space:nowrap}
td{padding:.6rem .9rem;border-top:1px solid #f1f5f9;font-size:.83rem;vertical-align:middle}
tr:hover td{background:#fafbff}
.dot{width:9px;height:9px;border-radius:50%;display:inline-block;flex-shrink:0}
.dot.on{background:#22c55e;box-shadow:0 0 0 3px #dcfce7}.dot.off{background:#94a3b8}
.ci{display:flex;align-items:center;gap:.5rem}
.cn{font-weight:600}.cos{font-size:.7rem;color:#64748b;margin-top:1px}
.badge{display:inline-block;font-size:.68rem;padding:1px 7px;border-radius:999px;font-weight:600}
.b-ok{background:#dcfce7;color:#15803d}.b-warn{background:#fef9c3;color:#854d0e}.b-err{background:#fee2e2;color:#b91c1c}.b-gray{background:#f1f5f9;color:#64748b}
.vb{background:#ede9fe;color:#6d28d9;font-family:Consolas,monospace}
.toggle{position:relative;display:inline-block;width:36px;height:20px;flex-shrink:0}
.toggle input{opacity:0;width:0;height:0}
.sl{position:absolute;cursor:pointer;inset:0;background:#cbd5e1;border-radius:20px;transition:.18s}
.sl::before{position:absolute;content:'';height:14px;width:14px;left:3px;bottom:3px;background:#fff;border-radius:50%;transition:.18s;box-shadow:0 1px 3px rgba(0,0,0,.2)}
input:checked+.sl{background:#3b82f6}
input:checked+.sl::before{transform:translateX(16px)}
.log-body{height:500px;overflow-y:auto;padding:.75rem 1rem;background:#0f172a;font-family:Consolas,'Courier New',monospace;font-size:.7rem;line-height:1.55}
.ll{margin-bottom:1px;white-space:pre-wrap;word-break:break-all}
.ll.I{color:#94a3b8}.ll.W{color:#fbbf24}.ll.E{color:#f87171}
.form-row{display:grid;grid-template-columns:200px 1fr;align-items:center;gap:.75rem;padding:.6rem 1.25rem;border-bottom:1px solid #f1f5f9}
.form-row label{font-size:.8rem;font-weight:500;color:#374151}
.form-row input,.form-row select{width:100%;padding:.4rem .6rem;border:1px solid #d1d5db;border-radius:5px;font-size:.82rem;color:#1e293b}
.form-row input:focus,.form-row select:focus{outline:none;border-color:#3b82f6;box-shadow:0 0 0 2px #dbeafe}
.form-foot{padding:.8rem 1.25rem;display:flex;gap:.5rem}
.info-box{background:#eff6ff;border:1px solid #bfdbfe;border-radius:7px;padding:.75rem 1rem;font-size:.78rem;color:#1e40af;margin:.75rem 1.25rem}
.toast{position:fixed;bottom:1.25rem;right:1.25rem;color:#fff;padding:.55rem 1.1rem;border-radius:7px;font-size:.78rem;font-weight:500;opacity:0;transition:opacity .22s;pointer-events:none;z-index:999}
.toast.show{opacity:1}.t-ok{background:#15803d}.t-err{background:#dc2626}
@keyframes spin{to{transform:rotate(360deg)}}
.spin{display:inline-block;animation:spin .7s linear infinite}
.pkg-name{font-weight:600}.pkg-src{font-size:.68rem;color:#94a3b8;font-family:Consolas,monospace;margin-top:1px}
.empty{text-align:center;color:#94a3b8;padding:2.5rem;font-size:.85rem}
</style>
</head>
<body>
<header>
  <div class="hdr"><h1>&#9881; WinAppDeploy</h1><span class="live">LIVE</span></div>
  <span class="hdr-sub" id="hdr-sub"></span>
</header>
<nav>
  <button class="tab on" onclick="tab('clients')">&#128187; Clients</button>
  <button class="tab" onclick="tab('pakketten')">&#128230; Pakketten</button>
  <button class="tab" onclick="tab('logs')">&#128196; Logs</button>
  <button class="tab" onclick="tab('instellingen')">&#9881; Instellingen</button>
</nav>
<main>

<!-- ── CLIENTS ── -->
<div class="pane on" id="pane-clients">
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
        <thead><tr><th>Status</th><th>Computer</th><th>OS</th><th>Gezien</th><th>Deployment</th><th>Pakketten</th><th>Actie</th></tr></thead>
        <tbody id="clients-tb"><tr><td colspan="7" class="empty">Laden...</td></tr></tbody>
      </table>
    </div>
  </div>
</div>

<!-- ── PAKKETTEN ── -->
<div class="pane" id="pane-pakketten">
  <div class="panel">
    <div class="ph">
      <h2>&#128230; Pakketten</h2>
      <div class="acts">
        <button class="btn bsec" onclick="loadManifest()">&#8635; Vernieuwen</button>
        <button class="btn bsec" id="btn-regen" onclick="doRegen()">&#9660; Opnieuw genereren</button>
        <button class="btn bsuc" id="btn-save" onclick="doSave()" disabled>&#10003; Opslaan</button>
      </div>
    </div>
    <div style="overflow-x:auto">
      <table>
        <thead><tr><th>Naam</th><th>Versie</th><th>Bron</th><th>Ingeschakeld</th><th>Verplicht</th></tr></thead>
        <tbody id="pkg-tb"><tr><td colspan="5" class="empty">Laden...</td></tr></tbody>
      </table>
    </div>
  </div>
</div>

<!-- ── LOGS ── -->
<div class="pane" id="pane-logs">
  <div class="panel">
    <div class="ph">
      <h2>&#128196; Agent logs</h2>
      <div class="acts">
        <button class="btn bsec" onclick="loadLogs()">&#8635; Vernieuwen</button>
      </div>
    </div>
    <div class="log-body" id="log-body"><div class="ll I">Laden...</div></div>
  </div>
</div>

<!-- ── INSTELLINGEN ── -->
<div class="pane" id="pane-instellingen">
  <div class="panel">
    <div class="ph"><h2>&#9881; Serverconfiguratie</h2></div>
    <div class="form-row"><label>Share pad</label><input id="cfg-share" type="text" placeholder="\\SERVER\AppDeployment"></div>
    <div class="form-row"><label>Manifest bestand</label><input id="cfg-manifest" type="text" placeholder="apps.json"></div>
    <div class="form-row"><label>Log map</label><input id="cfg-logpath" type="text" placeholder="C:\ProgramData\AppDeployment\Logs"></div>
    <div class="form-row"><label>Poort</label><input id="cfg-port" type="number" placeholder="8080" style="width:120px"></div>
    <div class="info-box">&#8505; Een poortwijziging vereist een herstart van de dashboardservice.</div>
    <div class="form-foot">
      <button class="btn bsuc" onclick="saveCfg()">&#10003; Configuratie opslaan</button>
      <button class="btn bsec" onclick="loadCfg()">&#8635; Opnieuw laden</button>
    </div>
  </div>
  <div class="panel">
    <div class="ph"><h2>&#128203; Service info</h2></div>
    <div class="form-row"><label>Dashboard URL</label><input readonly value="http://localhost" id="svc-url" type="text"></div>
    <div class="form-row"><label>Manifest pad</label><input readonly id="svc-manifest" type="text"></div>
    <div class="form-row"><label>Status map</label><input readonly id="svc-status" type="text"></div>
    <div class="form-row"><label>Trigger map</label><input readonly id="svc-trigger" type="text"></div>
  </div>
</div>

</main>
<div class="toast" id="toast"></div>
<script>
var M=null,dirty=false,CL=[];

function esc(s){if(s==null)return'';return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}

function toast(msg,t){var e=document.getElementById('toast');e.textContent=msg;e.className='toast show '+(t||'t-ok');clearTimeout(e._t);e._t=setTimeout(function(){e.className='toast';},3200);}

function tab(name){
  document.querySelectorAll('.tab').forEach(function(b,i){b.classList.toggle('on',['clients','pakketten','logs','instellingen'][i]===name);});
  document.querySelectorAll('.pane').forEach(function(p){p.classList.toggle('on',p.id==='pane-'+name);});
  if(name==='clients')loadClients();
  if(name==='pakketten')loadManifest();
  if(name==='logs')loadLogs();
  if(name==='instellingen'){loadCfg();loadSvcInfo();}
}

// ── Clients ──────────────────────────────────────────────────────────────────
async function loadClients(){
  try{
    var r=await fetch('/api/clients');CL=await r.json();
    CL.sort(function(a,b){if(a.online!==b.online)return a.online?-1:1;return(a.computerName||'').localeCompare(b.computerName||'');});
    var tb=document.getElementById('clients-tb');
    if(!CL.length){tb.innerHTML='<tr><td colspan="7" class="empty">Geen clientstatusbestanden gevonden.<br>Controleer of de agent al heeft gedraaid en schrijftoegang heeft tot de share.</td></tr>';updateClientStats();return;}
    tb.innerHTML=CL.map(function(c,i){
      var dot='<span class="dot '+(c.online?'on':'off')+'"></span>';
      var seen=c.minutesAgo<2?'Zojuist':c.minutesAgo<60?c.minutesAgo+' min geleden':Math.round(c.minutesAgo/60)+' uur geleden';
      var res=c.deploymentResult||'';
      var resBadge=res==='upToDate'?'<span class="badge b-ok">Up-to-date</span>':res==='installed'?'<span class="badge b-ok">Geinstalleerd</span>':res==='partial'?'<span class="badge b-warn">Deels</span>':res==='failed'?'<span class="badge b-err">Mislukt</span>':'<span class="badge b-gray">Onbekend</span>';
      var reboot=c.rebootRequired?'<span class="badge b-warn" title="Reboot vereist">&#9888; Reboot</span>':'';
      var pkgs='<span style="color:#64748b;font-size:.75rem">'+(c.packagesInstalled||0)+' inst. / '+(c.packagesFailed||0)+' fout</span>';
      return '<tr><td><div class="ci">'+dot+'</div></td>'
        +'<td><div class="cn">'+esc(c.computerName)+'</div></td>'
        +'<td><div class="cos">'+esc(c.osCaption||'')+'</div></td>'
        +'<td style="color:#64748b;font-size:.78rem">'+esc(seen)+'</td>'
        +'<td>'+resBadge+' '+reboot+'</td>'
        +'<td>'+pkgs+'</td>'
        +'<td><div class="acts"><button class="btn bpri" onclick="deployClient('+i+')">&#9654; Deploy</button>'
        +'<button class="btn bsec" onclick="showPkgs('+i+')" title="Pakketstatus bekijken">&#128269;</button></div></td>'
        +'</tr>';
    }).join('');
    updateClientStats();
  }catch(e){toast('Fout bij laden clients: '+e.message,'t-err');}
}

function updateClientStats(){
  var total=CL.length,online=CL.filter(function(c){return c.online;}).length;
  var reboot=CL.filter(function(c){return c.rebootRequired;}).length;
  var failed=CL.filter(function(c){return c.packagesFailed>0;}).length;
  document.getElementById('cs-total').textContent=total;
  document.getElementById('cs-online').textContent=online;
  document.getElementById('cs-reboot').textContent=reboot;
  document.getElementById('cs-failed').textContent=failed;
  document.getElementById('hdr-sub').textContent=online+'/'+total+' online';
}

async function deployClient(i){
  var c=CL[i];if(!c)return;
  try{
    var r=await fetch('/api/clients/'+encodeURIComponent(c.computerName)+'/deploy',{method:'POST'});
    var j=await r.json();
    if(j.success)toast((j.immediate?'&#9654; Direct uitgevoerd':'&#128203; Trigger aangemaakt')+' voor '+c.computerName);
    else toast('Fout: '+j.message,'t-err');
  }catch(e){toast('Fout: '+e.message,'t-err');}
}

async function deployAll(){
  var online=CL.filter(function(c){return c.online;});
  if(!online.length){toast('Geen online clients gevonden','t-err');return;}
  for(var i=0;i<CL.length;i++){if(CL[i].online)await deployClient(i);}
  toast(online.length+' clients getriggerd');
}

function showPkgs(i){
  var c=CL[i];if(!c||!c.packages)return;
  var lines=c.packages.map(function(p){return(p.action==='installed'?'[OK]  ':'[--]  ')+p.name+(p.version?' v'+p.version:'')+(p.reason?' ('+p.reason+')':'');});
  alert('Pakketstatus '+c.computerName+':\n\n'+lines.join('\n'));
}

// ── Pakketten ─────────────────────────────────────────────────────────────────
async function loadManifest(){
  try{
    var r=await fetch('/api/manifest');M=await r.json();
    renderPkgs();dirty=false;document.getElementById('btn-save').disabled=true;
  }catch(e){toast('Fout bij laden manifest: '+e.message,'t-err');}
}

function renderPkgs(){
  var tb=document.getElementById('pkg-tb');
  if(!M||!M.packages||!M.packages.length){tb.innerHTML='<tr><td colspan="5" class="empty">Geen pakketten.</td></tr>';return;}
  tb.innerHTML=M.packages.map(function(p,i){return'<tr>'
    +'<td><div class="pkg-name">'+esc(p.name||p.id)+'</div></td>'
    +'<td>'+(p.version?'<span class="badge vb">'+esc(p.version)+'</span>':'<span style="color:#cbd5e1">—</span>')+'</td>'
    +'<td><div style="font-size:.7rem;color:#94a3b8;font-family:Consolas,monospace">'+esc(p.source||'')+'</div></td>'
    +'<td><label class="toggle"><input type="checkbox"'+(p.enabled?' checked':'')+' onchange="tog('+i+',\'enabled\',this.checked)"><span class="sl"></span></label></td>'
    +'<td><label class="toggle"><input type="checkbox"'+(p.required?' checked':'')+' onchange="tog('+i+',\'required\',this.checked)"><span class="sl"></span></label></td>'
    +'</tr>';}).join('');
}

function tog(i,f,v){M.packages[i][f]=v;dirty=true;document.getElementById('btn-save').disabled=false;}

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
  try{
    var r=await fetch('/api/regenerate',{method:'POST'});var j=await r.json();
    if(j.success){toast('Manifest opnieuw gegenereerd');await loadManifest();}else toast('Fout: '+j.message,'t-err');
  }catch(e){toast('Fout: '+e.message,'t-err');}
  finally{btn.disabled=false;btn.innerHTML='&#9660; Opnieuw genereren';}
}

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
  }catch(e){toast('Fout bij laden config: '+e.message,'t-err');}
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
  var cfg={
    SharePath:document.getElementById('cfg-share').value,
    ManifestFile:document.getElementById('cfg-manifest').value,
    LogPath:document.getElementById('cfg-logpath').value,
    Port:parseInt(document.getElementById('cfg-port').value)||8080
  };
  try{
    var r=await fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(cfg)});
    var j=await r.json();
    if(j.success)toast('Configuratie opgeslagen');else toast('Fout bij opslaan','t-err');
  }catch(e){toast('Fout: '+e.message,'t-err');}
}

// Init
loadClients();
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

try {
    $listener.Start()
} catch {
    throw "Kan HTTP-server niet starten op poort ${Port}: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "  WinAppDeploy Dashboard"
Write-Host "  ======================"
Write-Host "  URL      : $url"
Write-Host "  Manifest : $manifestPath"
Write-Host "  Logs     : $LogPath"
Write-Host "  Config   : $ConfigPath"
Write-Host ""
Write-Host "  Ctrl+C om te stoppen."
Write-Host ""

if (-not $NoOpenBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        $context = $null
        try { $context = $listener.GetContext() }
        catch [System.Net.HttpListenerException] { if (-not $listener.IsListening) { break }; continue }

        $req    = $context.Request
        $res    = $context.Response
        $method = $req.HttpMethod
        $path   = $req.Url.LocalPath

        try {
            if ($method -eq "GET" -and $path -eq "/") {
                Send-Response -Response $res -Body $html -ContentType "text/html; charset=utf-8"
            }
            elseif ($method -eq "GET" -and $path -eq "/api/manifest") {
                Send-Response -Response $res -Body (Get-ManifestContent)
            }
            elseif ($method -eq "POST" -and $path -eq "/api/manifest") {
                $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
                Save-ManifestContent -Json $body
                Send-Response -Response $res -Body '{"success":true}'
            }
            elseif ($method -eq "POST" -and $path -eq "/api/regenerate") {
                try {
                    $out = Invoke-ManifestRegenerate
                    Send-Response -Response $res -Body (@{ success = $true; message = $out } | ConvertTo-Json -Compress)
                } catch {
                    Send-Response -Response $res -Body (@{ success = $false; message = $_.Exception.Message } | ConvertTo-Json -Compress)
                }
            }
            elseif ($method -eq "GET" -and $path -eq "/api/clients") {
                Send-Response -Response $res -Body (Get-ClientsJson)
            }
            elseif ($method -eq "POST" -and $path -match "^/api/clients/([^/]+)/deploy$") {
                $clientName = [uri]::UnescapeDataString($Matches[1])

                New-Item -ItemType Directory -Path $triggerPath -Force | Out-Null
                $triggerFile = Join-Path $triggerPath "$clientName.trigger"
                Set-Content -LiteralPath $triggerFile -Value (Get-Date).ToString("o") -Encoding UTF8

                # Probeer WinRM voor directe uitvoering
                $immediate = $false
                try {
                    $agentScript = Join-Path $scriptsDir "AppDeploymentAgent.ps1"
                    Invoke-Command -ComputerName $clientName -FilePath $agentScript -ErrorAction Stop
                    $immediate = $true
                    Remove-Item -LiteralPath $triggerFile -Force -ErrorAction SilentlyContinue
                } catch { }

                $msg = if ($immediate) { "Direct uitgevoerd via WinRM" } else { "Trigger aangemaakt, voert uit bij volgende taakrun" }
                Send-Response -Response $res -Body (@{ success = $true; message = $msg; immediate = $immediate } | ConvertTo-Json -Compress)
            }
            elseif ($method -eq "GET" -and $path -eq "/api/logs") {
                $lines = @(Get-LogLines -MaxLines 200)
                $parts = $lines | ForEach-Object { $_ | ConvertTo-Json }
                Send-Response -Response $res -Body ('[' + ($parts -join ',') + ']')
            }
            elseif ($method -eq "GET" -and $path -eq "/api/config") {
                Send-Response -Response $res -Body (Get-ServerConfig)
            }
            elseif ($method -eq "POST" -and $path -eq "/api/config") {
                $body = (New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
                Save-ServerConfig -Json $body
                Send-Response -Response $res -Body '{"success":true}'
            }
            elseif ($method -eq "GET" -and $path -eq "/api/info") {
                $info = @{
                    port         = $Port
                    manifestPath = $manifestPath
                    statusPath   = $statusPath
                    triggerPath  = $triggerPath
                    sharePath    = $SharePath
                } | ConvertTo-Json -Compress
                Send-Response -Response $res -Body $info
            }
            else {
                Send-Response -Response $res -Body '{"error":"Not Found"}' -StatusCode 404
            }
        } catch {
            try { Send-Response -Response $res -Body (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) -StatusCode 500 } catch {}
        }
    }
} finally {
    $listener.Stop()
    Write-Host "Dashboard gestopt."
}
