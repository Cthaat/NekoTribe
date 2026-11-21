$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'init-db.mjs') @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
