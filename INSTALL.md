# WinAppDeploy — Installatiehandleiding

Volg deze handleiding stap voor stap. Voer elke stap volledig uit voordat je doorgaat naar de volgende.

---

## Overzicht

```
┌─────────────────────────────────────────────────────┐
│  SERVER (één keer instellen)                        │
│                                                     │
│  1. Scripts downloaden                              │
│  2. Share aanmaken  (D:\AppDeployment)              │
│  3. MSI-bestanden plaatsen                          │
│  4. Manifest genereren  →  apps.json                │
│  5. Dashboard installeren  →  http://localhost:8080 │
└──────────────────────┬──────────────────────────────┘
                       │  Netwerkshare  \\SERVER\AppDeployment
┌──────────────────────▼──────────────────────────────┐
│  CLIENT (herhalen per computer)                     │
│                                                     │
│  6. Agent installeren                               │
│  7. Agent testen                                    │
└─────────────────────────────────────────────────────┘
```

> Alle PowerShell-commando's worden uitgevoerd als **Administrator**. Klik met rechtermuisknop op PowerShell → *Als administrator uitvoeren*.

---

## Vereisten

| Onderdeel | Vereiste |
|---|---|
| Server OS | Windows Server 2016 of nieuwer (of Windows 10/11 Pro) |
| Client OS | Windows 10 of nieuwer |
| PowerShell | 5.1 (`powershell.exe`) — standaard aanwezig op Windows |
| Netwerk | Clients moeten de server via naam of IP kunnen bereiken |
| MSI-bestanden | Moeten stille installatie ondersteunen (`/qn`) |

> **Let op:** gebruik altijd `powershell.exe` en **niet** `pwsh.exe` (PowerShell 7). De manifest-generator maakt gebruik van Windows Installer COM dat niet goed werkt in PowerShell 7.

---

## Stap 1 — Scripts downloaden (server)

1. Download het project als ZIP of kloon de repository naar de server.
2. Pak het ZIP-bestand uit, bijvoorbeeld naar:
   ```
   C:\Users\Administrator\Documents\windows-apps-main
   ```
3. Controleer of de map `scripts\` de volgende bestanden bevat:

   ```
   scripts\
     New-AppDeploymentManifest.ps1
     AppDeploymentAgent.ps1
     Install-AppDeploymentAgent.ps1
     Uninstall-AppDeploymentAgent.ps1
     Start-DeploymentDashboard.ps1
     Install-DashboardService.ps1
     Uninstall-DashboardService.ps1
     Pre-Check.ps1
   ```

4. Open PowerShell **als administrator** en ga naar de projectmap:
   ```powershell
   cd "C:\Users\Administrator\Documents\windows-apps-main"
   ```

5. Sta het uitvoeren van scripts toe (eenmalig):
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
   ```
   Bevestig met `J` of `Y`.

---

## Stap 2 — Share aanmaken (server)

### 2a. Map aanmaken

```powershell
New-Item -ItemType Directory -Path "D:\AppDeployment" -Force
```

> Gebruik een andere schijfletter als `D:` niet beschikbaar is, maar pas dan alle verdere commando's ook aan.

### 2b. SMB-share aanmaken

```powershell
New-SmbShare -Name "AppDeployment" -Path "D:\AppDeployment" -ReadAccess "Domain Computers"
```

Controleer of de share werkt:
```powershell
Get-SmbShare -Name "AppDeployment"
```

Je zou nu `\\<SERVERNAAM>\AppDeployment` moeten kunnen bereiken vanaf een andere computer.

### 2c. Submappen aanmaken met schrijftoegang voor clients

Clients moeten hun status en triggers kunnen wegschrijven:

```powershell
New-Item -ItemType Directory -Path "D:\AppDeployment\status"
New-Item -ItemType Directory -Path "D:\AppDeployment\triggers"

$acl  = Get-Acl "D:\AppDeployment\status"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "Domain Computers", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($rule)
Set-Acl "D:\AppDeployment\status"   $acl
Set-Acl "D:\AppDeployment\triggers" $acl
```

---

## Stap 3 — MSI-bestanden plaatsen (server)

Kopieer de MSI-installatiebestanden naar `D:\AppDeployment`:

```
D:\AppDeployment\
  Chrome.msi
  7-Zip.msi
  VLC.msi
  ...
```

Je kunt submappen gebruiken, het script zoekt recursief.

---

## Stap 4 — Manifest genereren (server)

> **Belangrijk:** gebruik hier `powershell.exe`, niet `pwsh`.

```powershell
powershell.exe -File .\scripts\New-AppDeploymentManifest.ps1 -SharePath "D:\AppDeployment"
```

Als het goed gaat zie je:
```
Manifest geschreven: D:\AppDeployment\apps.json (3 package(s))
```

Open `D:\AppDeployment\apps.json` om te controleren. Elk pakket staat er standaard op `enabled: true` en `required: true`. Je kunt dit later aanpassen via het dashboard.

> **Fout "Access is denied"?** Je gebruikt waarschijnlijk een UNC-pad (`\\SERVER\...`). Gebruik het **lokale pad** (`D:\AppDeployment`) wanneer je op de server zelf werkt.

> **Fout "Cannot convert value to type System.String"?** Je gebruikt PowerShell 7. Start het script opnieuw met `powershell.exe -File ...` zoals hierboven.

---

## Stap 5 — Dashboard installeren (server)

Het dashboard installeert zichzelf als een Windows-service die automatisch opstart.

Vervang `SERVERNAAM` door de werkelijke naam van de server:

```powershell
.\scripts\Install-DashboardService.ps1 -SharePath "\\SERVERNAAM\AppDeployment" -StartNow
```

Als het goed gaat zie je:
```
Configuratie geschreven: C:\ProgramData\AppDeployment\server.config.json
Scheduled task geregistreerd: 'WinAppDeploy Dashboard'
Dashboard gestart (status: Running)

  Installatie voltooid
  URL: http://localhost:8080/
```

### Dashboard controleren

Open een browser op de server en ga naar:
```
http://localhost:8080
```

Je ziet het dashboard met vier tabbladen: **Clients**, **Pakketten**, **Logs** en **Instellingen**.

### Dashboard opnieuw starten of stoppen

```powershell
# Stoppen
Stop-ScheduledTask  -TaskName "WinAppDeploy Dashboard"

# Starten
Start-ScheduledTask -TaskName "WinAppDeploy Dashboard"

# Status bekijken
Get-ScheduledTask   -TaskName "WinAppDeploy Dashboard" | Select-Object TaskName, State
```

---

## Stap 6 — Client installeren

Voer de volgende stappen uit **op elke clientcomputer** als administrator.

### 6a. Scripts beschikbaar maken

Zorg dat de scripts bereikbaar zijn op de client, bijvoorbeeld via de share:

```powershell
# Optie A: rechtstreeks uitvoeren vanaf de share
\\SERVERNAAM\AppDeployment\...

# Optie B: scripts kopiëren naar de client
Copy-Item "\\SERVERNAAM\AppDeployment\scripts" -Destination "C:\Temp\WinAppDeploy" -Recurse
cd "C:\Temp\WinAppDeploy"
```

### 6b. Agent installeren

```powershell
.\scripts\Install-AppDeploymentAgent.ps1 -SharePath "\\SERVERNAAM\AppDeployment" -RunNow
```

De installer:
- kopieert de agent naar `C:\ProgramData\AppDeployment\`
- schrijft de configuratie naar `C:\ProgramData\AppDeployment\client.config.json`
- registreert de scheduled task **WinAppDeploy Agent**
- voert direct een eerste deployment uit (`-RunNow`)

### 6c. Installatie controleren

```powershell
# Scheduled task controleren
Get-ScheduledTask -TaskName "WinAppDeploy Agent"

# Logbestand bekijken (datum van vandaag invullen)
Get-Content "C:\ProgramData\AppDeployment\Logs\agent-$(Get-Date -Format yyyyMMdd).log"
```

In het logbestand zie je per pakket of het geïnstalleerd, overgeslagen of mislukt is.

---

## Stap 7 — Pre-check uitvoeren

Gebruik het pre-check script om automatisch te controleren of alles correct is ingesteld.

### Op de server

```powershell
.\scripts\Pre-Check.ps1 -SharePath "D:\AppDeployment" -Role Server
```

### Op de client

```powershell
.\scripts\Pre-Check.ps1 -SharePath "\\SERVERNAAM\AppDeployment" -Role Client
```

### Beide rollen tegelijk (op de server)

```powershell
.\scripts\Pre-Check.ps1 -SharePath "D:\AppDeployment" -Role Beide
```

Elke controle toont:

| Label | Betekenis |
|---|---|
| `OK` (groen) | Controle geslaagd |
| `WARN` (geel) | Aandachtspunt, maar geen blokkade |
| `FOUT` (rood) | Probleem gevonden — volg de `>>` aanwijzing |

Aan het einde verschijnt een samenvatting. Zorg dat er **geen rode FOUTs** zijn voordat je verder gaat.

---

## Dashboard gebruiken

Na installatie kun je alles beheren via `http://localhost:8080` op de server.

| Tab | Wat kun je hier doen? |
|---|---|
| **Clients** | Zien welke clients online zijn, deployment-status bekijken, "Deploy nu" sturen |
| **Pakketten** | Pakketten aan/uitzetten, verplicht maken, manifest opslaan |
| **Logs** | Agentlogs bekijken (ververst elke 30 seconden) |
| **Instellingen** | Share pad, poort en log map aanpassen |

### Manifest opnieuw genereren via het dashboard

1. Ga naar het tabblad **Pakketten**
2. Klik op **Opnieuw genereren**
3. Vink **Nieuw uitschakelen** aan als je nieuwe pakketten eerst wilt controleren
4. Na het genereren verschijnt een venster met wat er nieuw of bijgewerkt is
5. Gebruik de toggle-switches om pakketten aan/uit te zetten
6. Klik op **Wijzigingen opslaan**

---

## Problemen oplossen

### "Access is denied" bij manifest genereren

**Oorzaak:** het script wordt uitgevoerd als lokaal account zonder toegang tot de share.  
**Oplossing:** voer het script uit op de server zelf met het lokale pad (`D:\AppDeployment`).

### "Cannot convert value to type System.String"

**Oorzaak:** het script wordt uitgevoerd in PowerShell 7 (`pwsh.exe`).  
**Oplossing:**
```powershell
powershell.exe -File .\scripts\New-AppDeploymentManifest.ps1 -SharePath "D:\AppDeployment"
```

### Client verschijnt niet in het dashboard

**Mogelijke oorzaken:**
- De agent heeft nog niet gedraaid — wacht op de volgende geplande taakrun of gebruik `-RunNow`
- De client heeft geen schrijftoegang op `\\SERVER\AppDeployment\status` — controleer de ACL
- De agent heeft een fout — bekijk het logbestand op de client:
  ```powershell
  Get-Content "C:\ProgramData\AppDeployment\Logs\agent-$(Get-Date -Format yyyyMMdd).log"
  ```

### "Deploy nu" werkt niet direct

**Oorzaak:** WinRM/PSRemoting is niet ingeschakeld op de client.  
**Gevolg:** de deployment wordt uitgevoerd bij de volgende geplande taakrun (niet direct).  
**Oplossing (eenmalig op de client):**
```powershell
Enable-PSRemoting -Force
```

### Dashboard reageert niet op http://localhost:8080

**Controleer:**
```powershell
Get-ScheduledTask -TaskName "WinAppDeploy Dashboard" | Select-Object TaskName, State
```

Als de status niet `Running` is:
```powershell
Start-ScheduledTask -TaskName "WinAppDeploy Dashboard"
```

Als de task niet bestaat:
```powershell
.\scripts\Install-DashboardService.ps1 -SharePath "\\SERVERNAAM\AppDeployment" -StartNow
```

### Scheduled task "WinAppDeploy Agent" bestaat niet

```powershell
.\scripts\Install-AppDeploymentAgent.ps1 -SharePath "\\SERVERNAAM\AppDeployment"
```

---

## Overzicht bestanden na installatie

**Server:**
```
D:\AppDeployment\
  apps.json                        Pakketmanifest
  status\<ComputerNaam>.json       Statusbestand per client
  triggers\<ComputerNaam>.trigger  Tijdelijk deploy-signaal
  Chrome.msi, 7-Zip.msi, ...      MSI-bestanden

C:\ProgramData\AppDeployment\
  server.config.json               Dashboardconfiguratie
  Logs\agent-yyyyMMdd.log          Serveragentlogs
```

**Client:**
```
C:\ProgramData\AppDeployment\
  AppDeploymentAgent.ps1           Agent script
  client.config.json               Clientconfiguratie
  Cache\                           Lokale MSI-cache
  Logs\agent-yyyyMMdd.log          Agentlogs
  Logs\msi-<id>-datum.log          MSI-installatielogs per pakket
```
