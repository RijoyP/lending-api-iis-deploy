<#
.SYNOPSIS
    Starts a SQL Server LocalDB instance for the pipeline. Not used on real servers.

.DESCRIPTION
    GitHub-hosted runners have no SQL Server, so the pipeline uses LocalDB to stand in for
    one. A LocalDB instance belongs to the user who created it. IIS runs the app as the
    app pool identity, which is a different user, so the instance is shared under
    -SharedName and reached as (localdb)\.\<SharedName>. Sharing needs administrator rights.

.EXAMPLE
    .\Start-LocalDb.ps1 -InstanceName LendingCi -SharedName LendingShared
#>
[CmdletBinding()]
param(
    [string]$InstanceName = 'LendingCi',

    [string]$SharedName
)

$ErrorActionPreference = 'Stop'

function Find-SqlLocalDb {
    $command = Get-Command sqllocaldb.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $candidate = Get-ChildItem "$env:ProgramFiles\Microsoft SQL Server\*\Tools\Binn\SqlLocalDB.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($candidate) {
        return $candidate.FullName
    }
    return $null
}

function Invoke-SqlLocalDb {
    $output = & $sqlLocalDb @args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "sqllocaldb $($args -join ' ') failed: $output"
    }
    return $output
}

$sqlLocalDb = Find-SqlLocalDb
if (-not $sqlLocalDb) {
    Write-Host 'SQL Server LocalDB not found. Installing it with Chocolatey...'
    & choco.exe install sqllocaldb -y --no-progress | Out-Null
    $sqlLocalDb = Find-SqlLocalDb
    if (-not $sqlLocalDb) {
        throw 'SQL Server LocalDB could not be installed.'
    }
}

$instances = (Invoke-SqlLocalDb info) -split "`r?`n" | ForEach-Object { $_.Trim() }
if ($instances -notcontains $InstanceName) {
    Write-Host "Creating LocalDB instance $InstanceName"
    Invoke-SqlLocalDb create $InstanceName | Out-Null
}

if ($SharedName) {
    Write-Host "Sharing $InstanceName as $SharedName"
    Invoke-SqlLocalDb share $InstanceName $SharedName | Out-Null
    # The shared name only works after a restart of the instance.
    Invoke-SqlLocalDb stop $InstanceName | Out-Null
}

Invoke-SqlLocalDb start $InstanceName | Out-Null

if ($SharedName) {
    Write-Host "LocalDB is running as (localdb)\.\$SharedName"
}
else {
    Write-Host "LocalDB is running as (localdb)\$InstanceName"
}
