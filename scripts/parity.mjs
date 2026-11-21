#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { checkParity, syncSharedFiles } from './lib/parity.mjs';

try {
  const args = process.argv.slice(2);
  const command = args.shift();
  if (!['check', 'release', 'sync-shared'].includes(command)) {
    throw new Error('Usage: node scripts/parity.mjs check|release [--workspace-root PATH], or sync-shared --workspace-root PATH --shared FILE [--shared FILE]...');
  }
  let workspaceRoot;
  const paths = [];
  while (args.length) {
    const option = args.shift();
    const value = args.shift();
    if (!value || value.startsWith('--')) throw new Error(`Missing value for ${option}`);
    if (option === '--workspace-root' && !workspaceRoot) workspaceRoot = resolve(value);
    else if (command === 'sync-shared' && option === '--shared') paths.push(value);
    else throw new Error(`Unexpected argument: ${option}`);
  }
  const projectRoot = fileURLToPath(new URL('../', import.meta.url));
  const report = command === 'sync-shared'
    ? syncSharedFiles({ projectRoot, workspaceRoot, paths })
    : checkParity({ projectRoot, workspaceRoot, release: command === 'release' });
  console.log(JSON.stringify({ command, ...report }));
} catch (error) {
  console.error(`parity: ${error instanceof Error ? error.message : 'check failed'}`);
  process.exitCode = 1;
}
