# Lending API: CI/CD to IIS

A small .NET 10 API with a GitHub Actions pipeline that builds it, tests it, packages it
and deploys it to IIS on Windows using PowerShell. The deployment verifies itself and
rolls back automatically when the new release is not healthy.

The API is deliberately simple. The point of the repository is the release process around it.

## What the pipeline does

```
push to main
   |
   v
build ---------------------> deploy-test ---------------------> deploy-production
restore                      install IIS + Hosting Bundle       (self-hosted runner on
vulnerable package check     deploy the package to IIS           the IIS server, behind
build, stamped with version  verify /health and /version         a manual approval)
test                         call the API through IIS
publish                      deploy a broken package and
zip = release package        check that it is rolled back
```

| Stage | What happens |
|---|---|
| **build** | Restores, fails on NuGet packages with known vulnerabilities, builds with version `1.0.<run number>`, runs the tests, and zips the published output. The package is built once and the same file is deployed to every environment. |
| **deploy-test** | Runs on a clean GitHub-hosted Windows runner. Installs IIS and the ASP.NET Core Hosting Bundle, deploys the package, and checks that the right version answers through IIS. It then deploys a deliberately broken package to prove that the rollback works. |
| **deploy-production** | Deploys the same package to a real IIS server through a self-hosted runner. It is skipped until a runner is registered (see [Deploying to a real server](#deploying-to-a-real-server)). |

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
2. Write the environment name (Test, Production) into that release's `web.config`
3. Create the app pool and site if they do not exist, and give the app pool identity read access to the site folder only
4. Point the site at the new release and restart the app pool
5. Call `/health` and `/version` until the expected version answers
6. If it does not, point the site back at the previous release and fail the job
7. Remove releases beyond the newest five and add a line to `deployments.log`

Because the old release is still on disk, a rollback takes seconds and needs no rebuild.

## Repository layout

| Path | Contents |
|---|---|
| [src/LendingApi](src/LendingApi) | The API: `/health`, `/version`, `/api/loans` |
| [tests/LendingApi.Tests](tests/LendingApi.Tests) | Integration tests that run the API in memory |
| [deploy/Install-Prerequisites.ps1](deploy/Install-Prerequisites.ps1) | Installs IIS and the ASP.NET Core Hosting Bundle if they are missing |
| [deploy/Deploy-IisSite.ps1](deploy/Deploy-IisSite.ps1) | Deploys, verifies and rolls back a release |
| [deploy/Test-Rollback.ps1](deploy/Test-Rollback.ps1) | Deploys a broken package to prove the rollback works |
| [.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml) | The pipeline |
| [docs/runbook.md](docs/runbook.md) | How to deploy, roll back and troubleshoot by hand |

## Run it locally

```powershell
dotnet test
dotnet run --project src/LendingApi
# http://localhost:5141/api/loans
```

To deploy to IIS on your own Windows machine, from an elevated Windows PowerShell prompt:

```powershell
dotnet publish src/LendingApi -c Release -p:Version=1.0.1 -o publish
Compress-Archive -Path publish/* -DestinationPath LendingApi-1.0.1.zip

.\deploy\Install-Prerequisites.ps1
.\deploy\Deploy-IisSite.ps1 -PackagePath .\LendingApi-1.0.1.zip -Version 1.0.1 -Environment Test
# http://localhost:8085/version
```

## Deploying to a real server

1. On the IIS server, install a GitHub Actions self-hosted runner as a service that runs with
   administrator rights, and give it the labels `windows` and `iis`.
2. In the repository settings, create the `production` environment and add required reviewers.
   This gives a manual approval before each production deployment.
3. Add the repository variable `PRODUCTION_RUNNER_READY` with the value `true`.

## Limits of this sample

- Loans are kept in memory and are lost when the app pool recycles. There is no SQL Server
  database and no database migration step.
- The test deployment targets IIS on a temporary GitHub-hosted runner. The production job
  uses the same scripts but has not been run against a real server.
- The site is served over HTTP on port 8085. There is no certificate or HTTPS binding.
- Application logs go to the default providers. Central logging and alerting are not set up.
