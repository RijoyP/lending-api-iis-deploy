#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Proves that a bad release is rejected and the site keeps serving the previous one.

.DESCRIPTION
    Builds a deliberately broken package (the application DLL is removed), tries to deploy
    it, and checks that:
      - Deploy-IisSite.ps1 reports a failure
      - the site still serves the known good version afterwards

    Run it after a successful deployment of -GoodVersion.

.EXAMPLE
    .\Test-Rollback.ps1 -PackagePath .\LendingApi-1.0.42.zip -GoodVersion 1.0.42 -Environment Test
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,

    [Parameter(Mandatory)]
    [string]$GoodVersion,

    [string]$SiteName = 'LendingApi',

    [int]$Port = 8085,

    [string]$Environment = 'Production'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$workFolder = Join-Path $env:TEMP "broken-release-$(Get-Random)"
$brokenPackage = "$workFolder.zip"

Expand-Archive -Path $PackagePath -DestinationPath $workFolder
Remove-Item -Path (Join-Path $workFolder "$SiteName.dll")
Compress-Archive -Path (Join-Path $workFolder '*') -DestinationPath $brokenPackage

$rejected = $false
try {
    & (Join-Path $PSScriptRoot 'Deploy-IisSite.ps1') -PackagePath $brokenPackage -Version '0.0.0-broken' `
        -SiteName $SiteName -Port $Port -Environment $Environment
}
catch {
    $rejected = $true
    Write-Host "Broken release was rejected as expected: $($_.Exception.Message)"
}
finally {
    Remove-Item -Path $workFolder, $brokenPackage -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $rejected) {
    throw 'The broken release was accepted. Post-deploy verification is not working.'
}

$info = Invoke-RestMethod -Uri "http://localhost:$Port/version" -TimeoutSec 30
$runningVersion = ($info.version -split '\+')[0]
if ($runningVersion -ne $GoodVersion) {
    throw "After the rollback the site runs $runningVersion, expected $GoodVersion."
}

Write-Host "Rollback verified. The site still serves $($info.version)."
