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
.\deploy\Deploy-IisSite.ps1 -PackagePath .\LendingApi-1.0.42.zip -Version 1.0.42 -EnvironmentName prod `
    -ConnectionString 'Server=SQL01;Database=LendingDb;Integrated Security=true;TrustServerCertificate=true'
```

The script backs up and migrates the database before it switches the site. It fails, and
rolls the code back by itself, if the new release does not answer on `/health` with the
expected version within about a minute.

## Roll back to an earlier release

List the releases that are still on the server, then re-activate one. Leave out
`-PackagePath` and `-ConnectionString`.

```powershell
Get-ChildItem C:\inetpub\sites\LendingApi\releases

.\deploy\Deploy-IisSite.ps1 -Version 1.0.41 -EnvironmentName prod
```

The five newest releases are kept. For anything older, download the package from the
pipeline run that built it and deploy it as a normal release.

A rollback only changes the code. The database stays at its current schema version, which
is safe because every migration is backward compatible with the previous release.

## Database

Schema history, newest first:

```sql
SELECT Version, ScriptName, AppliedAt, AppliedBy FROM dbo.SchemaVersions ORDER BY Version DESC;
```

Apply the migrations without deploying the app:

```powershell
.\deploy\Invoke-DbMigrations.ps1 -ConnectionString $connectionString -AppLogin 'IIS APPPOOL\LendingApi'
```

A backup is taken before an existing database is changed. Its file name is printed by the
deployment, for example `LendingDb-before-0004-20261002-133551.bak`, and it is written to
the SQL Server instance's default backup folder.

Restore that backup only as a last resort, when a migration damaged data. It loses every
change made after the backup was taken, so agree it with the business owner first:

```sql
ALTER DATABASE LendingDb SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE LendingDb FROM DISK = N'<backup file>' WITH REPLACE;
ALTER DATABASE LendingDb SET MULTI_USER;
```

Then roll the app back to the release that matches the restored schema.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| HTTP 500.19 | IIS cannot read `web.config`, or the ASP.NET Core Module is missing | Run `.\deploy\Install-Prerequisites.ps1` |
| HTTP 500.30 or 500.31 | The app failed to start, or the .NET runtime version is missing | Check the Application event log (below). Run `.\deploy\Install-Prerequisites.ps1` |
| `/health` returns 503 `Unhealthy` | The app runs but cannot read the database | Check the SQL Server service, the connection string in the release's `web.config`, and that `IIS APPPOOL\LendingApi` is a user in the database |
| HTTP 503 from IIS | The app pool is stopped, often after repeated crashes | `Start-WebAppPool LendingApi`, then check the event log for the crash |
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
