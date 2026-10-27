import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, readFileSync, rmdirSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
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
  finally {
    assert(workspace.startsWith(join(tmpdir(), 'neko-parity-')));
    rmSync(workspace, { recursive: true, force: true });
  }
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

function registerTwoFactorCatalog(context) {
  const sourcePaths = ['server/database/schema.mjs', 'server/database/schema-definition.mjs'];
  const sources = sourcePaths.map((path, index) => {
    const content = `// schema source ${index}\n`;
    context.write(path, content);
    context.ledger.baseline.sources.push({ path, sha256: sha(content) });
    context.ledger.features[0].sourceFiles.push(path);
    return { path, sha256: sha(content) };
  });
  const catalogPath = 'specifications/requirements/two-factor-schema-catalog.json';
  const catalog = { id: 'AUTH-2FA-SCHEMA-CATALOG', sources };
  const entry = { source: { path: catalogPath, sha256: '' }, copies: {
    rust: 'contracts/requirements/two-factor-schema-catalog.json',
    go: 'contracts/requirements/two-factor-schema-catalog.json'
  }};
  context.ledger.sharedFiles = [entry];
  const saveCatalog = () => {
    const content = JSON.stringify(catalog);
    context.write(catalogPath, content);
    entry.source.sha256 = sha(content);
    for (const backend of ['rust', 'go']) {
      const copy = join(context.workspace, backend, entry.copies[backend]);
      mkdirSync(join(copy, '..'), { recursive: true });
      writeFileSync(copy, content);
    }
    context.save();
  };
  saveCatalog();
  return { catalog, saveCatalog, sourcePaths };
}

test('registered 2FA catalog accepts its current fixed sources, including CRLF checkout', () => fixture(context => {
  const { sourcePaths } = registerTwoFactorCatalog(context);
  context.write(sourcePaths[0], '// schema source 0\r\n');
  assert.equal(checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }).sharedFiles, 1);
}));

test('registered 2FA catalog rejects schema source drift even when baseline is re-pinned', () => fixture(context => {
  const { sourcePaths } = registerTwoFactorCatalog(context);
  context.write(sourcePaths[0], '// modified schema source\n');
  context.ledger.baseline.sources.find(item => item.path === sourcePaths[0]).sha256 = sha('// modified schema source\n');
  context.save();
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }), /catalog.*source/i);
}));

for (const [name, alter] of [
  ['missing source', sources => sources.pop()],
  ['duplicate source', sources => { sources[1] = structuredClone(sources[0]); }],
  ['extra source', sources => sources.push({path: 'server/source.ts', sha256: sha('export const example = true;')})],
  ['external source', sources => { sources[1].path = '../private.env'; }],
  ['invalid hash', sources => { sources[1].sha256 = 'invalid'; }]
]) {
  test(`registered 2FA catalog rejects ${name}`, () => fixture(context => {
    const { catalog, saveCatalog } = registerTwoFactorCatalog(context);
    alter(catalog.sources);
    saveCatalog();
    assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }), /catalog.*source/i);
  }));
}
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
  write('specifications/requirements/example.md', 'Example behavior must be identical.');
  write('specifications/scenarios/example-case.json', { id: 'EXAMPLE-OK', cases: [{ action: 'get', expected: 200 }] });
  feature.review = 'reviewed'; feature.definition = 'specifications/requirements/example.md';
  feature.scenarios = [{ id: 'EXAMPLE-OK', file: 'specifications/scenarios/example-case.json' }];
  ledger.sharedFiles = [feature.definition, feature.scenarios[0].file].map(path => {
    const content = readFileSync(join(root, path));
    const copy = path.replace(/^specifications\//, 'contracts/');
    for (const backend of ['rust', 'go']) {
      const destination = join(workspace, backend, copy);
      mkdirSync(join(destination, '..'), { recursive: true });
      writeFileSync(destination, content);
    }
    return { source: { path, sha256: sha(content) }, copies: { rust: copy, go: copy } };
  });
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
test('reviewed requirement must be registered for both backends', () => fixture(context => {
  accept(context);
  context.ledger.sharedFiles = context.ledger.sharedFiles.filter(entry => entry.source.path !== context.ledger.features[0].definition);
  context.save();
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace, release: true }),
    /EXAMPLE.*requirement.*shared/i);
}));
test('reviewed scenario must be registered for both backends', () => fixture(context => {
  accept(context);
  context.ledger.sharedFiles = context.ledger.sharedFiles.filter(entry => entry.source.path !== context.ledger.features[0].scenarios[0].file);
  context.save();
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace, release: true }),
    /EXAMPLE.*scenario.*shared/i);
}));

test('reviewed feature rejects an unregistered shared dependency', () => fixture(context => {
  accept(context);
  context.ledger.features[0].sharedDependencies = ['specifications/requirements/catalog.json'];
  context.save();
  assert.throws(() => checkParity({projectRoot: context.root, workspaceRoot: context.workspace}), /shared dependency/i);
}));

test('accepted feature requires evidence for every shared dependency', () => fixture(context => {
  accept(context);
  const path = 'specifications/requirements/catalog.json';
  const content = 'shared catalog version one';
  context.write(path, content);
  for (const backend of ['rust', 'go']) {
    const copy = join(context.workspace, backend, 'contracts/requirements/catalog.json');
    mkdirSync(join(copy, '..'), {recursive: true});
    writeFileSync(copy, content);
  }
  context.ledger.sharedFiles.push({source: {path, sha256: sha(content)}, copies: {
    rust: 'contracts/requirements/catalog.json', go: 'contracts/requirements/catalog.json'
  }});
  context.ledger.features[0].sharedDependencies = [path];
  context.save();
  assert.throws(() => checkParity({projectRoot: context.root, workspaceRoot: context.workspace, release: true}), /dependency.*evidence/i);
  for (const backend of ['nuxt', 'rust', 'go']) {
    const receiptPath = `specifications/evidence/${backend}.json`;
    const receipt = JSON.parse(readFileSync(join(context.root, receiptPath), 'utf8'));
    receipt.dependencies = [{path, sha256: sha(content)}];
    context.write(receiptPath, receipt);
  }
  assert.equal(checkParity({projectRoot: context.root, workspaceRoot: context.workspace, release: true}).ready, true);
  context.ledger.features[0].sharedDependencies = [];
  context.save();
  assert.throws(() => checkParity({projectRoot: context.root, workspaceRoot: context.workspace, release: true}), /dependency.*evidence/i);
  context.ledger.features[0].sharedDependencies = [path];
  const changed = 'shared catalog version two';
  context.write(path, changed);
  for (const backend of ['rust', 'go']) writeFileSync(join(context.workspace, backend, 'contracts/requirements/catalog.json'), changed);
  context.ledger.sharedFiles.find(entry => entry.source.path === path).source.sha256 = sha(changed);
  context.save();
  assert.throws(() => checkParity({projectRoot: context.root, workspaceRoot: context.workspace, release: true}), /dependency.*checksum/i);
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
  const path = context.ledger.features[0].definition;
  context.write(path, 'Different behavior.');
  const entry = context.ledger.sharedFiles.find(item => item.source.path === path);
  entry.source.sha256 = sha('Different behavior.');
  for (const backend of ['rust', 'go']) writeFileSync(join(context.workspace, backend, entry.copies[backend]), 'Different behavior.');
  context.save();
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

function sharedFiles(context) {
  context.write('specifications/scenarios/shared.json', '{"case":"current"}\n');
  const hash = sha('{"case":"current"}\n');
  for (const backend of ['rust', 'go']) {
    mkdirSync(join(context.workspace, backend, 'contracts/scenarios'), { recursive: true });
    writeFileSync(join(context.workspace, backend, 'contracts/scenarios/shared.json'), '{"case":"current"}\n');
  }
  context.ledger.sharedFiles = [{ source: { path: 'specifications/scenarios/shared.json', sha256: hash },
    copies: { rust: 'contracts/scenarios/shared.json', go: 'contracts/scenarios/shared.json' } }];
  context.save();
}
test('workspace checks verify versioned shared requirement and scenario copies', () => fixture(context => {
  sharedFiles(context);
  const report = checkParity({ projectRoot: context.root, workspaceRoot: context.workspace });
  assert.equal(report.sharedFiles, 1);
}));
test('Go cannot keep an old scenario while Nuxt changes its requirement baseline', () => fixture(context => {
  sharedFiles(context);
  writeFileSync(join(context.workspace, 'go/contracts/scenarios/shared.json'), '{"case":"old"}\n');
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }), /shared.*copy.*go/i);
}));
test('shared source changes require an explicit reviewed hash update', () => fixture(context => {
  sharedFiles(context);
  context.write('specifications/scenarios/shared.json', '{"case":"changed"}\n');
  assert.throws(() => checkParity({ projectRoot: context.root }), /shared.*source/i);
}));
test('shared file mapping cannot read outside component contracts', () => fixture(context => {
  sharedFiles(context);
  context.ledger.sharedFiles[0].copies.go = '../private.env'; context.save();
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }), /shared.*path|relative path/i);
}));
test('shared copies cannot follow a contracts link into private component files', () => fixture(context => {
  sharedFiles(context);
  const directory = join(context.workspace, 'go/contracts/scenarios');
  const privateDirectory = join(context.workspace, 'go/private-data');
  mkdirSync(privateDirectory);
  writeFileSync(join(privateDirectory, 'shared.json'), '{"case":"current"}\n');
  unlinkSync(join(directory, 'shared.json')); rmdirSync(directory);
  symlinkSync(privateDirectory, directory, process.platform === 'win32' ? 'junction' : 'dir');
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }), /escapes|symlink/i);
}));
test('shared sources cannot redirect a public requirement directory into private files', () => fixture(context => {
  sharedFiles(context);
  const directory = join(context.root, 'specifications/scenarios');
  const privateDirectory = join(context.root, 'private-data');
  mkdirSync(privateDirectory);
  writeFileSync(join(privateDirectory, 'shared.json'), '{"case":"current"}\n');
  unlinkSync(join(directory, 'shared.json')); rmdirSync(directory);
  symlinkSync(privateDirectory, directory, process.platform === 'win32' ? 'junction' : 'dir');
  assert.throws(() => checkParity({ projectRoot: context.root, workspaceRoot: context.workspace }), /escapes|symlink/i);
}));
