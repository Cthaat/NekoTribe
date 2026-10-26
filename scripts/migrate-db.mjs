import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { parseEnv } from 'node:util';
import { applySchema, checkSchema, planSchema } from '../server/database/schema.mjs';

const defaultRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export async function loadOracleDriver(root = defaultRoot) {
  let location;
  try {
    location = createRequire(resolve(root, 'scripts/migrate-db.mjs')).resolve('oracledb');
  } catch (error) {
    if (error.code !== 'MODULE_NOT_FOUND') throw error;
    // Portable Nuxt output/runtime images keep dependencies beside the server entry.
    location = createRequire(resolve(root, '.output/server/index.mjs')).resolve('oracledb');
  }
  return await import(pathToFileURL(location).href);
}
export async function migrateDatabase({ args = [], env = process.env, root = defaultRoot, loadDriver, output = console.log } = {}) {
  let action; let dotenv;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (['--plan', '--check', '--apply'].includes(arg)) {
      if (action) throw new Error('Specify at most one schema action.');
      action = arg;
    } else if (arg === '--dotenv') {
      if (dotenv !== undefined || typeof args[i + 1] !== 'string' || !args[i + 1].trim() || args[i + 1].startsWith('--')) throw new Error('Specify --dotenv once with a file path.');
      dotenv = args[++i];
    } else throw new Error('Use --plan, --check or --apply with optional --dotenv PATH; credentials belong in environment configuration.');
  }
  const mode = action ?? '--plan';
  if (mode === '--plan') { const plan = planSchema(); output(JSON.stringify({ mode: 'offline-plan', plan })); return plan; }
  // Only an explicit connected command reads .env or loads the Oracle driver.
  const envPath = resolve(root, dotenv ?? '.env');
  if (dotenv !== undefined && !existsSync(envPath)) throw new Error('The requested environment file does not exist.');
  const config = { ...(existsSync(envPath) ? parseEnv(readFileSync(envPath, 'utf8')) : {}), ...env };
  const get = name => config[`NUXT_${name}`] ?? config[name];
  const user = get('ORACLE_USER'); const password = get('ORACLE_PASSWORD');
  const host = get('ORACLE_HOST'); const port = get('ORACLE_PORT');
  const service = get('ORACLE_SERVICE_NAME');
  if (![user, password, host, port, service].every(v => typeof v === 'string' && v.length > 0)) throw new Error('Oracle environment configuration is incomplete.');
  let connection;
  try {
    const imported = await (loadDriver ? loadDriver() : loadOracleDriver(root)); const driver = imported.default ?? imported;
    connection = await driver.getConnection({ user, password, connectString: `${host}:${port}/${service}` });
    const adapter = {
      async execute(sql, binds = {}) {
        if (mode === '--check' && !/^SELECT\b/i.test(sql.trim())) throw new Error('Check mode is read-only.');
        const parameters = Object.fromEntries(Object.entries(binds).map(([key, value]) => [key,
          value && typeof value === 'object' && value.out === 'number' ? { dir: driver.BIND_OUT, type: driver.NUMBER } : value
        ]));
        return await connection.execute(sql, parameters, { outFormat: driver.OUT_FORMAT_OBJECT, autoCommit: true });
      }
    };
    const result = mode === '--check' ? await checkSchema(adapter) : await applySchema(adapter);
    output(JSON.stringify({ mode: mode.slice(2), result }));
    if (mode === '--check' && result.some(step => step.status !== 'ready')) throw new Error('Database schema check failed.');
    return result;
  } catch {
    // Driver failures may echo passwords/connect strings. Suppress their raw messages.
    throw new Error('Database migration/check failed; no failed step was marked successful. Review the schema using a secure administrator session.');
  } finally {
    if (connection) {
      try { await connection.close(); }
      catch { throw new Error('Database connection cleanup failed.'); }
    }
  }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await migrateDatabase({ args: process.argv.slice(2) }); }
  catch { console.error('Schema command failed. Use --plan/--check/--apply with optional --dotenv PATH and verify environment, schema compatibility and migration lock permissions. Raw driver diagnostics are suppressed.'); process.exitCode = 1; }
}
