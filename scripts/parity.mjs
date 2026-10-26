#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { checkParity } from './lib/parity.mjs';

try {
  const args = process.argv.slice(2);
  const command = args.shift();
  if (!['check', 'release'].includes(command)) throw new Error('Usage: node scripts/parity.mjs [check|release] [--workspace-root PATH]');
  let workspaceRoot;
  if (args.length) {
    if (args.length !== 2 || args[0] !== '--workspace-root' || !args[1]) throw new Error('Expected --workspace-root PATH');
    workspaceRoot = resolve(args[1]);
  }
  const report = checkParity({ projectRoot: fileURLToPath(new URL('../', import.meta.url)), workspaceRoot, release: command === 'release' });
  console.log(JSON.stringify({ command, ...report }));
} catch (error) {
  console.error(`parity: ${error instanceof Error ? error.message : 'check failed'}`);
  process.exitCode = 1;
}
