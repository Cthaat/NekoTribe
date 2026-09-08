param([switch]$Compose)
$ErrorActionPreference = 'Stop'
$Arguments = @((Join-Path $PSScriptRoot 'startup.mjs'), 'start')
if ($Compose) { $Arguments += '--compose' }
& node @Arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
