import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deploy, planDeployment, parseDeploymentArgs } from '../scripts/deploy.mjs';

function fixture(fn) {
  const root = mkdtempSync(join(tmpdir(), 'neko-deploy-'));
  writeFileSync(join(root, '.env'), 'ORACLE_PASSWORD=private-fixture\nORACLE_HOST=db.internal\nREDIS_HOST=cache.internal\n');
  try { fn(root); } finally { rmSync(root, { recursive: true, force: true }); }
}

test('planning does not invoke Docker or reveal configuration values', () => fixture(root => {
  const plan = deploy({ root, env: {} }, () => { throw new Error('Docker must not run'); });
  assert.equal(plan.action, 'plan');
  assert(!JSON.stringify(plan).includes('private-fixture'));
}));
test('external mode selects only the app file and forwards the selected environment file', () => fixture(root => {
  const calls = [];
  deploy({ root, env: {}, action: 'up', mode: 'external', project: 'neko-test' }, (command, args, options) => {
    calls.push({ command, args, options }); return { status: 0 };
  });
  assert.equal(calls[0].command, 'docker');
  assert(calls[0].args.includes(join(root, 'docker-compose.external.yml')));
  assert(calls[0].args.includes('neko-test'));
  assert.equal(calls[0].options.env.ENV_FILE, join(root, '.env'));
  assert(!calls[0].args.join(' ').includes('private-fixture'));
}));
test('dependency mode starts just Redis and Oracle without building an app', () => fixture(root => {
  const plan = planDeployment({ root, env: {}, action: 'up', mode: 'dependencies' });
  assert.deepEqual(plan.args.slice(-4), ['up', '-d', 'redis', 'oracle19c']);
  assert(!plan.args.includes('--build'));
}));
test('stop preserves volumes and avoids unrequested services in dependency mode', () => fixture(root => {
  const plan = planDeployment({ root, env: {}, action: 'stop', mode: 'dependencies' });
  assert.deepEqual(plan.args.slice(-3), ['stop', 'redis', 'oracle19c']);
  assert(!plan.args.includes('down'));
}));
test('invalid and duplicate options fail before executing anything', () => {
  assert.throws(() => parseDeploymentArgs(['up', '--mode']));
  assert.throws(() => parseDeploymentArgs(['up', '--reset', 'true']));
  assert.throws(() => parseDeploymentArgs(['up', '--mode', 'source', '--mode', 'image']));
});
test('external mode rejects container-local dependency addresses with canonical environment precedence', () => fixture(root => {
  assert.throws(() => planDeployment({ root, action: 'up', mode: 'external', env: { NUXT_ORACLE_HOST: 'localhost' } }), /External Oracle/);
  assert.throws(() => planDeployment({ root, action: 'up', mode: 'external', env: { NUXT_REDIS_URL: 'redis://127.0.0.1:6379' } }), /External Redis/);
  assert.doesNotThrow(() => planDeployment({ root, action: 'up', mode: 'external', env: { NUXT_ORACLE_HOST: 'host.docker.internal', NUXT_REDIS_HOST: 'host.docker.internal' } }));
}));
test('subprocess failure is reported without dumping private output', () => fixture(root => {
  assert.throws(() => deploy({ root, env: {}, action: 'status' }, () => ({ status: 1, stderr: 'private-fixture' })), /Deployment command failed/);
}));
test('missing environment and unsafe project names are rejected', () => fixture(root => {
  assert.throws(() => planDeployment({ root, env: {}, envFile: 'missing.env' }), /missing or unreadable/);
  assert.throws(() => planDeployment({ root, env: {}, project: 'bad;command' }), /Compose project/);
}));
test('explicit init is separate from up and unavailable for external resources', () => fixture(root => {
  const plan = planDeployment({ root, env: {}, action: 'init-db' });
  assert.deepEqual(plan.args.slice(-5), ['run', '--rm', '-e', 'DB_INIT_ALLOW_EMPTY=true', 'db-init']);
  const up = planDeployment({ root, env: {}, action: 'up' });
  assert(!up.args.includes('DB_INIT_ALLOW_EMPTY=true'));
  assert.throws(() => planDeployment({ root, env: {}, action: 'init-db', mode: 'external' }), /managed externally/);
}));
test('external container mappings use the same canonical environment as validation', () => fixture(root => {
  const plan = planDeployment({ root, action: 'up', mode: 'external', env: { NUXT_ORACLE_HOST: 'remote-db', NUXT_REDIS_URL: 'redis://remote-cache:6379', ACCESS_SECRET: 'shell-fixture-secret' } });
  assert.equal(plan.childEnv.NUXT_ORACLE_HOST, 'remote-db');
  assert.equal(plan.childEnv.ORACLE_HOST, 'remote-db');
  assert.equal(plan.childEnv.NUXT_ACCESS_SECRET, 'shell-fixture-secret');
  const compose = readFileSync(new URL('../docker-compose.external.yml', import.meta.url), 'utf8');
  for (const [key, legacy] of [['NUXT_ORACLE_HOST', 'ORACLE_HOST'], ['NUXT_REDIS_URL', 'REDIS_URL'], ['NUXT_ACCESS_SECRET', 'ACCESS_SECRET']]) {
    assert(compose.includes(`${key}: \${${key}-\${${legacy}-}}`), `Container must consume canonical ${key}, falling back to ${legacy} only if unset`);
  }
}));
test('feature migration is an explicit one-off command and never starts app dependencies', () => fixture(root => {
  for (const mode of ['source', 'image', 'external', 'dependencies']) {
    const plan = planDeployment({ root, env: {}, mode, action: 'migrate-db' });
    assert.deepEqual(plan.args.slice(-5), ['--entrypoint', 'node', 'app', 'scripts/migrate-db.mjs', '--apply']);
    assert(plan.args.includes('--no-deps'));
    assert.equal(plan.args.includes('--build'), mode !== 'image');
    assert(!plan.args.includes('DB_INIT_ALLOW_EMPTY=true'));
  }
  const up = planDeployment({ root, env: {}, action: 'up' });
  assert(!up.args.includes('--apply'));
  const dockerfile = readFileSync(new URL('../Dockerfile', import.meta.url), 'utf8');
  assert(dockerfile.includes('COPY scripts/migrate-db.mjs ./scripts/'));
  assert(dockerfile.includes('RUN node scripts/build-ai-public-terms.mjs'));
  assert(dockerfile.includes('ENV NEKO_TERMS_PACKAGED=1'));
  assert(dockerfile.includes('COPY scripts/ai-public-terms-maintenance.mjs ./scripts/'));
  assert(dockerfile.includes('COPY scripts/ai-skill-config-maintenance.mjs ./scripts/'));
  assert(dockerfile.includes('COPY specifications/requirements/ai-public-terms-catalog.json ./specifications/requirements/'));
  assert(dockerfile.includes('COPY server/database/schema.mjs server/database/schema-definition.mjs ./server/database/'));
}));
