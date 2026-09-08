import { build } from 'esbuild';
import { mkdir, rm } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Keep external native packages resolved against this checkout's dependencies.
const directory = new URL(`../.codex-logs/storage-test-${process.pid}/`, import.meta.url);
await mkdir(directory, { recursive: true });
const outfile = fileURLToPath(new URL('test.mjs', directory));
try {
  await build({
    entryPoints: [fileURLToPath(new URL('../server/storage/index.test.ts', import.meta.url))],
    outfile, bundle: true, platform: 'node', format: 'esm', packages: 'external'
  });
  await import(pathToFileURL(outfile).href);
} finally {
  await rm(directory, { recursive: true, force: true });
}
