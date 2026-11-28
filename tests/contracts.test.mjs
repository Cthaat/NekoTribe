import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../scripts/contracts.mjs', import.meta.url));
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'neko-contracts-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const path of ['nuxt/doc', 'nuxt/server/api/v2/items', 'rust/contracts', 'flutter/contracts', 'go/contracts']) {
    mkdirSync(join(root, path), { recursive: true });
  }
  const spec = { openapi: '3.0.1', info: { version: '2.0.0' }, paths: {
    '/api/v2/items/{id}': { get: { operationId: 'getItem', parameters: [{ in: 'path', name: 'id', required: true, schema: { type: 'string' } }], responses: { 200: { description: 'OK' } } } }
  } };
  writeFileSync(join(root, 'nuxt/doc/v2.openapi.json'), JSON.stringify(spec) + '\n');
  writeFileSync(join(root, 'nuxt/doc/runtime-addresses.md'), '# Addresses\n');
  writeFileSync(join(root, 'nuxt/server/api/v2/items/[id].get.ts'), 'export default defineEventHandler(() => ({}));\n');
  for (const path of [
    'start-native.mjs', 'package-native.mjs', 'check-deployment-endpoints.mjs',
    'release/native/start.cmd', 'release/native/start.sh',
    'source/native/start.cmd', 'source/native/start.sh'
  ]) {
    const target = join(root, 'nuxt/scripts', path);
    mkdirSync(dirname(target), { recursive: true });
    cpSync(new URL(`../scripts/${path}`, import.meta.url), target);
  }
  const git = (...args) => execFileSync('git', ['-c', `safe.directory=${join(root, 'nuxt')}`, '-C', join(root, 'nuxt'), ...args], { stdio: 'pipe' });
  git('init', '-b', 'master');
  git('add', '.');
  git('-c', 'user.name=Contract Test', '-c', 'user.email=contracts@example.invalid', 'commit', '-m', 'fixture');
  const run = (...args) => spawnSync(process.execPath, [script, ...args], { cwd: join(root, 'nuxt'), encoding: 'utf8' });
  return { root, run, git };
}
function synced(t) {
  const value = fixture(t);
  const result = value.run('sync', '--workspace-root', value.root);
  assert.equal(result.status, 0, result.stderr);
  return value;
}

test('sync is explicit and check works offline with only the Nuxt checkout', (t) => {
  const { root, run } = synced(t);
  for (const project of ['rust', 'flutter', 'go']) rmSync(join(root, project), { recursive: true });
  rmSync(join(root, 'nuxt/.git'), { recursive: true });
  assert.equal(run('check').status, 0);
  assert.notEqual(run('sync').status, 0);
  assert.notEqual(run('check', '--workspace-root', root).status, 0);
});

test('detached sync records provenance and preserves launcher line endings', t => {
  const { root, run, git } = fixture(t);
  git('checkout', '--detach', 'HEAD');
  const result = run('sync', '--workspace-root', root);
  assert.equal(result.status, 0, result.stderr);
  const { source } = JSON.parse(readFileSync(join(root, 'nuxt/doc/contracts.manifest.json')));
  assert.equal(source.branch, 'HEAD');
  assert.equal(source.commit, git('rev-parse', 'HEAD').toString().trim());
  for (const project of ['rust', 'go']) {
    for (const prefix of ['', 'scripts/release/native/']) {
      const cmd = readFileSync(join(root, project, prefix + 'start.cmd'), 'utf8');
      assert.match(cmd, /\r\n/);
      assert.doesNotMatch(cmd.replaceAll('\r\n', ''), /[\r\n]/);
      assert.doesNotMatch(readFileSync(join(root, project, prefix + 'start.sh'), 'utf8'), /\r/);
    }
  }
  assert.equal(run('check', '--workspace-root', root).status, 0);
});

test('workspace root lookup accepts alternate Windows path casing', {skip:process.platform !== 'win32'}, (t) => {
  const { root, run } = fixture(t);
  const alias = root.toUpperCase();
  const sync = run('sync', '--workspace-root', alias);
  assert.equal(sync.status, 0, sync.stderr);
  const result = run('check', '--workspace-root', alias);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).scope, 'workspace');
});

test('workspace check rejects a changed copy and a missing addresses file', (t) => {
  const { root, run } = synced(t);
  writeFileSync(join(root, 'rust/contracts/v2.openapi.json'), '{}\n');
  assert.match(run('check', '--workspace-root', root).stderr, /rust.*(hash|bytes)/i);
  cpSync(join(root, 'nuxt/doc/v2.openapi.json'), join(root, 'rust/contracts/v2.openapi.json'));
  rmSync(join(root, 'go/contracts/runtime-addresses.md'));
  assert.match(run('check', '--workspace-root', root).stderr, /runtime-addresses.md/);
});

test('check rejects wrong authority, source paths, version and content drift', (t) => {
  const { root, run } = synced(t);
  const path = join(root, 'nuxt/doc/contracts.manifest.json');
  const original = readFileSync(path, 'utf8');
  for (const mutate of [
    (m) => { m.authority = 'Rust'; },
    (m) => { m.files[0].sourcePath = '../elsewhere.json'; },
    (m) => { m.contractVersion = '9.0'; },
    (m) => { m.revision = 'stale-revision'; },
    (m) => { m.files[0].gitBlob = '0'.repeat(40); }
  ]) {
    const manifest = JSON.parse(original);
    mutate(manifest);
    writeFileSync(path, JSON.stringify(manifest) + '\n');
    assert.notEqual(run('check').status, 0);
  }
  writeFileSync(path, original);
  writeFileSync(join(root, 'nuxt/doc/runtime-addresses.md'), '# Changed\n');
  assert.match(run('check').stderr, /hash/i);
});

test('check rejects CRLF, unresolved refs, duplicate operationIds and missing path parameters', (t) => {
  const { root, run } = synced(t);
  const path = join(root, 'nuxt/doc/v2.openapi.json');
  const original = readFileSync(path, 'utf8');
  const mutations = [
    (s) => { s.paths['/api/v2/items/{id}'].get.parameters = []; },
    (s) => { s.paths['/api/v2/items/{id}'].get.responses[200].$ref = '#/missing'; },
    (s) => { s.paths['/api/v2/items/{id}'].post = s.paths['/api/v2/items/{id}'].get; }
  ];
  for (const mutate of mutations) {
    const spec = JSON.parse(original);
    mutate(spec);
    writeFileSync(path, JSON.stringify(spec) + '\n');
    assert.notEqual(run('sync', '--workspace-root', root).status, 0);
  }
  writeFileSync(path, original.replaceAll('\n', '\r\n'));
  assert.match(run('check').stderr, /LF/);
});

test('sync refuses undocumented routes and never creates missing project directories', (t) => {
  const { root, run } = synced(t);
  writeFileSync(join(root, 'nuxt/server/api/v2/new.post.ts'), 'export default {};\n');
  assert.match(run('sync', '--workspace-root', root).stderr, /undocumented.*POST.*new/i);
  rmSync(join(root, 'nuxt/server/api/v2/new.post.ts'));
  rmSync(join(root, 'go'), { recursive: true });
  assert.notEqual(run('sync', '--workspace-root', root).status, 0);
});

test('sync records exact Git provenance for an uncommitted LF-normalized snapshot', (t) => {
  const { root, run, git } = fixture(t);
  const path = join(root, 'nuxt/doc/v2.openapi.json');
  const spec = JSON.parse(readFileSync(path, 'utf8'));
  spec.info.description = 'Reviewed uncommitted contract';
  writeFileSync(path, JSON.stringify(spec, null, 2).replaceAll('\n', '\r\n') + '\r\n');
  assert.equal(run('sync', '--workspace-root', root).status, 0);
  assert.equal(readFileSync(path).includes(13), false);
  const manifest = JSON.parse(readFileSync(join(root, 'nuxt/doc/contracts.manifest.json')));
  const file = manifest.files[0];
  assert.equal(file.gitBlob, git('hash-object', 'doc/v2.openapi.json').toString().trim());
  assert.equal(file.committedSource.gitBlob, git('rev-parse', 'HEAD:doc/v2.openapi.json').toString().trim());
  assert.equal(file.committedSource.commit, git('rev-parse', 'HEAD').toString().trim());
  assert.equal(file.differsFromCommittedSource, true);
  assert.equal(manifest.files[1].differsFromCommittedSource, false);
  assert.equal(run('check', '--workspace-root', root).status, 0);
});

test('check names a missing source file and sync rejects incorrect implementation attribution', (t) => {
  const { root, run } = synced(t);
  const path = join(root, 'nuxt/doc/v2.openapi.json');
  const spec = JSON.parse(readFileSync(path));
  spec.paths['/api/v2/items/{id}'].get['x-implementation-source'] = 'server/api/v2/other.get.ts';
  writeFileSync(path, JSON.stringify(spec) + '\n');
  assert.match(run('sync', '--workspace-root', root).stderr, /Wrong implementation source/);
  rmSync(join(root, 'nuxt/doc/runtime-addresses.md'));
  assert.match(run('check').stderr, /runtime-addresses.md/);
});

test('sync rejects OAS 3.0 invalid Schema Object types without scanning example data as schemas', (t) => {
  const { root, run } = synced(t);
  const path = join(root, 'nuxt/doc/v2.openapi.json');
  const original = JSON.parse(readFileSync(path));
  for (const invalid of [{ type: 'null' }, { type: ['string', 'null'] }, { type: 'array' }, { type: 'array', items: 'string' }]) {
    const spec = structuredClone(original);
    spec.paths['/api/v2/items/{id}'].get.responses[200].content = { 'application/json': { schema: invalid } };
    writeFileSync(path, JSON.stringify(spec) + '\n');
    assert.match(run('sync', '--workspace-root', root).stderr, /Invalid.*(type|array)/);
  }
  const spec = structuredClone(original);
  spec.paths['/api/v2/items/{id}'].get.responses[200].content = {
    'application/json': { schema: { type: 'object', nullable: true, enum: [null] }, example: { type: 'null' } }
  };
  writeFileSync(path, JSON.stringify(spec) + '\n');
  assert.equal(run('sync', '--workspace-root', root).status, 0);
});

test('sync refuses invalid UTF-8 instead of silently rewriting source bytes', (t) => {
  const { root, run } = synced(t);
  const path = join(root, 'nuxt/doc/runtime-addresses.md');
  writeFileSync(path, Buffer.from([0x23, 0x20, 0xff, 0x0a]));
  assert.match(run('sync', '--workspace-root', root).stderr, /invalid UTF-8/);
  assert.deepEqual(readFileSync(path), Buffer.from([0x23, 0x20, 0xff, 0x0a]));
});
