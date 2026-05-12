# WinAppDeploy — Stap-voor-stap handleiding

> **Leestijd:** ~20 minuten  
> **Niveau:** Beginnend systeembeheerder  
> **Alle commando's worden uitgevoerd als Administrator**

---

## Wat gaan we installeren?

```
┌──────────────────────────────────────────────────────────────────┐
│  SERVER (één keer doen)                                          │
│  ─────────────────────                                           │
│  • Gedeelde map (share) met MSI-bestanden                        │
│  • Pakketmanifest  apps.json  — lijst van wat geïnstalleerd moet │
│  • Webdashboard op  http://localhost:8080                        │
└────────────────────────┬─────────────────────────────────────────┘
                         │  \\SERVER\AppDeployment
┌────────────────────────▼─────────────────────────────────────────┐
│  CLIENT (herhalen per computer)                                  │
│  ────────────────────────────                                    │
│  • Agent als geplande taak (draait elk uur)                      │
│  • Installeert automatisch pakketten uit apps.json               │
└──────────────────────────────────────────────────────────────────┘
```

**Vereisten:**

| Wat | Vereiste |
|---|---|
| Server | Windows 10/11 Pro of Windows Server 2016+ |
| Clients | Windows 10 of nieuwer |
| PowerShell | 5.1 — standaard aanwezig, open via `powershell.exe` |
| Netwerk | Clients bereiken de server via computernaam of IP |
| MSI-bestanden | Moeten stille installatie ondersteunen (`/qn`) |

> **Belangrijk — gebruik altijd `powershell.exe`, niet `pwsh.exe`.**  
> PowerShell 7 (`pwsh`) werkt niet correct met de manifest-generator.

---

## Optie A — Automatische setup (aanbevolen)

Eén script regelt alles: mappen, share, rechten, manifest en dashboard.

### Op de server

1. Open **PowerShell als administrator**  
   *(rechtermuisknop op het Startmenu → Windows PowerShell (beheerder))*

2. Ga naar de projectmap:
   ```powershell
   cd "C:\pad\naar\WinAppDeploy"
   ```

3. Voer het setup-script uit:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\scripts\Setup.ps1
   ```

4. Het script stelt vragen. Kies **[1] Server**:
   ```
   Wat wil je doen?

   [1]  Server  — share, rechten, manifest en dashboard installeren
   [2]  Client  — deployment agent installeren op deze computer

   > Keuze [1/2] :
   ```

5. Beantwoord de vragen (druk op Enter voor de standaardwaarden):
   ```
   > Lokaal pad voor de share [D:\AppDeployment] :      ← Enter
   > SMB share-naam [AppDeployment] :                   ← Enter
   > Account voor schrijftoegang [Domain Computers] :   ← Enter
   > Dashboard poort [8080] :                           ← Enter
   ```

6. Bevestig de samenvatting:
   ```
   > Starten met installatie? [J/n] :   J
   ```

7. Als het goed gaat zie je groene `[OK]` regels:
   ```
   [OK]  Map aangemaakt: D:\AppDeployment
   [OK]  SMB share 'AppDeployment' aangemaakt
   [OK]  Schrijftoegang voor 'Domain Computers' op status + triggers
   [??]  Geen MSI-bestanden gevonden — manifest overgeslagen
   [OK]  Dashboard service geregistreerd als scheduled task
   ```
   > De `[??]` over het manifest is normaal als je nog geen MSI-bestanden hebt geplaatst.

8. Controleer het dashboard — open een browser op de server:
   ```
   http://localhost:8080
   ```
   Je ziet het WinAppDeploy dashboard met een Setup-tab.

### Op elke client

1. Open **PowerShell als administrator** op de clientcomputer

2. Ga naar de projectmap (of kopieer de scripts naar de client):
   ```powershell
   cd "C:\pad\naar\WinAppDeploy"
   ```

3. Voer het setup-script uit:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\scripts\Setup.ps1
   ```

4. Kies **[2] Client**

5. Vul het UNC-pad in (vervang `SERVERNAAM` door de echte naam):
   ```
   > UNC-pad naar de server share : \\SERVERNAAM\AppDeployment
   ```

6. Bevestig en wacht tot de installatie klaar is

7. Klaar — de client verschijnt binnen een paar minuten in het dashboard

---

## Optie B — Handmatige installatie

Gebruik deze methode als je meer controle wilt of als Setup.ps1 problemen geeft.

---

### Stap 1 — Scripts uitpakken

1. Pak de projectmap uit naar de server, bijvoorbeeld naar:
   ```
   C:\WinAppDeploy\
   ```

2. Controleer of de map `scripts\` aanwezig is met alle bestanden:
   ```powershell
   Get-ChildItem "C:\WinAppDeploy\scripts\"
   ```
   Je moet deze bestanden zien:
   ```
   AppDeploymentAgent.ps1
   Install-AppDeploymentAgent.ps1
   Install-DashboardService.ps1
   New-AppDeploymentManifest.ps1
   Pre-Check.ps1
   Setup.ps1
   Start-DeploymentDashboard.ps1
   Uninstall-AppDeploymentAgent.ps1
   Uninstall-DashboardService.ps1
   ```

3. Sta PowerShell-scripts toe (eenmalig per computer):
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
   ```
   Bevestig met `J` of `Y`.

---

### Stap 2 — Share aanmaken op de server

Open PowerShell als administrator op de server en voer alles hieronder uit.

#### 2a — Map aanmaken

```powershell
New-Item -ItemType Directory -Path "D:\AppDeployment" -Force
New-Item -ItemType Directory -Path "D:\AppDeployment\status"
New-Item -ItemType Directory -Path "D:\AppDeployment\triggers"
```

> Geen D:-schijf? Gebruik dan `C:\AppDeployment` en pas alle verdere paden aan.

#### 2b — SMB-share aanmaken

```powershell
New-SmbShare -Name "AppDeployment" -Path "D:\AppDeployment" -ReadAccess "Domain Computers"
```

Controleer of de share werkt:
```powershell
Get-SmbShare -Name "AppDeployment"
```

Je zou het volgende moeten zien:
```
Name            ScopeName Path              Description
----            --------- ----              -----------
AppDeployment   *         D:\AppDeployment
```

#### 2c — Schrijftoegang geven aan clients

Clients moeten hun statusbestanden en triggers kunnen wegschrijven:

```powershell
$acl  = Get-Acl "D:\AppDeployment\status"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "Domain Computers", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($rule)
Set-Acl "D:\AppDeployment\status"   $acl
Set-Acl "D:\AppDeployment\triggers" $acl
```

> **Geen domein?** Vervang `"Domain Computers"` door `"Everyone"` of de naam van een lokale groep.

---

### Stap 3 — MSI-bestanden plaatsen

Kopieer de MSI-installatiebestanden naar `D:\AppDeployment`:

```
D:\AppDeployment\
  Chrome.msi
  VLC.msi
  7-Zip.msi
```

Submappen mogen ook — het manifest-script zoekt recursief.

---

### Stap 4 — Manifest genereren

> **Gebruik `powershell.exe`, niet `pwsh.exe`!**

```powershell
cd "C:\WinAppDeploy"
powershell.exe -File .\scripts\New-AppDeploymentManifest.ps1 -SharePath "D:\AppDeployment"
```

Als het goed gaat:
```
Manifest geschreven: D:\AppDeployment\apps.json (3 package(s))
```

Controleer het manifest:
```powershell
Get-Content "D:\AppDeployment\apps.json" | ConvertFrom-Json | Select-Object -ExpandProperty packages | Format-Table id, name, version, enabled, required
```

Uitvoer:
```
id        name       version  enabled required
--        ----       -------  ------- --------
chrome    Chrome     124.0    True    True
vlc       VLC        3.0.21   True    True
7-zip     7-Zip      24.01    True    True
```

---

### Stap 5 — Dashboard installeren

Vervang `SERVERNAAM` door de werkelijke computernaam van de server:

```powershell
cd "C:\WinAppDeploy"
.\scripts\Install-DashboardService.ps1 -SharePath "\\SERVERNAAM\AppDeployment" -StartNow
```

Als het goed gaat:
```
Configuratie geschreven: C:\ProgramData\AppDeployment\server.config.json
Scheduled task geregistreerd: 'WinAppDeploy Dashboard'
Dashboard gestart (status: Running)

  Installatie voltooid
  ====================
  Task     : WinAppDeploy Dashboard
  Config   : C:\ProgramData\AppDeployment\server.config.json
  Dashboard: http://localhost:8080/

  Het dashboard start automatisch bij het opstarten van Windows.
```

Open een browser op de server:
```
http://localhost:8080
```

Je ziet dit:

```
┌─────────────────────────────────────────────────────────────────┐
│  ⚙ WinAppDeploy  ● LIVE                                         │
├───────────────────────────────────────────────────────────────  │
│  ⚙ Setup  💻 Clients  📦 Pakketten  📄 Logs  ⚙ Instellingen    │
├─────────────────────────────────────────────────────────────────│
│  ✅ Servercontrole          │  💻 Client installeren            │
│  ✓ Share map bestaat        │  .\scripts\Install-...Agent.ps1   │
│  ✓ SMB share geconfigureerd │  -SharePath "\\SERVER\..."        │
│  ✓ Schrijftoegang clients   │                                   │
│  ✓ Manifest apps.json       │                                   │
│  ✓ Dashboard service actief │                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

### Stap 6 — Agent installeren op client

Voer deze stappen uit **op elke clientcomputer** als administrator.

#### 6a — Scripts beschikbaar maken

**Optie 1:** Scripts kopiëren vanuit de share (makkelijkst):
```powershell
Copy-Item "\\SERVERNAAM\AppDeployment" -Destination "C:\Temp\WinAppDeploy" -Recurse
cd "C:\Temp\WinAppDeploy"
```

**Optie 2:** USB-stick of netwerkkopie van de projectmap.

#### 6b — Agent installeren

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Install-AppDeploymentAgent.ps1 -SharePath "\\SERVERNAAM\AppDeployment" -RunNow
```

Als het goed gaat:
```
Agent geinstalleerd in: C:\ProgramData\AppDeployment
Config geschreven: C:\ProgramData\AppDeployment\client.config.json
Scheduled task geregistreerd: WinAppDeploy Agent
Scheduled task gestart.
```

#### 6c — Installatie controleren

```powershell
# Task zichtbaar?
Get-ScheduledTask -TaskName "WinAppDeploy Agent"

# Logbestand bekijken
Get-Content "C:\ProgramData\AppDeployment\Logs\agent-$(Get-Date -Format yyyyMMdd).log"
```

Een succesvolle eerste run ziet er zo uit:
```
2026-05-12 10:30:01 [INFO] Deployment gestart. Config=... Manifest=... Triggered=False
2026-05-12 10:30:02 [INFO] Overslaan: Chrome al op versie 124.0
2026-05-12 10:30:03 [INFO] Start installatie: vlc
2026-05-12 10:30:45 [INFO] Installatie gelukt. Package=vlc ExitCode=0 ...
2026-05-12 10:30:45 [INFO] Deployment afgerond. Geinstalleerd=1 Overgeslagen=1 Mislukt=0
2026-05-12 10:30:45 [INFO] Status geschreven: \\SERVERNAAM\AppDeployment\status\PC001.json
```

Daarna verschijnt de client in het dashboard onder **Clients**.

---

### Stap 7 — Pre-check uitvoeren (aanbevolen)

Het pre-check script controleert automatisch of alles goed staat.

**Op de server:**
```powershell
.\scripts\Pre-Check.ps1 -SharePath "D:\AppDeployment" -Role Server
```

**Op de client:**
```powershell
.\scripts\Pre-Check.ps1 -SharePath "\\SERVERNAAM\AppDeployment" -Role Client
```

Verwachte uitvoer (alles groen):
```
  ================================================
   WinAppDeploy — Pre-installatiecontrole
  ================================================
  Computer : PC001
  Datum    : 12-05-2026 10:30

  Server
  ──────
   OK   Windows Installer COM beschikbaar
   OK   Share map bestaat (D:\AppDeployment)
   OK   SMB share geconfigureerd
   OK   Submap 'status' bestaat
   OK   Submap 'triggers' bestaat
   OK   Submap 'status' schrijfbaar (huidig account)
   OK   Manifest apps.json aanwezig
   OK   Manifest apps.json is geldig

  ================================================
   Resultaat
  ================================================

   Geslaagd  : 8

   Alles in orde! WinAppDeploy is correct geconfigureerd.
```

> Rode `FOUT`-regels? Volg de `>>` aanwijzing eronder.

---

## Dashboard gebruiken

Open `http://localhost:8080` op de server.

### Tab: Setup

Overzicht van de serverconfiguratie met groene vinkjes. Toont ook het installatie-commando voor nieuwe clients. Knoppen om ontbrekende mappen en rechten aan te maken.

### Tab: Clients

| Kolom | Wat zie je |
|---|---|
| Groene stip | Client online (gezien binnen 90 minuten) |
| Grijze stip | Client offline |
| Deployment | Up-to-date / Geïnstalleerd / Deels / Mislukt |
| Deploy-knop | Stuurt direct een deploy-opdracht naar die client |

Knop **Alle online deployen** — triggert alle online clients tegelijk.

### Tab: Pakketten

Hier beheer je `apps.json`:

1. **Toggle Ingeschakeld** — zet een pakket aan of uit
2. **Toggle Verplicht** — als uit, installeert de agent dit pakket niet
3. **Installatie-argumenten** — pas MSI-argumenten aan per pakket
4. **Wijzigingen opslaan** — sla de wijzigingen op in `apps.json`
5. **Opnieuw genereren** — scan de share opnieuw op nieuwe MSI-bestanden

### Tab: Logs

Laatste 200 regels van de agentlogs. Kleurcodering:

- **Grijs** = INFO (normaal)
- **Geel** = WARN (aandacht nodig)
- **Rood** = ERROR (iets mislukt)

### Tab: Instellingen

Pas het share-pad, poort, logmap en manifest-bestandsnaam aan.

---

## Pakketten beheren

### Nieuw MSI-bestand toevoegen

1. Kopieer het MSI-bestand naar `D:\AppDeployment`
2. Ga in het dashboard naar **Pakketten**
3. Klik op **Opnieuw genereren**
4. Vink **Nieuw uitschakelen** aan als je het pakket eerst wilt controleren
5. Klik op **Wijzigingen opslaan**

### Pakket uitschakelen

1. Ga naar **Pakketten**
2. Zet de toggle **Ingeschakeld** uit bij het gewenste pakket
3. Klik op **Wijzigingen opslaan**

### Pakket niet verplicht maken

1. Ga naar **Pakketten**
2. Zet de toggle **Verplicht** uit
3. Klik op **Wijzigingen opslaan**
4. De agent slaat dit pakket over, ook als het niet geïnstalleerd is

---

## Problemen oplossen

### Fout: "Configbestand niet gevonden"

**Oorzaak:** de agent is niet correct geïnstalleerd.  
**Oplossing:** installeer de agent opnieuw:
```powershell
.\scripts\Install-AppDeploymentAgent.ps1 -SharePath "\\SERVERNAAM\AppDeployment" -RunNow
```

### Fout: "Manifest niet gevonden"

**Oorzaak:** `apps.json` bestaat nog niet op de share.  
**Oplossing:** genereer het manifest op de server:
```powershell
powershell.exe -File .\scripts\New-AppDeploymentManifest.ps1 -SharePath "D:\AppDeployment"
```

### Fout: "Access is denied" bij manifest genereren

**Oorzaak:** je gebruikt een UNC-pad (`\\SERVER\...`) in plaats van het lokale pad.  
**Oplossing:** gebruik het **lokale pad** op de server:
```powershell
powershell.exe -File .\scripts\New-AppDeploymentManifest.ps1 -SharePath "D:\AppDeployment"
```

### Fout: COM-fout of "Cannot convert value..."

**Oorzaak:** je gebruikt PowerShell 7 (`pwsh.exe`).  
**Oplossing:** gebruik altijd `powershell.exe`:
```powershell
powershell.exe -File .\scripts\New-AppDeploymentManifest.ps1 -SharePath "D:\AppDeployment"
```

### Client verschijnt niet in het dashboard

Controleer in volgorde:

1. **Heeft de agent gedraaid?**
   ```powershell
   Get-Content "C:\ProgramData\AppDeployment\Logs\agent-$(Get-Date -Format yyyyMMdd).log"
   ```

2. **Is de share bereikbaar?**
   ```powershell
   Test-Path "\\SERVERNAAM\AppDeployment"
   ```

3. **Heeft de client schrijftoegang op `\status`?**
   ```powershell
   Set-Content "\\SERVERNAAM\AppDeployment\status\test.tmp" "test"
   Remove-Item "\\SERVERNAAM\AppDeployment\status\test.tmp"
   ```
   Fout? → Controleer de ACL op de server (zie stap 2c).

4. **Pre-check uitvoeren op de client:**
   ```powershell
   .\scripts\Pre-Check.ps1 -SharePath "\\SERVERNAAM\AppDeployment" -Role Client
   ```

### "Deploy nu" werkt niet direct

**Oorzaak:** WinRM is niet ingeschakeld op de client.  
**Gevolg:** de deployment wordt uitgevoerd bij de volgende geplande taakrun.  
**Oplossing (eenmalig uitvoeren op de client als admin):**
```powershell
Enable-PSRemoting -Force
```

### Dashboard niet bereikbaar op poort 8080

Controleer de status van de service:
```powershell
Get-ScheduledTask -TaskName "WinAppDeploy Dashboard" | Select-Object TaskName, State
```

Niet `Running`? Start hem opnieuw:
```powershell
Start-ScheduledTask -TaskName "WinAppDeploy Dashboard"
```

Task bestaat niet? Installeer opnieuw:
```powershell
.\scripts\Install-DashboardService.ps1 -SharePath "\\SERVERNAAM\AppDeployment" -StartNow
```

### Scheduled task "WinAppDeploy Agent" bestaat niet

```powershell
.\scripts\Install-AppDeploymentAgent.ps1 -SharePath "\\SERVERNAAM\AppDeployment"
```

---

## Agent verwijderen

**Van een client:**
```powershell
.\scripts\Uninstall-AppDeploymentAgent.ps1
```

Logs bewaren bij verwijderen:
```powershell
.\scripts\Uninstall-AppDeploymentAgent.ps1 -KeepLogs
```

**Dashboard van de server:**
```powershell
.\scripts\Uninstall-DashboardService.ps1
```

---

## Bestandsoverzicht na installatie

**Server:**
```
D:\AppDeployment\
  apps.json                           Pakketmanifest (welke MSIs worden uitgerold)
  Chrome.msi, VLC.msi, ...           MSI-bestanden
  status\PC001.json                   Statusbestand per client
  triggers\PC001.trigger              Tijdelijk deploy-signaal (wordt verwijderd na uitvoer)

C:\ProgramData\AppDeployment\
  server.config.json                  Dashboardconfiguratie
  Logs\agent-20260512.log            Serveragentlogs (als ook de server een agent heeft)
```

**Client:**
```
C:\ProgramData\AppDeployment\
  AppDeploymentAgent.ps1              Agent script
  client.config.json                  Clientconfiguratie (SharePath, LogPath, etc.)
  Cache\chrome\Chrome.msi            Lokale MSI-cache (kopie van share)
  Logs\agent-20260512.log            Agentlogs
  Logs\msi-chrome-20260512-103000.log MSI-installatielog per pakket
```

---

## Samenvatting commando's

| Actie | Commando |
|---|---|
| Server instellen (auto) | `powershell.exe -ExecutionPolicy Bypass -File .\scripts\Setup.ps1` → kies 1 |
| Client installeren (auto) | `powershell.exe -ExecutionPolicy Bypass -File .\scripts\Setup.ps1` → kies 2 |
| Manifest genereren | `powershell.exe -File .\scripts\New-AppDeploymentManifest.ps1 -SharePath "D:\AppDeployment"` |
| Dashboard installeren | `.\scripts\Install-DashboardService.ps1 -SharePath "\\SERVER\AppDeployment" -StartNow` |
| Agent installeren | `.\scripts\Install-AppDeploymentAgent.ps1 -SharePath "\\SERVER\AppDeployment" -RunNow` |
| Pre-check server | `.\scripts\Pre-Check.ps1 -SharePath "D:\AppDeployment" -Role Server` |
| Pre-check client | `.\scripts\Pre-Check.ps1 -SharePath "\\SERVER\AppDeployment" -Role Client` |
| Dashboard starten | `Start-ScheduledTask -TaskName "WinAppDeploy Dashboard"` |
| Dashboard stoppen | `Stop-ScheduledTask  -TaskName "WinAppDeploy Dashboard"` |
| Agent verwijderen | `.\scripts\Uninstall-AppDeploymentAgent.ps1` |
| Dashboard verwijderen | `.\scripts\Uninstall-DashboardService.ps1` |
