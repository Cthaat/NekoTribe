$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'init-db.mjs')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
