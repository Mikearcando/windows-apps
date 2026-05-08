# WinAppDeploy

WinAppDeploy is een lichte Windows app deployment basis voor MSI-installaties vanaf een netwerkshare.

De server beheert een share met MSI-bestanden en een JSON-manifest. De client draait een PowerShell-agent als geplande taak, leest het manifest, controleert wat al geïnstalleerd is en installeert ontbrekende of nieuwere MSI-pakketten stil met `msiexec`. Een webdashboard op de server geeft realtime inzicht in de status van alle clients en laat je pakketten, manifest en instellingen volledig beheren.

## Structuur

```text
config/
  client.example.json           Voorbeeld clientconfiguratie
  server.example.json           Voorbeeld serverconfiguratie (dashboard)
  manifest.example.json         Voorbeeld applicatiemanifest
scripts/
  New-AppDeploymentManifest.ps1     Scant de share op MSI's en genereert apps.json
  AppDeploymentAgent.ps1            Deployment agent (draait op clients als scheduled task)
  Install-AppDeploymentAgent.ps1    Installeert de agent op een client
  Uninstall-AppDeploymentAgent.ps1  Verwijdert de agent van een client
  Start-DeploymentDashboard.ps1     Webdashboard (handmatig starten of via service)
  Install-DashboardService.ps1      Installeert het dashboard als autostart Windows service
  Uninstall-DashboardService.ps1    Verwijdert de dashboardservice
```

---

## Server Inrichten

### 1. Share aanmaken

Voer uit op de server als administrator:

```powershell
New-Item -ItemType Directory -Path "D:\AppDeployment" -Force
New-SmbShare -Name "AppDeployment" -Path "D:\AppDeployment" -ReadAccess "Domain Computers"
```

### 2. Submappen aanmaken voor clientstatus en triggers

Clients hebben schrijftoegang nodig op `status\` (voor statusbestanden) en `triggers\` (voor deploy-signalen):

```powershell
New-Item -ItemType Directory -Path "D:\AppDeployment\status"
New-Item -ItemType Directory -Path "D:\AppDeployment\triggers"

$acl  = Get-Acl "D:\AppDeployment\status"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "Domain Computers","Modify","ContainerInherit,ObjectInherit","None","Allow")
$acl.AddAccessRule($rule)
Set-Acl "D:\AppDeployment\status"   $acl
Set-Acl "D:\AppDeployment\triggers" $acl
```

### 3. MSI-bestanden plaatsen en manifest genereren

Plaats de MSI-bestanden in `D:\AppDeployment` en genereer het manifest **op de server zelf**:

```powershell
.\scripts\New-AppDeploymentManifest.ps1 -SharePath "D:\AppDeployment"
```

Dit maakt `D:\AppDeployment\apps.json`. Bestaande waarden zoals `enabled`, `required` en `arguments` blijven behouden bij elke volgende run.

> **Let op — PowerShell-versie:** het manifest genereren maakt gebruik van Windows Installer COM en vereist **PowerShell 5.1** (`powershell.exe`). Gebruik niet `pwsh.exe` (PowerShell 7) voor dit script.

> **Let op — rechten:** voer het script uit op de server zelf, of als domeinaccount met leesrecht op de share. Een lokaal administrator-account van een andere machine heeft geen toegang.

---

## Dashboard Installeren (Windows Server)

Het dashboard is een webapplicatie die draait als Windows scheduled task (autostart). Voer éénmalig uit als administrator:

```powershell
.\scripts\Install-DashboardService.ps1 -SharePath "\\SERVER\AppDeployment" -StartNow
```

Het dashboard:

- start automatisch bij het opstarten van Windows (als SYSTEM)
- is bereikbaar op `http://localhost:8080`
- slaat de configuratie op in `C:\ProgramData\AppDeployment\server.config.json`

### Handmatig starten (zonder service)

```powershell
.\scripts\Start-DeploymentDashboard.ps1 -SharePath "\\SERVER\AppDeployment"
```

### Service verwijderen

```powershell
.\scripts\Uninstall-DashboardService.ps1
```

---

## Dashboard

Het dashboard heeft vier tabbladen.

### Tab: Clients

Realtime overzicht van alle clients die de agent hebben gedraaid:

| Kolom | Omschrijving |
|---|---|
| Status | Groen = gezien binnen 90 minuten, grijs = offline |
| Computer | Computernaam |
| OS | Windows-versie |
| Gezien | Tijdstip van laatste agentrun |
| Deployment | Resultaat: Up-to-date / Geïnstalleerd / Deels / Mislukt / Reboot vereist |
| Pakketten | Aantal geïnstalleerd en mislukt |

Knoppen:

- **Deploy** — stuurt een deploy-signaal naar die client (zie [Deploy Nu](#deploy-nu))
- **🔍** — toont pakketdetails van de laatste run per pakket
- **Alle online deployen** — triggert alle clients met status Online tegelijk

### Tab: Pakketten

Overzicht van alle pakketten in `apps.json` met directe beheermogelijkheden:

| Actie | Omschrijving |
|---|---|
| Toggle **Ingeschakeld** | Pakket aan- of uitzetten (`enabled`) |
| Toggle **Verplicht** | Pakket verplicht of optioneel maken (`required`) |
| **Wijzigingen opslaan** | Schrijft de gewijzigde `apps.json` terug naar de share |
| **Opnieuw genereren** | Scant de share opnieuw op MSI-bestanden en werkt `apps.json` bij |

#### Manifest opnieuw genereren

Na het genereren verschijnt een resultaatvenster met:

- Totaal aantal pakketten, hoeveel er **nieuw** zijn en hoeveel **bijgewerkt**
- Lijst van alle pakketten met badge NIEUW of BIJGEWERKT
- De scriptuitvoer als bevestiging

Optie **Nieuw uitschakelen**: als dit is aangevinkt worden alle nieuw gevonden pakketten direct op `enabled: false` gezet. Handig als je eerst wilt controleren voordat iets uitgerold wordt.

### Tab: Logs

Laatste 200 regels uit de agentlogs op de server, automatisch ververst elke 30 seconden. Kleurcodering:

- Grijs = INFO
- Geel = WARN
- Rood = ERROR

### Tab: Instellingen

Formulier om `server.config.json` aan te passen:

| Veld | Omschrijving |
|---|---|
| Share pad | UNC-pad naar de AppDeployment share |
| Manifest bestand | Bestandsnaam van het manifest (standaard `apps.json`) |
| Log map | Pad naar de map met agentlogs |
| Poort | Poortnummer van het dashboard (herstart vereist bij wijziging) |

---

## Deploy Nu

De knop **Deploy** op de Clients-tab werkt in twee stappen:

1. Maakt `\\SERVER\AppDeployment\triggers\<ComputerNaam>.trigger` aan
2. Probeert de agent **direct** uit te voeren via WinRM/PSRemoting

Als WinRM niet beschikbaar is, blijft het trigger-bestand staan en voert de agent de deployment uit bij de eerstvolgende geplande taakrun.

WinRM inschakelen op clients (eenmalig, als administrator):

```powershell
Enable-PSRemoting -Force
```

---

## Client Installeren

Voer uit op de client als administrator:

```powershell
.\scripts\Install-AppDeploymentAgent.ps1 -SharePath "\\SERVER\AppDeployment" -RunNow
```

De installer:

- kopieert de agent naar `C:\ProgramData\AppDeployment`
- schrijft `C:\ProgramData\AppDeployment\client.config.json`
- registreert de scheduled task `WinAppDeploy Agent`
- draait optioneel direct een eerste deployment (`-RunNow`)

---

## Werking Agent

De agent installeert alleen pakketten die `enabled: true` **en** `required: true` hebben.

Bij elke run:

1. Controleert op een trigger-bestand in `triggers\<ComputerNaam>.trigger` — als aanwezig wordt dit verwijderd en gelogd
2. Laadt `apps.json` van de share
3. Controleert per pakket via het uninstall-register (eerst op `productCode`, dan op `name`)
4. Installeert ontbrekende of verouderde pakketten stil via `msiexec`
5. Schrijft `status\<ComputerNaam>.json` naar de share met het resultaat

Het statusbestand bevat:

```json
{
  "computerName": "PC001",
  "lastSeenUtc": "2026-05-08T10:30:00Z",
  "deploymentResult": "installed",
  "packagesInstalled": 2,
  "packagesFailed": 0,
  "rebootRequired": false,
  "triggeredDeploy": false,
  "packages": [ ... ],
  "osCaption": "Microsoft Windows 11 Pro"
}
```

Mogelijke waarden voor `deploymentResult`:

| Waarde | Betekenis |
|---|---|
| `upToDate` | Alles al geïnstalleerd, niets te doen |
| `installed` | Één of meer pakketten geïnstalleerd |
| `partial` | Sommige geïnstalleerd, sommige mislukt |
| `failed` | Alles mislukt |

Standaard MSI-installargumenten:

```text
/qn /norestart
```

Succesvolle exit codes: `0`, `3010`, `1641` — de laatste twee geven aan dat een reboot nodig kan zijn (zichtbaar als badge in het dashboard).

---

## Logs

Agentlogs op de client:

```text
C:\ProgramData\AppDeployment\Logs\agent-yyyyMMdd.log
```

MSI-installatielogs per pakket:

```text
C:\ProgramData\AppDeployment\Logs\msi-<app-id>-yyyyMMdd-HHmmss.log
```

---

## Sharetoegang

| Account | Pad | Rechten |
|---|---|---|
| Domain Computers | `\\SERVER\AppDeployment` | Lezen |
| Domain Computers | `\\SERVER\AppDeployment\status` | Schrijven |
| Domain Computers | `\\SERVER\AppDeployment\triggers` | Schrijven |
| Beheerdersaccount | `\\SERVER\AppDeployment` | Volledig beheer |

> Als de agent als SYSTEM draait: vervang "Domain Computers" door het computeraccount of een domeingroep met computeraccounts.

---

## Vereisten

| Component | Vereiste |
|---|---|
| Server (dashboard) | Windows, PowerShell 5.1+ |
| Server (manifest genereren) | PowerShell **5.1** (`powershell.exe`), Windows Installer aanwezig |
| Clients (agent) | Windows, PowerShell 5.1+, leestoegang op de share |
| Clients (Deploy Nu) | WinRM/PSRemoting ingeschakeld (`Enable-PSRemoting -Force`) |
| MSI-bestanden | Moeten stille installatie ondersteunen (`/qn`) |
| Netwerk | Clients bereiken de server via UNC-pad, niet via gemapte schijf |
