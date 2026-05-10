param(
  [switch]$Force,
  [string]$OracleContainerName,
  [string]$OracleSysServiceName,
  [string]$OraclePdbName
)

$ErrorActionPreference = 'Stop'

$RootDir = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $RootDir

function Import-DotEnv {
  param([string]$Path)

  if (-not (Test-Path $Path)) {
    return
  }

  Get-Content $Path | ForEach-Object {
    $Line = $_.Trim()
    if (
      $Line -and
      -not $Line.StartsWith('#') -and
      $Line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
    ) {
      $Name = $Matches[1]
      $Value = $Matches[2].Trim()
      if (
        ($Value.StartsWith('"') -and $Value.EndsWith('"')) -or
        ($Value.StartsWith("'") -and $Value.EndsWith("'"))
      ) {
        $Value = $Value.Substring(1, $Value.Length - 2)
      }
      [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    }
  }
}

function Assert-OracleIdentifier {
  param(
    [string]$Value,
    [string]$Name
  )

  if ($Value -notmatch '^[A-Za-z][A-Za-z0-9_$#]*$') {
    throw "$Name is not a safe Oracle identifier: $Value"
  }
}

function Test-DockerContainerRunning {
  param([string]$Name)

  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    return $false
  }

  $Names = docker ps --format '{{.Names}}'
  return ($Names | Select-String -Pattern "^$([regex]::Escape($Name))$" -Quiet)
}

function Wait-OracleContainer {
  param([string]$Name)

  for ($Index = 1; $Index -le 60; $Index++) {
    docker exec $Name sh -lc 'lsnrctl status >/dev/null 2>&1'
    if ($LASTEXITCODE -eq 0) {
      return
    }
    Write-Host "Waiting for Oracle listener ($Index/60)..."
    Start-Sleep -Seconds 10
  }

  throw 'Oracle listener did not become ready in time.'
}

function New-ResetSql {
  param([string]$PdbName)

  @"
SET SERVEROUTPUT ON
SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
  PROCEDURE try_switch_container IS
  BEGIN
    EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = $PdbName';
    DBMS_OUTPUT.PUT_LINE('[OK] switched container to $PdbName');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('[WARN] skip container switch: ' || SQLERRM);
  END;
BEGIN
  try_switch_container;
END;
/

DECLARE
  PROCEDURE drop_optional(
    p_sql          IN VARCHAR2,
    p_label        IN VARCHAR2,
    p_missing_code IN NUMBER
  ) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    DBMS_OUTPUT.PUT_LINE('[OK] dropped ' || p_label);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = p_missing_code THEN
        DBMS_OUTPUT.PUT_LINE('[SKIP] missing ' || p_label);
      ELSE
        DBMS_OUTPUT.PUT_LINE('[ERROR] failed to drop ' || p_label || ': ' || SQLERRM);
        RAISE;
      END IF;
  END;

  PROCEDURE run_noncritical(
    p_sql   IN VARCHAR2,
    p_label IN VARCHAR2
  ) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    DBMS_OUTPUT.PUT_LINE('[OK] ' || p_label);
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('[WARN] skip ' || p_label || ': ' || SQLERRM);
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Resetting NekoTribe Oracle V2 objects...');

  drop_optional('DROP USER neko_readonly CASCADE', 'user neko_readonly', -1918);
  drop_optional('DROP USER neko_admin CASCADE', 'user neko_admin', -1918);
  drop_optional('DROP USER neko_app CASCADE', 'user neko_app', -1918);

  drop_optional(
    'DROP TABLESPACE neko_index INCLUDING CONTENTS AND DATAFILES',
    'tablespace neko_index',
    -959
  );
  drop_optional(
    'DROP TABLESPACE neko_data INCLUDING CONTENTS AND DATAFILES',
    'tablespace neko_data',
    -959
  );
  drop_optional(
    'DROP TABLESPACE neko_temp INCLUDING CONTENTS AND DATAFILES',
    'tablespace neko_temp',
    -959
  );

  run_noncritical('PURGE DBA_RECYCLEBIN', 'purged DBA recycle bin');

  DBMS_OUTPUT.PUT_LINE('NekoTribe Oracle V2 reset finished.');
END;
/

EXIT;
"@
}

function Invoke-DockerOracleReset {
  param(
    [string]$Name,
    [string]$SqlFile
  )

  $Target = '/tmp/neko_tribe-oracle-v2-reset.sql'
  Wait-OracleContainer -Name $Name
  docker cp $SqlFile "${Name}:$Target"
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to copy reset SQL into Oracle container.'
  }

  docker exec -i $Name sh -lc "ORACLE_SID=$OracleSysServiceName sqlplus -s '/ as sysdba' @$Target"
  if ($LASTEXITCODE -ne 0) {
    throw "Oracle reset failed with exit code $LASTEXITCODE."
  }

  docker exec $Name sh -lc "rm -f $Target" | Out-Null
}

function Invoke-LocalSqlplusReset {
  param([string]$SqlFile)

  if (-not (Get-Command sqlplus -ErrorAction SilentlyContinue)) {
    throw "sqlplus is not available and Oracle container '$OracleContainerName' is not running."
  }

  if (-not $env:ORACLE_HOST) { throw 'ORACLE_HOST is required' }
  if (-not $env:ORACLE_PORT) { throw 'ORACLE_PORT is required' }
  if (-not $env:ORACLE_PWD) { throw 'ORACLE_PWD is required for SYSDBA reset' }

  $ConnectString = "sys/$($env:ORACLE_PWD)@$($env:ORACLE_HOST):$($env:ORACLE_PORT)/$OracleSysServiceName as sysdba"
  sqlplus -s $ConnectString "@$SqlFile"
  if ($LASTEXITCODE -ne 0) {
    throw "Oracle reset failed with exit code $LASTEXITCODE."
  }
}

Import-DotEnv -Path '.env'

if (-not $OracleContainerName) {
  $OracleContainerName = if ($env:ORACLE_CONTAINER_NAME) { $env:ORACLE_CONTAINER_NAME } else { 'oracle19c' }
}
if (-not $OracleSysServiceName) {
  $OracleSysServiceName = if ($env:ORACLE_SYS_SERVICE_NAME) { $env:ORACLE_SYS_SERVICE_NAME } else { 'ORCLCDB' }
}
if (-not $OraclePdbName) {
  $OraclePdbName = if ($env:ORACLE_PDB_NAME) { $env:ORACLE_PDB_NAME } else { 'ORCLPDB1' }
}

Assert-OracleIdentifier -Value $OracleSysServiceName -Name 'OracleSysServiceName'
Assert-OracleIdentifier -Value $OraclePdbName -Name 'OraclePdbName'

Write-Warning 'This will DROP NekoTribe V2 users and tablespaces: neko_app, neko_admin, neko_readonly, neko_data, neko_index, neko_temp.'
Write-Warning 'All V2 schema objects, seed data, materialized views, grants, and stored code created by doc/neko_tribe-oracle-v2.sql will be removed.'

if (-not $Force) {
  $Answer = Read-Host 'Type RESET to continue'
  if ($Answer -ne 'RESET') {
    Write-Host 'Reset cancelled.'
    exit 1
  }
}

$TempSql = Join-Path $env:TEMP "neko_tribe-oracle-v2-reset-$PID.sql"
New-ResetSql -PdbName $OraclePdbName | Set-Content -Path $TempSql -Encoding UTF8

try {
  if (Test-DockerContainerRunning -Name $OracleContainerName) {
    Invoke-DockerOracleReset -Name $OracleContainerName -SqlFile $TempSql
  }
  else {
    Invoke-LocalSqlplusReset -SqlFile $TempSql
  }
}
finally {
  Remove-Item -LiteralPath $TempSql -Force -ErrorAction SilentlyContinue
}

Write-Host 'Database reset finished. You can now run scripts/init-db.ps1 again.'
