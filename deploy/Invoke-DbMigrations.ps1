<#
.SYNOPSIS
    Brings a SQL Server database up to date with the versioned scripts in db/migrations.

.DESCRIPTION
    Scripts are named <version>_<description>.sql, for example 0003_add_loan_status.sql.
    They are applied in version order, each in its own transaction, and recorded in the
    dbo.SchemaVersions table. A script that has been applied is never run again.

    Steps:
      1. Create the database if it does not exist
      2. Create dbo.SchemaVersions if it does not exist
      3. Refuse to continue if a script that was already applied has been edited
      4. Back up the database when there are scripts to apply
      5. Apply the pending scripts
      6. Give the application login read and write access, and nothing more

    Scripts must be backward compatible with the release that is currently live (add
    columns with defaults, do not rename or drop). The code can then be rolled back
    without touching the database.

.EXAMPLE
    .\Invoke-DbMigrations.ps1 -ConnectionString 'Server=SQL01;Database=LendingDb;Integrated Security=true' `
        -AppLogin 'IIS APPPOOL\LendingApi'
#>
[CmdletBinding()]
param(
    # Connection used to change the schema. Needs rights to create tables and take backups.
    [Parameter(Mandatory)]
    [string]$ConnectionString,

    # Default: db\migrations next to the deploy folder.
    [string]$MigrationsPath,

    # Windows login the application runs as. It is added to db_datareader and db_datawriter.
    [string]$AppLogin,

    # Folder for the backup, as seen by the SQL Server service. Default: the instance's backup folder.
    [string]$BackupDirectory,

    [switch]$SkipBackup
)

$ErrorActionPreference = 'Stop'

if (-not $MigrationsPath) {
    $MigrationsPath = Join-Path $PSScriptRoot '..\db\migrations'
}

function Open-Connection([string]$ConnectionStringToOpen) {
    $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionStringToOpen
    $connection.Open()
    return $connection
}

function New-Command($Connection, [string]$Sql, [hashtable]$Parameters, $Transaction) {
    $command = $Connection.CreateCommand()
    $command.CommandText = $Sql
    $command.CommandTimeout = 600
    if ($Transaction) { $command.Transaction = $Transaction }
    if ($Parameters) {
        foreach ($name in $Parameters.Keys) {
            [void]$command.Parameters.AddWithValue("@$name", $Parameters[$name])
        }
    }
    return $command
}

function Invoke-NonQuery($Connection, [string]$Sql, [hashtable]$Parameters, $Transaction) {
    $command = New-Command $Connection $Sql $Parameters $Transaction
    try { [void]$command.ExecuteNonQuery() } finally { $command.Dispose() }
}

function Invoke-Scalar($Connection, [string]$Sql, [hashtable]$Parameters) {
    $command = New-Command $Connection $Sql $Parameters $null
    try { return $command.ExecuteScalar() } finally { $command.Dispose() }
}

# Line endings are normalised so the checksum is the same on every machine.
function Get-ScriptChecksum([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Text -replace "`r`n", "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

$builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $ConnectionString
# The builder is also a dictionary, so psbase is needed to reach its properties.
$database = $builder.psbase.InitialCatalog
if ($database -notmatch '^[A-Za-z0-9_]+$') {
    throw "The connection string must name a database (letters, digits and underscores only)."
}
$builder.psbase.InitialCatalog = 'master'
$masterConnectionString = $builder.psbase.ConnectionString

# --- Load the scripts ------------------------------------------------------------------

$scripts = @(Get-ChildItem -Path $MigrationsPath -Filter '*.sql' | Sort-Object Name | ForEach-Object {
        if ($_.Name -notmatch '^(\d+)_.+\.sql$') {
            throw "Migration '$($_.Name)' is not named <version>_<description>.sql."
        }
        $text = [System.IO.File]::ReadAllText($_.FullName)
        [pscustomobject]@{
            Version  = [int]$Matches[1]
            Name     = $_.Name
            Text     = $text
            Checksum = Get-ScriptChecksum $text
        }
    })

if ($scripts.Count -eq 0) {
    throw "No migration scripts found in $MigrationsPath."
}
$duplicates = @($scripts | Group-Object Version | Where-Object { $_.Count -gt 1 })
if ($duplicates.Count -gt 0) {
    throw "More than one migration has version $($duplicates[0].Name)."
}

# --- 1. Database -----------------------------------------------------------------------

$master = Open-Connection $masterConnectionString
try {
    $isNewDatabase = $null -eq (Invoke-Scalar $master 'SELECT DB_ID(@name)' @{ name = $database } | Where-Object { $_ -isnot [DBNull] })
    if ($isNewDatabase) {
        Write-Host "    Creating database $database"
        Invoke-NonQuery $master "CREATE DATABASE [$database]"
    }
}
finally {
    $master.Dispose()
}

$connection = Open-Connection $ConnectionString
try {
    # --- 2. Version table --------------------------------------------------------------

    Invoke-NonQuery $connection @'
IF OBJECT_ID('dbo.SchemaVersions') IS NULL
    CREATE TABLE dbo.SchemaVersions
    (
        Version    int            NOT NULL CONSTRAINT PK_SchemaVersions PRIMARY KEY,
        ScriptName nvarchar(260)  NOT NULL,
        Checksum   char(64)       NOT NULL,
        AppliedAt  datetimeoffset NOT NULL CONSTRAINT DF_SchemaVersions_AppliedAt DEFAULT SYSDATETIMEOFFSET(),
        AppliedBy  nvarchar(128)  NOT NULL CONSTRAINT DF_SchemaVersions_AppliedBy DEFAULT SUSER_SNAME()
    );
'@

    $applied = @{}
    $command = New-Command $connection 'SELECT Version, ScriptName, Checksum FROM dbo.SchemaVersions' $null $null
    $reader = $command.ExecuteReader()
    try {
        while ($reader.Read()) {
            $applied[[int]$reader['Version']] = [pscustomobject]@{ Name = $reader['ScriptName']; Checksum = $reader['Checksum'] }
        }
    }
    finally {
        $reader.Dispose()
        $command.Dispose()
    }

    # --- 3. Applied scripts must not change --------------------------------------------

    foreach ($script in $scripts) {
        if ($applied.ContainsKey($script.Version) -and $applied[$script.Version].Checksum -ne $script.Checksum) {
            throw "Migration $($script.Name) was changed after it was applied. Add a new script instead of editing an old one."
        }
    }

    $pending = @($scripts | Where-Object { -not $applied.ContainsKey($_.Version) })
    $backupFile = $null

    if ($pending.Count -eq 0) {
        Write-Host '    Database is up to date.'
    }
    else {
        # --- 4. Backup -----------------------------------------------------------------

        if (-not $isNewDatabase -and -not $SkipBackup) {
            $backupFile = '{0}-before-{1:D4}-{2:yyyyMMdd-HHmmss}.bak' -f $database, $pending[0].Version, (Get-Date).ToUniversalTime()
            if ($BackupDirectory) {
                $backupFile = Join-Path $BackupDirectory $backupFile
            }
            Write-Host "    Backing up $database to $backupFile"
            # COPY_ONLY leaves the regular backup chain untouched.
            Invoke-NonQuery $connection "BACKUP DATABASE [$database] TO DISK = @file WITH COPY_ONLY, INIT, CHECKSUM" @{ file = $backupFile }
        }

        # --- 5. Apply ------------------------------------------------------------------

        foreach ($script in $pending) {
            Write-Host "    Applying $($script.Name)"
            $transaction = $connection.BeginTransaction()
            try {
                # GO is a batch separator for client tools, not T-SQL, so split on it here.
                $batches = [regex]::Split($script.Text, '(?im)^\s*GO\s*$') | Where-Object { $_.Trim() }
                foreach ($batch in $batches) {
                    Invoke-NonQuery $connection $batch $null $transaction
                }
                Invoke-NonQuery $connection 'INSERT INTO dbo.SchemaVersions (Version, ScriptName, Checksum) VALUES (@version, @name, @checksum)' `
                    @{ version = $script.Version; name = $script.Name; checksum = $script.Checksum } $transaction
                $transaction.Commit()
            }
            catch {
                $transaction.Rollback()
                throw "Migration $($script.Name) failed and was rolled back: $($_.Exception.Message)"
            }
        }
    }

    # --- 6. Application access ---------------------------------------------------------

    if ($AppLogin) {
        Write-Host "    Granting $AppLogin read and write access"
        Invoke-NonQuery $connection @'
DECLARE @sql nvarchar(max);

IF SUSER_ID(@login) IS NULL
BEGIN
    SET @sql = N'CREATE LOGIN ' + QUOTENAME(@login) + N' FROM WINDOWS';
    EXEC (@sql);
END

IF DATABASE_PRINCIPAL_ID(@login) IS NULL
BEGIN
    SET @sql = N'CREATE USER ' + QUOTENAME(@login) + N' FOR LOGIN ' + QUOTENAME(@login);
    EXEC (@sql);
END

SET @sql = N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@login)
         + N'; ALTER ROLE db_datawriter ADD MEMBER ' + QUOTENAME(@login);
EXEC (@sql);
'@ @{ login = $AppLogin }
    }

    $currentVersion = Invoke-Scalar $connection 'SELECT ISNULL(MAX(Version), 0) FROM dbo.SchemaVersions'
    $newestScript = ($scripts | Measure-Object Version -Maximum).Maximum
    if ($currentVersion -gt $newestScript) {
        Write-Host "    The database (version $currentVersion) is newer than this package (version $newestScript). This is expected when rolling back."
    }

    [pscustomobject]@{
        Database       = $database
        SchemaVersion  = $currentVersion
        AppliedScripts = @($pending | ForEach-Object { $_.Name })
        BackupFile     = $backupFile
    }
}
finally {
    $connection.Dispose()
}
