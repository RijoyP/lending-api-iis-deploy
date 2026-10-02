#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys a release of the API to IIS, verifies it, and rolls back if verification fails.

.DESCRIPTION
    Every release is unpacked into its own folder:

        <SitesRoot>\<SiteName>\releases\<Version>

    The IIS site is then pointed at that folder. The previous release stays on disk, so a
    rollback is only a matter of pointing the site back at it.

    Steps:
      1. Unpack the package into a new release folder
      2. Set the environment name in the release's web.config
      3. Create the app pool and site if they do not exist
      4. Point the site at the new release and restart the app pool
      5. Verify /health and /version
      6. Roll back to the previous release if verification fails
      7. Remove old releases and write a line to the deployment log

    To roll back by hand, run the script with -Version set to a release that is still on
    the server and leave out -PackagePath.

.EXAMPLE
    .\Deploy-IisSite.ps1 -PackagePath .\LendingApi-1.0.42.zip -Version 1.0.42 -Environment Test

.EXAMPLE
    .\Deploy-IisSite.ps1 -Version 1.0.41 -Environment Test
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [string]$PackagePath,

    [string]$SiteName = 'LendingApi',

    [int]$Port = 8085,

    [string]$Environment = 'Production',

    [string]$SitesRoot = 'C:\inetpub\sites',

    [int]$KeepReleases = 5
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Import-Module WebAdministration

$siteRoot = Join-Path $SitesRoot $SiteName
$releasesRoot = Join-Path $siteRoot 'releases'
$releasePath = Join-Path $releasesRoot $Version
$appPoolName = $SiteName
$sitePath = "IIS:\Sites\$SiteName"
$appPoolPath = "IIS:\AppPools\$appPoolName"
$baseUrl = "http://localhost:$Port"

function Write-Step([string]$Message) {
    Write-Host "==> $Message"
}

function Write-DeploymentLog([string]$Result) {
    $line = '{0:u} | {1} | {2} | {3} | {4}\{5}' -f (Get-Date).ToUniversalTime(), $Version, $Environment, $Result, $env:USERDOMAIN, $env:USERNAME
    Add-Content -Path (Join-Path $siteRoot 'deployments.log') -Value $line
}

function Set-AspNetCoreEnvironment([string]$WebConfigPath, [string]$Name) {
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($WebConfigPath)

    $aspNetCore = $xml.SelectSingleNode('//aspNetCore')
    if (-not $aspNetCore) {
        throw "No <aspNetCore> element found in $WebConfigPath."
    }

    $variables = $aspNetCore.SelectSingleNode('environmentVariables')
    if (-not $variables) {
        $variables = $xml.CreateElement('environmentVariables')
        [void]$aspNetCore.AppendChild($variables)
    }

    $variable = $variables.SelectSingleNode("environmentVariable[@name='ASPNETCORE_ENVIRONMENT']")
    if (-not $variable) {
        $variable = $xml.CreateElement('environmentVariable')
        $variable.SetAttribute('name', 'ASPNETCORE_ENVIRONMENT')
        [void]$variables.AppendChild($variable)
    }

    $variable.SetAttribute('value', $Name)
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
            $health = Invoke-WebRequest -Uri "$baseUrl/health" -UseBasicParsing -TimeoutSec 15
            $info = Invoke-RestMethod -Uri "$baseUrl/version" -TimeoutSec 15
            # The build stamps the version as "<version>+<commit sha>".
            $runningVersion = ($info.version -split '\+')[0]

            if ($health.StatusCode -eq 200) {
                if (-not $ExpectedVersion) {
                    Write-Host "    Healthy, running $runningVersion ($($info.environment))."
                    return $true
                }
                if ($runningVersion -eq $ExpectedVersion -and $info.environment -eq $Environment) {
                    Write-Host "    Healthy, running $($info.version) ($($info.environment)) on $($info.machine)."
                    return $true
                }
                Write-Host "    Attempt $attempt/${Attempts}: running $runningVersion ($($info.environment)), expected $ExpectedVersion ($Environment)."
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
    $site = Get-Website | Where-Object { $_.Name -eq $SiteName }
    $currentPath = [Environment]::ExpandEnvironmentVariables($site.physicalPath)
}

if ($PackagePath) {
    if (-not (Test-Path $PackagePath)) {
        throw "Package not found: $PackagePath"
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

Write-Step "Setting environment to $Environment"
Set-AspNetCoreEnvironment -WebConfigPath (Join-Path $releasePath 'web.config') -Name $Environment

# --- 3. App pool and site --------------------------------------------------------------

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

# --- 4. Switch -------------------------------------------------------------------------

if ($currentPath) {
    Write-Step "Switching site $SiteName from $currentPath to $releasePath"
    Set-ItemProperty -Path $sitePath -Name physicalPath -Value $releasePath
}
else {
    Write-Step "Creating site $SiteName on port $Port"
    New-Website -Name $SiteName -Port $Port -PhysicalPath $releasePath -ApplicationPool $appPoolName | Out-Null
}

Restart-AppPool
if ((Get-WebsiteState -Name $SiteName).Value -ne 'Started') {
    Start-Website -Name $SiteName
}

# --- 5. Verify -------------------------------------------------------------------------

Write-Step "Verifying $baseUrl"
$verified = Test-Deployment -ExpectedVersion $Version

# --- 6. Roll back on failure -----------------------------------------------------------

if (-not $verified) {
    if ($currentPath -and $currentPath -ne $releasePath) {
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

# --- 7. Clean up and record ------------------------------------------------------------

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
