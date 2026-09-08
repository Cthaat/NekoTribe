import { existsSync } from 'node:fs';
import { loadEnvFile } from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { resolveRuntimeEnvironment } from './runtime-env.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
process.chdir(root);
const [mode = 'dev', ...args] = process.argv.slice(2);
if (!['dev', 'start'].includes(mode)) {
  throw new Error('Expected dev or start. Build with yarn build first.');
}
const dotenvIndex = args.indexOf('--dotenv');
if (dotenvIndex >= 0 && !args[dotenvIndex + 1]) {
  throw new Error('--dotenv requires a file path');
}
const dotenv = resolve(root, dotenvIndex >= 0 ? args[dotenvIndex + 1] : '.env');
if (existsSync(dotenv)) loadEnvFile(dotenv);
else if (dotenvIndex >= 0) throw new Error('The requested environment file does not exist');
Object.assign(process.env, resolveRuntimeEnvironment(process.env, mode));

if (mode === 'dev') {
  process.argv = [process.argv[0], process.argv[1], 'dev', ...args];
  await import('@nuxt/cli/cli');
} else {
  const remaining = dotenvIndex >= 0
    ? args.filter((_, index) => index !== dotenvIndex && index !== dotenvIndex + 1)
    : args;
  if (remaining.length) throw new Error('For production set HOST/PORT in the environment; only --dotenv is accepted.');
  const entry = resolve(root, '.output/server/index.mjs');
  if (!existsSync(entry)) throw new Error('Build output is missing. Run yarn build first.');
  await import(pathToFileURL(entry).href);
}
