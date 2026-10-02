# Runbook: Lending API on IIS

All commands run on the IIS server in an elevated Windows PowerShell prompt.

| Item | Value |
|---|---|
| IIS site and app pool | `LendingApi` |
| Port | 8085 |
| Site folder | `C:\inetpub\sites\LendingApi` |
| Releases | `C:\inetpub\sites\LendingApi\releases\<version>` |
| Deployment history | `C:\inetpub\sites\LendingApi\deployments.log` |
| Health check | `http://localhost:8085/health` returns `Healthy` |
| Running version | `http://localhost:8085/version` |

## Check the current state

```powershell
Invoke-RestMethod http://localhost:8085/version
Get-Content C:\inetpub\sites\LendingApi\deployments.log -Tail 10

Import-Module WebAdministration
Get-WebsiteState -Name LendingApi
Get-WebAppPoolState -Name LendingApi
(Get-Website | Where-Object Name -eq LendingApi).physicalPath
```

## Deploy a release by hand

Normally the pipeline does this. To do it by hand, download the `release` artifact from the
pipeline run and unzip it on the server.

```powershell
.\deploy\Deploy-IisSite.ps1 -PackagePath .\LendingApi-1.0.42.zip -Version 1.0.42 -Environment Production
```

The script fails, and rolls back by itself, if the new release does not answer on `/health`
with the expected version within about a minute.

## Roll back to an earlier release

List the releases that are still on the server, then re-activate one. Leave out `-PackagePath`.

```powershell
Get-ChildItem C:\inetpub\sites\LendingApi\releases

.\deploy\Deploy-IisSite.ps1 -Version 1.0.41 -Environment Production
```

The five newest releases are kept. For anything older, download the package from the
pipeline run that built it and deploy it as a normal release.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| HTTP 500.19 | IIS cannot read `web.config`, or the ASP.NET Core Module is missing | Run `.\deploy\Install-Prerequisites.ps1` |
| HTTP 500.30 or 500.31 | The app failed to start, or the .NET runtime version is missing | Check the Application event log (below). Run `.\deploy\Install-Prerequisites.ps1` |
| HTTP 503 | The app pool is stopped, often after repeated crashes | `Start-WebAppPool LendingApi`, then check the event log for the crash |
| HTTP 403.14 or 404 on every URL | The site points at an empty or wrong folder | Check `physicalPath` (above) and re-run the deployment |
| Deployment fails with "access denied" | The prompt is not elevated | Start Windows PowerShell as administrator |
| Port 8085 does not answer | Site stopped, or another process uses the port | `Get-WebsiteState LendingApi` and `netstat -ano \| findstr :8085` |

Recent errors from IIS and .NET:

```powershell
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2, 3 } -MaxEvents 20 |
    Format-List TimeCreated, ProviderName, Message
```

To see the app's own start-up output, set `stdoutLogEnabled="true"` in the release's
`web.config`, create a `logs` folder next to it that the app pool identity can write to,
reproduce the problem, and read the file in `logs`. Turn it off again afterwards, because
the file grows without limit.

## After an incident

1. Restore service first. Roll back, do not debug in production.
2. Note the time, the version, the symptom and what restored service.
3. Find the root cause from the event log and the pipeline run for that version.
4. Fix it in code or in the scripts and add a check that would have caught it, such as a
   test or an extra step in the deployment verification.
