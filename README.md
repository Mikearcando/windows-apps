# WinAppDeploy

WinAppDeploy is een lichte Windows app deployment basis voor MSI-installaties vanaf een netwerkshare.

De server beheert een share met MSI-bestanden en een JSON-manifest. De client draait een PowerShell-agent als geplande taak, leest het manifest, controleert wat al geïnstalleerd is en installeert ontbrekende of nieuwere MSI-pakketten stil met `msiexec`. Een webdashboard op de server geeft realtime inzicht in de status van alle clients en laat je pakketten en instellingen beheren.

## Structuur

```text
config/
  client.example.json           Voorbeeld clientconfiguratie
  server.example.json           Voorbeeld serverconfiguratie (dashboard)
  manifest.example.json         Voorbeeld applicatiemanifest
scripts/
  New-AppDeploymentManifest.ps1     Genereert apps.json op basis van MSI-bestanden
  AppDeploymentAgent.ps1            Deployment agent (draait op clients)
  Install-AppDeploymentAgent.ps1    Installeert de agent als scheduled task op clients
  Uninstall-AppDeploymentAgent.ps1  Verwijdert de agent van clients
  Start-DeploymentDashboard.ps1     Webdashboard (handmatig starten)
  Install-DashboardService.ps1      Installeert dashboard als Windows service (autostart)
  Uninstall-DashboardService.ps1    Verwijdert de dashboardservice
```

## Server Inrichten

### 1. Share aanmaken

```powershell
New-Item -ItemType Directory -Path "D:\AppDeployment" -Force
New-SmbShare -Name "AppDeployment" -Path "D:\AppDeployment" -ReadAccess "Domain Computers"
```

### 2. Submappen aanmaken voor clientstatus en triggers

De agent heeft schrijftoegang nodig tot de `status\` en `triggers\` submappen:

```powershell
New-Item -ItemType Directory -Path "D:\AppDeployment\status"
New-Item -ItemType Directory -Path "D:\AppDeployment\triggers"

# Schrijftoegang voor Domain Computers op de twee submappen
$acl = Get-Acl "D:\AppDeployment\status"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("Domain Computers","Modify","ContainerInherit,ObjectInherit","None","Allow")
$acl.AddAccessRule($rule)
Set-Acl "D:\AppDeployment\status" $acl
Set-Acl "D:\AppDeployment\triggers" $acl
```

### 3. MSI-bestanden plaatsen en manifest genereren

```powershell
.\scripts\New-AppDeploymentManifest.ps1 -SharePath "\\SERVER\AppDeployment"
```

Dit maakt `\\SERVER\AppDeployment\apps.json`. Bestaande waarden zoals `enabled`, `required` en `arguments` blijven behouden.

## Dashboard Installeren (Windows Server)

Voer éénmalig uit als administrator op de server:

```powershell
.\scripts\Install-DashboardService.ps1 -SharePath "\\SERVER\AppDeployment" -StartNow
```

Het dashboard:

- start automatisch bij het opstarten van Windows (als SYSTEM)
- is bereikbaar op `http://localhost:8080`
- beheert `C:\ProgramData\AppDeployment\server.config.json`

### Dashboard handmatig starten (zonder service)

```powershell
.\scripts\Start-DeploymentDashboard.ps1 -SharePath "\\SERVER\AppDeployment"
```

### Service verwijderen

```powershell
.\scripts\Uninstall-DashboardService.ps1
```

## Dashboard Functies

Het dashboard heeft vier tabbladen:

| Tab | Functie |
|---|---|
| **Clients** | Realtime overzicht van alle clients: online/offline, laatste deployment, pakketstatus. Knop "Deploy" per client of voor alle online clients tegelijk. |
| **Pakketten** | Toggle-switches om pakketten in/uit te schakelen of verplicht te maken. Manifest direct opslaan of opnieuw genereren. |
| **Logs** | Laatste 200 regels uit de agentlogs, ververst elke 30 seconden. |
| **Instellingen** | Share pad, poort en logmap aanpassen en opslaan in `server.config.json`. |

### Deploy Nu

De knop **Deploy** op de Clients-tab:

1. Maakt een trigger-bestand aan op `\\SERVER\AppDeployment\triggers\<ComputerNaam>.trigger`
2. Probeert vervolgens de agent **direct** uit te voeren via WinRM/PSRemoting
3. Als WinRM niet beschikbaar is, voert de agent het uit bij de volgende geplande taakrun

## Client Installeren

Voer op de client als administrator uit:

```powershell
.\scripts\Install-AppDeploymentAgent.ps1 -SharePath "\\SERVER\AppDeployment" -RunNow
```

De installer:

- kopieert de agent naar `C:\ProgramData\AppDeployment`
- schrijft `C:\ProgramData\AppDeployment\client.config.json`
- registreert de scheduled task `WinAppDeploy Agent`
- draait optioneel direct een eerste deployment

## Werking

De agent installeert alleen packages die `enabled: true` **en** `required: true` hebben. Na elke run schrijft de agent een statusbestand naar `\\SERVER\AppDeployment\status\<ComputerNaam>.json` met:

- tijdstip van laatste run
- deploymentresultaat per pakket
- OS-versie
- of de run via een trigger werd gestart

Detectie van geïnstalleerde pakketten: eerst via `productCode` in het uninstall-register, daarna via `name` als fallback.

Standaard installargumenten:

```text
/qn /norestart
```

Succesvolle MSI exit codes:

```text
0, 3010, 1641
```

`3010` en `1641` betekenen dat een reboot nodig kan zijn (zichtbaar in het dashboard).

## Logs

Agentlogs op de client:

```text
C:\ProgramData\AppDeployment\Logs\agent-yyyyMMdd.log
```

MSI-installatielogs:

```text
C:\ProgramData\AppDeployment\Logs\msi-<app-id>-yyyyMMdd-HHmmss.log
```

## Sharetoegang

| Account | Pad | Rechten |
|---|---|---|
| Domain Computers | `\\SERVER\AppDeployment` | Lezen |
| Domain Computers | `\\SERVER\AppDeployment\status` | Schrijven |
| Domain Computers | `\\SERVER\AppDeployment\triggers` | Schrijven |
| Beheerdersaccount | `\\SERVER\AppDeployment` | Volledig beheer |

> Tip: als de agent als SYSTEM draait, vervang dan "Domain Computers" door het computeraccount of een domeingroep met computeraccounts.

## Vereisten

- Clients moeten de share kunnen bereiken via UNC-pad (`\\SERVER\AppDeployment`)
- MSI's moeten stille installatie ondersteunen
- Dashboard vereist PowerShell 5.1+ op de server
- "Deploy Nu" via WinRM vereist dat PSRemoting is ingeschakeld op de clients:
  `Enable-PSRemoting -Force`
