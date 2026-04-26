$ErrorActionPreference = 'Stop'

$RootDir = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $RootDir

if (-not (Test-Path '.env')) {
  Copy-Item '.env.example' '.env'
  Write-Host 'Created .env from .env.example'
}

if (Get-Command docker -ErrorAction SilentlyContinue) {
  Write-Host 'Starting local dependency containers: redis, oracle19c'
  docker compose up -d redis oracle19c
}
else {
  Write-Host 'Docker is not available. Make sure Oracle and Redis are reachable from .env.'
}

if (-not (Get-Command yarn -ErrorAction SilentlyContinue)) {
  if (Get-Command corepack -ErrorAction SilentlyContinue) {
    corepack enable
  }
}

yarn install --frozen-lockfile
yarn dev
