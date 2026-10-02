#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys a release of the API to IIS, verifies it, and rolls back if verification fails.

.DESCRIPTION
    Every release is unpacked into its own folder:

        <SitesRoot>\<SiteName>\releases\<Version>

    The IIS site is then pointed at that folder. The previous release stays on disk, so a
    rollback is only a matter of pointing the site back at it.

    The same package is deployed to every environment. What differs per environment comes
    from two places, both applied at deploy time:
      - environments\<EnvironmentName>.psd1  settings that are not secret
      - -ConnectionString                    the secret, supplied by the pipeline

    Steps:
      1. Unpack the package into a new release folder
      2. Write the environment's settings and connection string into the release's web.config
      3. Create the app pool if it does not exist
      4. Back up and migrate the database (see Invoke-DbMigrations.ps1)
      5. Point the site at the new release and restart the app pool
      6. Verify /health and /version
      7. Roll back to the previous release if verification fails
      8. Remove old releases and write a line to the deployment log

    To roll back by hand, run the script with -Version set to a release that is still on
    the server and leave out -PackagePath and -ConnectionString.

.EXAMPLE
    .\Deploy-IisSite.ps1 -PackagePath .\LendingApi-1.0.42.zip -Version 1.0.42 -EnvironmentName uat `
        -ConnectionString 'Server=SQL01;Database=LendingDb;Integrated Security=true;TrustServerCertificate=true'

.EXAMPLE
    .\Deploy-IisSite.ps1 -Version 1.0.41 -EnvironmentName uat
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,

    # Name of a file in the environments folder: dev, uat, preprod or prod.
    [Parameter(Mandatory)]
    [string]$EnvironmentName,

    [string]$PackagePath,

    [string]$ConnectionString,

    # Default: db\migrations next to the deploy folder.
    [string]$MigrationsPath,

    [string]$SitesRoot = 'C:\inetpub\sites',

    [int]$KeepReleases = 5
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Import-Module WebAdministration

$environmentFile = Join-Path $PSScriptRoot "environments\$EnvironmentName.psd1"
if (-not (Test-Path $environmentFile)) {
    $known = (Get-ChildItem (Join-Path $PSScriptRoot 'environments') -Filter '*.psd1').BaseName -join ', '
    throw "Unknown environment '$EnvironmentName'. Known environments: $known."
}
$environment = Import-PowerShellDataFile -Path $environmentFile

$siteName = $environment.SiteName
$port = $environment.Port
$aspNetCoreEnvironment = $environment.AspNetCoreEnvironment

$siteRoot = Join-Path $SitesRoot $siteName
$releasesRoot = Join-Path $siteRoot 'releases'
$releasePath = Join-Path $releasesRoot $Version
$appPoolName = $siteName
$sitePath = "IIS:\Sites\$siteName"
$appPoolPath = "IIS:\AppPools\$appPoolName"
$baseUrl = "http://localhost:$port"
$schemaVersion = '-'

function Write-Step([string]$Message) {
    Write-Host "==> $Message"
}

function Write-DeploymentLog([string]$Result) {
    $line = '{0:u} | {1} | {2} | schema {3} | {4} | {5}\{6}' -f (Get-Date).ToUniversalTime(), $Version, $EnvironmentName, $schemaVersion, $Result, $env:USERDOMAIN, $env:USERNAME
    Add-Content -Path (Join-Path $siteRoot 'deployments.log') -Value $line
}

# Writes settings as environment variables of the app, in the release's web.config.
function Set-AppEnvironmentVariables([string]$WebConfigPath, [hashtable]$Variables) {
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($WebConfigPath)

    $aspNetCore = $xml.SelectSingleNode('//aspNetCore')
    if (-not $aspNetCore) {
        throw "No <aspNetCore> element found in $WebConfigPath."
    }

    $container = $aspNetCore.SelectSingleNode('environmentVariables')
    if (-not $container) {
        $container = $xml.CreateElement('environmentVariables')
        [void]$aspNetCore.AppendChild($container)
    }

    foreach ($name in $Variables.Keys) {
        $variable = $container.SelectSingleNode("environmentVariable[@name='$name']")
        if (-not $variable) {
            $variable = $xml.CreateElement('environmentVariable')
            $variable.SetAttribute('name', $name)
            [void]$container.AppendChild($variable)
        }
        $variable.SetAttribute('value', [string]$Variables[$name])
    }

    $xml.Save($WebConfigPath)
}

function Restart-AppPool {
    if ((Get-WebAppPoolState -Name $appPoolName).Value -eq 'Started') {
        Restart-WebAppPool -Name $appPoolName
    }
    else {
        Start-WebAppPool -Name $appPoolName
    }
}

# Returns $true when the site is healthy. When $ExpectedVersion is given, the running
# build and environment must match as well.
function Test-Deployment([string]$ExpectedVersion, [int]$Attempts = 15, [int]$DelaySeconds = 2) {
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $health = Invoke-WebRequest -Uri "$baseUrl/health" -UseBasicParsing -TimeoutSec 30
            $info = Invoke-RestMethod -Uri "$baseUrl/version" -TimeoutSec 30
            # The build stamps the version as "<version>+<commit sha>".
            $runningVersion = ($info.version -split '\+')[0]

            if ($health.StatusCode -eq 200) {
                if (-not $ExpectedVersion) {
                    Write-Host "    Healthy, running $runningVersion ($($info.environment))."
                    return $true
                }
                if ($runningVersion -eq $ExpectedVersion -and $info.environment -eq $aspNetCoreEnvironment) {
                    Write-Host "    Healthy, running $($info.version) ($($info.environment), $($info.storage)) on $($info.machine)."
                    return $true
                }
                Write-Host "    Attempt $attempt/${Attempts}: running $runningVersion ($($info.environment)), expected $ExpectedVersion ($aspNetCoreEnvironment)."
            }
        }
        catch {
            Write-Host "    Attempt $attempt/${Attempts}: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    return $false
}

# --- 1. Unpack -------------------------------------------------------------------------

$currentPath = $null
if (Test-Path $sitePath) {
    $site = Get-Website | Where-Object { $_.Name -eq $siteName }
    $currentPath = [Environment]::ExpandEnvironmentVariables($site.physicalPath)
}

if ($PackagePath) {
    if (-not (Test-Path $PackagePath)) {
        throw "Package not found: $PackagePath"
    }
    if (-not $ConnectionString) {
        throw 'A new release needs -ConnectionString.'
    }
    if ($currentPath -eq $releasePath) {
        throw "Release $Version is the one currently live. Build a new version instead of overwriting it."
    }

    Write-Step "Unpacking $PackagePath to $releasePath"
    if (Test-Path $releasePath) {
        # Left over from an earlier failed attempt at this version.
        Remove-Item -Path $releasePath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $releasePath -Force | Out-Null
    Expand-Archive -Path $PackagePath -DestinationPath $releasePath
}
elseif (-not (Test-Path $releasePath)) {
    throw "Release $Version is not on this server and no -PackagePath was given."
}
else {
    Write-Step "Re-activating existing release $Version"
}

# --- 2. Configuration ------------------------------------------------------------------

Write-Step "Applying settings for environment '$EnvironmentName'"
$variables = @{ ASPNETCORE_ENVIRONMENT = $aspNetCoreEnvironment }
foreach ($name in $environment.Settings.Keys) {
    $variables[$name] = $environment.Settings[$name]
}
if ($ConnectionString) {
    $variables['ConnectionStrings__LendingDb'] = $ConnectionString
}
Set-AppEnvironmentVariables -WebConfigPath (Join-Path $releasePath 'web.config') -Variables $variables

# --- 3. App pool -----------------------------------------------------------------------

if (-not (Test-Path $appPoolPath)) {
    Write-Step "Creating app pool $appPoolName"
    New-WebAppPool -Name $appPoolName | Out-Null
}
# ASP.NET Core runs through the ASP.NET Core Module, so the pool needs no managed runtime.
Set-ItemProperty -Path $appPoolPath -Name managedRuntimeVersion -Value ''

# Least privilege: the pool identity only gets read access to its own site folder.
& icacls.exe $siteRoot /grant "IIS AppPool\${appPoolName}:(OI)(CI)RX" /Q | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Could not grant the app pool identity access to $siteRoot."
}

# --- 4. Database -----------------------------------------------------------------------

if ($ConnectionString) {
    Write-Step 'Migrating the database'
    $migrationArguments = @{ ConnectionString = $ConnectionString }
    if ($MigrationsPath) {
        $migrationArguments.MigrationsPath = $MigrationsPath
    }
    # With Windows authentication the app connects as the app pool identity, so there is
    # no database password to store. That identity gets read and write access only.
    if ((New-Object System.Data.SqlClient.SqlConnectionStringBuilder $ConnectionString).psbase.IntegratedSecurity) {
        $migrationArguments.AppLogin = "IIS APPPOOL\$appPoolName"
    }
    $migration = & (Join-Path $PSScriptRoot 'Invoke-DbMigrations.ps1') @migrationArguments
    $schemaVersion = $migration.SchemaVersion
    Write-Host "    Schema version $schemaVersion."
}

# --- 5. Switch -------------------------------------------------------------------------

if ($currentPath) {
    Write-Step "Switching site $siteName from $currentPath to $releasePath"
    Set-ItemProperty -Path $sitePath -Name physicalPath -Value $releasePath
}
else {
    Write-Step "Creating site $siteName on port $port"
    New-Website -Name $siteName -Port $port -PhysicalPath $releasePath -ApplicationPool $appPoolName | Out-Null
}

Restart-AppPool
if ((Get-WebsiteState -Name $siteName).Value -ne 'Started') {
    Start-Website -Name $siteName
}

# --- 6. Verify -------------------------------------------------------------------------

Write-Step "Verifying $baseUrl"
$verified = Test-Deployment -ExpectedVersion $Version

# --- 7. Roll back on failure -----------------------------------------------------------

if (-not $verified) {
    if ($currentPath -and $currentPath -ne $releasePath) {
        # Only the code is rolled back. Migrations are backward compatible, so the
        # previous release keeps working against the newer schema.
        Write-Warning "Verification failed. Rolling back to $currentPath"
        Set-ItemProperty -Path $sitePath -Name physicalPath -Value $currentPath
        Restart-AppPool

        if (Test-Deployment) {
            Write-DeploymentLog -Result 'FAILED, rolled back'
            throw "Release $Version failed verification. The site was rolled back to $currentPath."
        }
        Write-DeploymentLog -Result 'FAILED, rollback also unhealthy'
        throw "Release $Version failed verification and the previous release is not healthy either. Manual action is needed."
    }

    Write-DeploymentLog -Result 'FAILED, no previous release'
    throw "Release $Version failed verification and there is no previous release to roll back to."
}

# --- 8. Clean up and record ------------------------------------------------------------

$keep = @($releasePath, $currentPath)
Get-ChildItem -Path $releasesRoot -Directory |
    Sort-Object CreationTimeUtc -Descending |
    Select-Object -Skip $KeepReleases |
    Where-Object { $keep -notcontains $_.FullName } |
    ForEach-Object {
        Write-Step "Removing old release $($_.Name)"
        Remove-Item -Path $_.FullName -Recurse -Force
    }

Write-DeploymentLog -Result 'OK'
Write-Step "Release $Version is live at $baseUrl"
