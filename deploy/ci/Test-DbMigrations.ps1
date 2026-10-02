<#
.SYNOPSIS
    Tests Invoke-DbMigrations.ps1 and the migration scripts against a throw-away database.

.DESCRIPTION
    Checks that:
      - a new database is created and the first script is applied
      - an upgrade takes a backup first and applies the remaining scripts
      - running again changes nothing
      - a script that was edited after it was applied is refused

    The database and the backup are removed afterwards.

.EXAMPLE
    .\Test-DbMigrations.ps1 -Server '(localdb)\LendingCi'
#>
[CmdletBinding()]
param(
    [string]$Server = '(localdb)\MSSQLLocalDB',

    [string]$MigrationsPath
)

$ErrorActionPreference = 'Stop'

if (-not $MigrationsPath) {
    $MigrationsPath = Join-Path $PSScriptRoot '..\..\db\migrations'
}

$migrate = Join-Path $PSScriptRoot '..\Invoke-DbMigrations.ps1'
$database = "LendingDb_MigrationTest_$(Get-Random)"
$connectionString = "Server=$Server;Database=$database;Integrated Security=true;TrustServerCertificate=true"
$workFolder = Join-Path $env:TEMP $database
$firstOnly = Join-Path $workFolder 'first'
$edited = Join-Path $workFolder 'edited'

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "FAILED: $Message"
    }
    Write-Host "  ok: $Message"
}

$scripts = @(Get-ChildItem -Path $MigrationsPath -Filter '*.sql' | Sort-Object Name)
Assert-That ($scripts.Count -ge 2) 'there are at least two migration scripts to test an upgrade with'

New-Item -ItemType Directory -Path $firstOnly, $edited -Force | Out-Null
Copy-Item -Path $scripts[0].FullName -Destination $firstOnly
Copy-Item -Path (Join-Path $MigrationsPath '*.sql') -Destination $edited
Add-Content -Path (Join-Path $edited $scripts[0].Name) -Value '-- edited after release'

try {
    Write-Host 'New database'
    $result = & $migrate -ConnectionString $connectionString -MigrationsPath $firstOnly -BackupDirectory $workFolder
    Assert-That ($result.AppliedScripts.Count -eq 1) 'the first script is applied'
    Assert-That ($null -eq $result.BackupFile) 'no backup is taken of a database that was just created'

    Write-Host 'Upgrade'
    $result = & $migrate -ConnectionString $connectionString -MigrationsPath $MigrationsPath -BackupDirectory $workFolder
    Assert-That ($result.AppliedScripts.Count -eq $scripts.Count - 1) 'the remaining scripts are applied'
    Assert-That ($result.SchemaVersion -eq $scripts.Count) "the schema is at version $($scripts.Count)"
    Assert-That ($result.BackupFile -and (Test-Path $result.BackupFile)) 'a backup is taken before the upgrade'

    Write-Host 'Run again'
    $result = & $migrate -ConnectionString $connectionString -MigrationsPath $MigrationsPath -BackupDirectory $workFolder
    Assert-That ($result.AppliedScripts.Count -eq 0) 'nothing is applied the second time'
    Assert-That ($null -eq $result.BackupFile) 'no backup is taken when there is nothing to apply'

    Write-Host 'Edited script'
    $refused = $false
    try {
        & $migrate -ConnectionString $connectionString -MigrationsPath $edited -BackupDirectory $workFolder | Out-Null
    }
    catch {
        $refused = $_.Exception.Message -like '*was changed after it was applied*'
    }
    Assert-That $refused 'a script edited after it was applied is refused'

    Write-Host 'Migration tests passed.'
}
finally {
    [System.Data.SqlClient.SqlConnection]::ClearAllPools()
    $master = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=master;Integrated Security=true;TrustServerCertificate=true"
    $master.Open()
    try {
        $command = $master.CreateCommand()
        $command.CommandText = "IF DB_ID('$database') IS NOT NULL BEGIN ALTER DATABASE [$database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$database]; END"
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $master.Dispose()
    }
    Remove-Item -Path $workFolder -Recurse -Force -ErrorAction SilentlyContinue
}
