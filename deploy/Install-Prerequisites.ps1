#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prepares a Windows machine to host the API in IIS.

.DESCRIPTION
    Installs IIS with its PowerShell management tools and the ASP.NET Core Hosting Bundle
    (the runtime plus the IIS module that runs ASP.NET Core apps). Each part is skipped
    when it is already present, so the script is safe to run on every deployment.

.EXAMPLE
    .\Install-Prerequisites.ps1 -DotnetChannel 10.0
#>
[CmdletBinding()]
param(
    [string]$DotnetChannel = '10.0'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Install-Iis {
    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        # Windows Server
        $missing = @(Get-WindowsFeature -Name Web-Server, Web-Scripting-Tools | Where-Object { -not $_.Installed })
        if ($missing.Count -eq 0) {
            Write-Host 'IIS is already installed.'
            return
        }
        Write-Host "Installing IIS features: $($missing.Name -join ', ')"
        Install-WindowsFeature -Name $missing.Name | Out-Null
    }
    else {
        # Windows 10/11
        $missing = @('IIS-WebServerRole', 'IIS-WebServer', 'IIS-ManagementScriptingTools' | Where-Object {
                (Get-WindowsOptionalFeature -Online -FeatureName $_).State -ne 'Enabled'
            })
        if ($missing.Count -eq 0) {
            Write-Host 'IIS is already installed.'
            return
        }
        Write-Host "Enabling IIS features: $($missing -join ', ')"
        Enable-WindowsOptionalFeature -Online -FeatureName $missing -All -NoRestart | Out-Null
    }
}

function Install-HostingBundle {
    $module = Join-Path $env:ProgramFiles 'IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
    $runtime = Join-Path $env:ProgramFiles "dotnet\shared\Microsoft.AspNetCore.App\$DotnetChannel.*"

    if ((Test-Path $module) -and (Test-Path $runtime)) {
        Write-Host "ASP.NET Core Hosting Bundle $DotnetChannel is already installed."
        return
    }

    $installer = Join-Path $env:TEMP "dotnet-hosting-$DotnetChannel-win.exe"
    Write-Host "Downloading ASP.NET Core Hosting Bundle $DotnetChannel..."
    Invoke-WebRequest -Uri "https://aka.ms/dotnet/$DotnetChannel/dotnet-hosting-win.exe" -OutFile $installer -UseBasicParsing

    Write-Host 'Installing ASP.NET Core Hosting Bundle...'
    $process = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    # 3010 means the install succeeded and a reboot is recommended.
    if ($process.ExitCode -notin 0, 3010) {
        throw "Hosting Bundle installer failed with exit code $($process.ExitCode)."
    }

    # IIS only loads the new module and PATH after its services restart.
    Write-Host 'Restarting IIS...'
    & net.exe stop was /y | Out-Null
    & net.exe start w3svc | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'IIS did not start again after installing the Hosting Bundle.'
    }
}

Install-Iis
Install-HostingBundle

Import-Module WebAdministration
Write-Host "Prerequisites ready. IIS service status: $((Get-Service W3SVC).Status)"
