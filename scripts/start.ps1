$ErrorActionPreference = 'Stop'

$RootDir = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $RootDir

if (-not (Test-Path '.env')) {
  Copy-Item '.env.example' '.env'
  Write-Host 'Created .env from .env.example'
}

function Get-EnvFileValue {
  param(
    [string]$Path,
    [string]$Key
  )

  foreach ($line in Get-Content $Path) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#')) {
      continue
    }

    $parts = $trimmed -split '=', 2
    if ($parts.Count -ne 2) {
      continue
    }

    if ($parts[0].Trim() -ne $Key) {
      continue
    }

    return $parts[1].Trim().Trim("'`"")
  }

  return $null
}

$storageRootValue = Get-EnvFileValue '.env' 'STORAGE_ROOT_DIR'
if (-not $storageRootValue) {
  $storageRootValue = './storage'
}

if ([System.IO.Path]::IsPathRooted($storageRootValue)) {
  $storageRootDir = $storageRootValue
}
else {
  $storageRootDir = Join-Path $RootDir $storageRootValue
}

$storageTempDir = Join-Path $storageRootDir 'temp'
New-Item -ItemType Directory -Force -Path $storageRootDir, $storageTempDir | Out-Null

docker compose up -d --build
docker compose ps
