# Lending API: CI/CD to IIS and SQL Server

A small .NET 10 API with a GitHub Actions pipeline that builds it, tests it, packages it
and promotes the same package through DEV, UAT, PREPROD and PROD. Each deployment runs
on Windows with PowerShell: it migrates the SQL Server database, deploys to IIS, verifies
itself, and rolls back automatically when the new release is not healthy.

The API is deliberately simple. The point of the repository is the release process around it.

## What the pipeline does

```
push to main
   |
   v
build ------> deploy-dev ------> deploy-uat ------> deploy-preprod ------> deploy-prod
restore       install IIS        same steps         same steps             same steps,
package       back up and        as dev             as dev                 behind a manual
  check       migrate the                                                  approval
build         database
test          deploy to IIS
test the      verify version
  migrations  read and write
publish         through IIS
zip           prove the rollback
```

| Stage | What happens |
|---|---|
| **build** | Restores, fails on NuGet packages with known vulnerabilities, builds with version `1.0.<run number>`, runs the API tests and the database migration tests, and zips the published output. The zip, the deployment scripts and the migration scripts are uploaded together as one release package. |
| **deploy-dev** | Installs IIS and the ASP.NET Core Hosting Bundle, migrates the database, deploys the package and checks that the right version answers through IIS. It then creates a loan through the API to prove the app can read and write the database, and deploys a deliberately broken package to prove that the rollback works. |
| **deploy-uat, deploy-preprod, deploy-prod** | The same job with a different environment name. An environment only starts when the one before it succeeded. |

All four deployments use one reusable workflow, [deploy.yml](.github/workflows/deploy.yml),
so there is no separate, untested path for production.

Pull requests are built and tested but not deployed.

## Build once, configure per environment

The package contains no environment-specific values. They are applied at deploy time:

| What | Where it lives | Example |
|---|---|---|
| Settings that are not secret | [deploy/environments/](deploy/environments/)`<name>.psd1`, in Git, so changes are reviewed | environment name, port, log level |
| Secrets | The `DB_CONNECTION_STRING` secret of the GitHub environment with the same name | database connection string |

The deployment writes both into the `web.config` of the release as environment variables
of the app. With Windows authentication (`Integrated Security=true`) the app connects to
SQL Server as its app pool identity, so the connection string holds no password at all.

## How a deployment works

[deploy/Deploy-IisSite.ps1](deploy/Deploy-IisSite.ps1) puts every release in its own folder
and points the IIS site at it:

```
C:\inetpub\sites\LendingApi\
    deployments.log
    releases\
        1.0.41\      <- previous release, kept for rollback
        1.0.42\      <- the site points here
```

1. Unpack the package into `releases\<version>`
2. Write the environment's settings and connection string into that release's `web.config`
3. Create the app pool if it does not exist (No Managed Code, in-process hosting), and give its identity read access to the site folder only
4. Back up and migrate the database
5. Point the site at the new release and restart the app pool
6. Call `/health` and `/version` until the expected version answers. `/health` includes a database check
7. If it does not, point the site back at the previous release and fail the job
8. Remove releases beyond the newest five and add a line to `deployments.log`

Because the old release is still on disk, a rollback takes seconds and needs no rebuild.

## How database changes work

Schema changes are plain SQL scripts in [db/migrations](db/migrations), named
`<version>_<description>.sql`. [deploy/Invoke-DbMigrations.ps1](deploy/Invoke-DbMigrations.ps1)
applies them:

- Each script runs once, in version order, in its own transaction, and is recorded in the `dbo.SchemaVersions` table with a checksum, the time and the login that applied it.
- Before an existing database is changed, it is backed up (`BACKUP DATABASE ... WITH COPY_ONLY`).
- A script that was edited after it was applied is refused. Changes go into a new script.
- The app's login is added to `db_datareader` and `db_datawriter` only. The schema is changed by the deploying account, not by the app.

Scripts must be **backward compatible** with the release that is currently live: add columns
with defaults, do not rename or drop in the same release. A failed deployment then only
rolls back the code, and the previous release keeps working against the newer schema.
[0003_add_loan_status.sql](db/migrations/0003_add_loan_status.sql) is an example.

## Repository layout

| Path | Contents |
|---|---|
| [src/LendingApi](src/LendingApi) | The API: `/health`, `/version`, `/api/loans` |
| [tests/LendingApi.Tests](tests/LendingApi.Tests) | Integration tests that run the API in memory |
| [db/migrations](db/migrations) | Versioned SQL Server scripts |
| [deploy/Install-Prerequisites.ps1](deploy/Install-Prerequisites.ps1) | Installs IIS and the ASP.NET Core Hosting Bundle if they are missing |
| [deploy/Invoke-DbMigrations.ps1](deploy/Invoke-DbMigrations.ps1) | Backs up and migrates the database |
| [deploy/Deploy-IisSite.ps1](deploy/Deploy-IisSite.ps1) | Deploys, verifies and rolls back a release |
| [deploy/Test-Rollback.ps1](deploy/Test-Rollback.ps1) | Deploys a broken package to prove the rollback works |
| [deploy/environments](deploy/environments) | Settings per environment |
| [deploy/ci](deploy/ci) | Pipeline helpers: a LocalDB instance and the migration tests |
| [.github/workflows](.github/workflows) | `ci-cd.yml` (build and promotion) and `deploy.yml` (one deployment) |
| [docs/runbook.md](docs/runbook.md) | How to deploy, roll back and troubleshoot by hand |

## Run it locally

Local development uses an in-memory store, so no database is needed:

```powershell
dotnet test
dotnet run --project src/LendingApi
# http://localhost:5141/api/loans
```

To deploy to IIS on your own Windows machine, from an elevated Windows PowerShell prompt.
This example uses a local SQL Server Express instance:

```powershell
dotnet publish src/LendingApi -c Release -p:Version=1.0.1 -o publish
Compress-Archive -Path publish/* -DestinationPath LendingApi-1.0.1.zip

.\deploy\Install-Prerequisites.ps1
.\deploy\Deploy-IisSite.ps1 -PackagePath .\LendingApi-1.0.1.zip -Version 1.0.1 -EnvironmentName dev `
    -ConnectionString 'Server=.\SQLEXPRESS;Database=LendingDb;Integrated Security=true;TrustServerCertificate=true'
# http://localhost:8085/version
```

## Using real servers

In this repository every environment is deployed to IIS on a temporary GitHub-hosted
Windows runner, with SQL Server LocalDB standing in for the database server. To deploy
to real servers instead:

1. On each IIS server, install a GitHub Actions self-hosted runner as a service that runs
   with administrator rights, and pass its label as the `runner` input in `ci-cd.yml`.
2. In the repository settings, add the secret `DB_CONNECTION_STRING` to each environment
   (`dev`, `uat`, `preprod`, `prod`).
3. Add required reviewers to the `prod` environment. This gives a manual approval before
   each production deployment.

## Limits of this sample

- No environment here is a real server. Each one is a fresh runner that is thrown away after
  the job, so the database is always new and the backup step only runs in the migration tests.
- The connection string is stored in `web.config` as plain text. That is acceptable with
  Windows authentication, because it holds no password. A SQL login would need a protected store.
- The `prod` environment has no required reviewers until they are added in the repository settings.
- The site is served over HTTP on port 8085. There is no certificate or HTTPS binding.
- The migration runner is a short script written for this sample. A real project would
  normally use an established tool such as DbUp, Flyway or a DACPAC.
- Application logs go to the default providers. Central logging and alerting are not set up.
