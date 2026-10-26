import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { checkParity } from '../scripts/lib/parity.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
function fixture(run) {
  const workspace = mkdtempSync(join(tmpdir(), 'neko-parity-'));
  const root = join(workspace, 'nuxt');
  const write = (path, value) => {
    const full = join(root, path);
    mkdirSync(join(full, '..'), { recursive: true });
    writeFileSync(full, typeof value === 'string' ? value : JSON.stringify(value));
  };
  const spec = { paths: { '/api/v2/example': { get: { operationId: 'getExample' } } } };
  write('doc/api.json', spec);
  write('server/source.ts', 'export const example = true;');
  const ledger = {
    schemaVersion: 1,
    baseline: { sourceRoots: ['server'], openapi: { path: 'doc/api.json', sha256: sha(readFileSync(join(root, 'doc/api.json'))) },
      sources: [{ path: 'server/source.ts', sha256: sha(readFileSync(join(root, 'server/source.ts'))) }] },
    features: [{ id: 'EXAMPLE', revision: 1, review: 'unreviewed', definition: null, sourceFiles: ['server/source.ts'],
      operations: ['GET /api/v2/example'], scenarios: [],
      implementations: Object.fromEntries(['nuxt', 'rust', 'go'].map(backend => [backend,
        { state: backend === 'rust' ? 'proxy' : 'not-started', targetRevision: 1,
          tasks: ['Implement the example behavior'], evidence: [] }])) }]
  };
  const save = () => write('specifications/parity.json', ledger);
  save();
  try { return run({ root, workspace, write, ledger, save, spec }); }
  finally { rmSync(workspace, { recursive: true, force: true }); }
}

test('development check reports pending work without claiming acceptance', () => fixture(({ root }) => {
  const report = checkParity({ projectRoot: root });
  assert.equal(report.features, 1);
  assert.equal(report.accepted, 0);
  assert.equal(report.ready, false);
  assert.equal(report.pending.length, 1);
}));
test('feature without Go task is rejected', () => fixture(({ root, ledger, save }) => {
  delete ledger.features[0].implementations.go;
  save();
  assert.throws(() => checkParity({ projectRoot: root }), /EXAMPLE.*go.*task/i);
}));
test('every current operation must have exactly one feature owner', () => fixture(({ root, ledger, save }) => {
  ledger.features[0].operations = [];
  save();
  assert.throws(() => checkParity({ projectRoot: root }), /unowned operation.*GET \/api\/v2\/example/i);
}));
test('duplicated operation ownership is rejected', () => fixture(({ root, ledger, save }) => {
  const copy = structuredClone(ledger.features[0]); copy.id = 'OTHER';
  ledger.features.push(copy); save();
  assert.throws(() => checkParity({ projectRoot: root }), /duplicate operation/i);
}));
test('source edits require a reviewed baseline update', () => fixture(({ root, write }) => {
  write('server/source.ts', 'export const example = false;');
  assert.throws(() => checkParity({ projectRoot: root }), /baseline changed.*source.ts/i);
}));
test('adding an untracked source file cannot evade the baseline inventory', () => fixture(({ root, write }) => {
  write('server/new-route.ts', 'export const newRoute = true;');
  assert.throws(() => checkParity({ projectRoot: root }), /source inventory changed/i);
}));
test('JavaScript server handlers are included in source drift checks', () => fixture(({ root, write }) => {
  write('server/new-route.js', 'export default () => 200;');
  assert.throws(() => checkParity({ projectRoot: root }), /source inventory changed/i);
}));
test('Git CRLF conversion does not create a false source drift', () => fixture(({ root, write, ledger, save }) => {
  write('server/source.ts', 'one\ntwo\n');
  ledger.baseline.sources[0].sha256 = sha('one\ntwo\n'); save();
  write('server/source.ts', 'one\r\ntwo\r\n');
  assert.equal(checkParity({ projectRoot: root }).ready, false);
}));
test('contract edits cannot silently leave backend tasks behind', () => fixture(({ root, write, spec }) => {
  spec.paths['/api/v2/new'] = { post: { operationId: 'newExample' } }; write('doc/api.json', spec);
  assert.throws(() => checkParity({ projectRoot: root }), /baseline changed.*api.json/i);
}));
test('a requirement revision must target all three implementations', () => fixture(({ root, ledger, save }) => {
  ledger.features[0].revision = 2; save();
  assert.throws(() => checkParity({ projectRoot: root }), /target revision/i);
}));
test('accepted metadata without evidence cannot turn the gate green', () => fixture(({ root, ledger, save }) => {
  ledger.features[0].implementations.nuxt.state = 'accepted'; save();
  assert.throws(() => checkParity({ projectRoot: root }), /evidence/i);
}));
test('a reviewed feature requires actual requirement and scenario files', () => fixture(({ root, ledger, save }) => {
  ledger.features[0].review = 'reviewed'; ledger.features[0].definition = 'specifications/missing.md'; save();
  assert.throws(() => checkParity({ projectRoot: root }), /missing.md|scenario/i);
}));
test('path traversal is rejected before reading external files', () => fixture(({ root, ledger, save }) => {
  ledger.baseline.sources[0].path = '../private.env'; save();
  assert.throws(() => checkParity({ projectRoot: root }), /relative path/i);
}));
test('release check fails when implementations or requirements remain incomplete', () => fixture(({ root }) => {
  assert.throws(() => checkParity({ projectRoot: root, release: true }), /not ready.*EXAMPLE/i);
}));

function accept(context) {
  const { root, workspace, write, ledger, save } = context;
  const feature = ledger.features[0];
  write('specifications/example.md', 'Example behavior must be identical.');
  write('specifications/example-case.json', { id: 'EXAMPLE-OK', cases: [{ action: 'get', expected: 200 }] });
  feature.review = 'reviewed'; feature.definition = 'specifications/example.md';
  feature.scenarios = [{ id: 'EXAMPLE-OK', file: 'specifications/example-case.json' }];
  for (const backend of ['nuxt', 'rust', 'go']) {
    const component = join(workspace, backend);
    mkdirSync(join(component, 'src'), { recursive: true });
    writeFileSync(join(component, 'src/example.txt'), `${backend} fixture code`);
    const receiptPath = `specifications/evidence/${backend}.json`;
    const sourcePaths = backend === 'nuxt' ? ['src/example.txt', ...feature.sourceFiles] : ['src/example.txt'];
    feature.implementations[backend].sourceFiles = sourcePaths;
    write(receiptPath, { schemaVersion: 1, featureId: feature.id, revision: 1, backend,
      result: 'passed', mode: 'native', nuxtDependency: backend === 'nuxt' ? 'self' : 'blocked',
      requirementsSha256: sha(readFileSync(join(root, feature.definition))),
      scenarios: [{ id: 'EXAMPLE-OK', sha256: sha(readFileSync(join(root, feature.scenarios[0].file))) }],
      sources: sourcePaths.map(path => ({ path, sha256: sha(readFileSync(join(component, path))) })) });
    feature.implementations[backend].state = 'accepted';
    feature.implementations[backend].evidence = [receiptPath];
  }
  save();
}
test('release accepts a fully reviewed feature only with matching native receipts', () => fixture(context => {
  accept(context);
  const report = checkParity({ projectRoot: context.root, workspaceRoot: context.workspace, release: true });
  assert.equal(report.ready, true); assert.equal(report.accepted, 1);
}));
test('Nuxt proxy receipts do not prove independent backend acceptance', () => fixture(context => {
  accept(context);
  const path = 'specifications/evidence/rust.json';
  const receipt = JSON.parse(readFileSync(join(context.root, path)));
  receipt.mode = 'proxy'; context.write(path, receipt);
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }), /native/i);
}));
test('receipt from an earlier requirement cannot be reused', () => fixture(context => {
  accept(context);
  context.write('specifications/example.md', 'Different behavior.');
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }), /requirement.*checksum/i);
}));
test('changed source invalidates recorded acceptance', () => fixture(context => {
  accept(context);
  writeFileSync(join(context.workspace, 'go/src/example.txt'), 'changed implementation');
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }), /source.*checksum/i);
}));
test('receipt cannot omit source files owned by its feature', () => fixture(context => {
  accept(context);
  const path = 'specifications/evidence/nuxt.json';
  const receipt = JSON.parse(readFileSync(join(context.root, path)));
  receipt.sources = receipt.sources.filter(source => source.path !== 'server/source.ts'); context.write(path, receipt);
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }), /source coverage/i);
}));
test('re-pinning a changed source baseline does not preserve old acceptance', () => fixture(context => {
  accept(context);
  context.write('server/source.ts', 'changed feature implementation');
  context.ledger.baseline.sources[0].sha256 = sha('changed feature implementation'); context.save();
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }), /source.*checksum/i);
}));
test('pending legacy or hook audits block release even with accepted v2 operations', () => fixture(context => {
  accept(context);
  context.ledger.sourceAudits = [{ id: 'LEGACY-ONE', source: 'server/source.ts', disposition: 'unreviewed', featureIds: [], reason: '' }];
  context.save();
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace, release: true }), /not ready.*LEGACY-ONE/i);
}));
test('deleting a legacy audit cannot hide an unowned source file', () => fixture(context => {
  context.write('server/legacy.ts', 'legacy source');
  context.ledger.baseline.sources.push({ path: 'server/legacy.ts', sha256: sha('legacy source') });
  context.save();
  assert.throws(() => checkParity({ projectRoot: context.root }), /unowned source.*legacy.ts/i);
}));
test('classified feature audits must be included in the referenced feature evidence scope', () => fixture(context => {
  context.write('server/legacy.ts', 'legacy source');
  context.ledger.baseline.sources.push({ path: 'server/legacy.ts', sha256: sha('legacy source') });
  context.ledger.sourceAudits = [{ id: 'LEGACY-ONE', source: 'server/legacy.ts', disposition: 'alias', featureIds: ['EXAMPLE'], reason: 'Compatibility alias' }];
  context.save();
  assert.throws(() => checkParity({ projectRoot: context.root }), /audit source.*feature.*scope/i);
}));
