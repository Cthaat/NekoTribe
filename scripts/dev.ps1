param([switch]$Dependencies)
$ErrorActionPreference = 'Stop'
$Arguments = @((Join-Path $PSScriptRoot 'startup.mjs'), 'dev')
if ($Dependencies) { $Arguments += '--dependencies' }
& node @Arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
