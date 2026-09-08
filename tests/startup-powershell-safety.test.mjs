import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

for (const executable of ['powershell.exe', 'pwsh.exe']) {
  test(`${executable}: syntax and reset SQL guard, no script execution`, { skip: process.platform !== 'win32' }, () => {
    const command = String.raw`
$ErrorActionPreference = 'Stop'
foreach ($file in @('dev.ps1','start.ps1','init-db.ps1','reset-db.ps1')) {
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PWD "scripts/$file"), [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Invalid PowerShell syntax: $file" }
  if ($file -eq 'reset-db.ps1') {
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-ResetSql' }, $true)
    # Evaluate only the SQL generator definition, never the reset entrypoint.
    Invoke-Expression $fn.Extent.Text
    $sql = New-ResetSql -PdbName ORCLPDB1
    if ($sql -notmatch '(?s)ALTER SESSION SET CONTAINER.*?EXCEPTION\s+WHEN OTHERS THEN\s+RAISE;') { throw 'Container switch must fail closed.' }
    if ($sql -notmatch 'WHENEVER SQLERROR EXIT' -or $sql -notmatch 'WHENEVER OSERROR EXIT') { throw 'SQL session guards missing.' }
  }
}
Write-Output 'POWERSHELL_SAFETY_PASS'
`;
    const result = spawnSync(executable, ['-NoProfile', '-NonInteractive', '-Command', command], { cwd: fileURLToPath(new URL('..', import.meta.url)), encoding: 'utf8', windowsHide: true, timeout: 30000 });
    assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /POWERSHELL_SAFETY_PASS/);
  });
}
