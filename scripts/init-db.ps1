$ErrorActionPreference = 'Stop'

$RootDir = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $RootDir

$SqlFile = if ($env:SQL_FILE) { $env:SQL_FILE } else { 'doc/neko_tribe-oracle-v2.sql' }
$OracleContainerName = if ($env:ORACLE_CONTAINER_NAME) { $env:ORACLE_CONTAINER_NAME } else { 'oracle19c' }

if (-not (Test-Path $SqlFile)) {
  throw "SQL file not found: $SqlFile"
}

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

function Invoke-DockerOracleInit {
  param([string]$Name)

  $Target = '/tmp/neko_tribe-oracle-v2.sql'
  Wait-OracleContainer -Name $Name
  docker cp $SqlFile "${Name}:$Target"
  docker exec -i $Name sh -lc "sqlplus -s '/ as sysdba' @$Target"
}

function Invoke-LocalSqlplusInit {
  if (-not (Get-Command sqlplus -ErrorAction SilentlyContinue)) {
    throw "sqlplus is not available and Oracle container '$OracleContainerName' is not running."
  }

  if (-not $env:ORACLE_HOST) { throw 'ORACLE_HOST is required' }
  if (-not $env:ORACLE_PORT) { throw 'ORACLE_PORT is required' }
  if (-not $env:ORACLE_PWD) { throw 'ORACLE_PWD is required for SYSDBA initialization' }

  $ServiceName = if ($env:ORACLE_SYS_SERVICE_NAME) { $env:ORACLE_SYS_SERVICE_NAME } else { 'ORCLCDB' }
  $ConnectString = "sys/$($env:ORACLE_PWD)@$($env:ORACLE_HOST):$($env:ORACLE_PORT)/$ServiceName as sysdba"

  sqlplus -s $ConnectString "@$SqlFile"
}

Import-DotEnv -Path '.env'

if (Test-DockerContainerRunning -Name $OracleContainerName) {
  Invoke-DockerOracleInit -Name $OracleContainerName
}
else {
  Invoke-LocalSqlplusInit
}

Write-Host 'Database initialization finished.'
