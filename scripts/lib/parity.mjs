import { closeSync, lstatSync, openSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import {buildPublicTermsCatalog,checkPublicTermsPage} from './ai-public-terms-catalog.mjs';

const backends = ['nuxt', 'rust', 'go'];
const clients = ['nuxtWeb', 'flutter'];
const states = new Set(['not-started', 'in-progress', 'proxy', 'implemented', 'accepted']);
const methods = new Set(['get', 'post', 'put', 'patch', 'delete', 'head', 'options', 'trace']);
const ensure = (condition, message) => { if (!condition) throw new Error(message); };
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const nonempty = value => typeof value === 'string' && value.trim().length > 0;
const realPath = realpathSync.native;

function relativePath(path) {
  ensure(nonempty(path) && !isAbsolute(path) && !path.includes('\\') &&
    path.split('/').every(part => part && part !== '..' && part !== '.') && !path.includes(':'), `Invalid relative path: ${path}`);
}
function inside(root, path) {
  relativePath(path);
  const absolute = resolve(root, path);
  const actual = realPath(absolute);
  const delta = relative(realPath(root), actual);
  ensure(delta && delta !== '..' && !delta.startsWith(`..${sep}`) && !isAbsolute(delta), `Path escapes project: ${path}`);
  return actual;
}
function file(root, path) { return readFileSync(inside(root, path)); }
function publicDirectory(root, path) {
  relativePath(path);
  let directory = root;
  for (const part of path.split('/')) {
    directory = resolve(directory, part);
    ensure(!lstatSync(directory).isSymbolicLink(), 'Shared public directory cannot be a symlink');
  }
  return inside(root, path);
}
function json(root, path) { return JSON.parse(file(root, path).toString('utf8')); }
function checksum(root, entry, description, normalize = false) {
  ensure(entry && /^[a-f0-9]{64}$/.test(entry.sha256), `${description}: invalid checksum`);
  const bytes = file(root, entry.path);
  if (normalize) ensure(Buffer.from(bytes.toString('utf8')).equals(bytes), `${description}: invalid UTF-8`);
  ensure(digest(normalize ? bytes.toString('utf8').replaceAll('\r\n', '\n') : bytes) === entry.sha256, `${description}: ${entry.path}`);
}

function checkTwoFactorCatalogSources(root, path) {
  if (path !== 'specifications/requirements/two-factor-schema-catalog.json') return;
  const catalog = json(root, path);
  const expected = new Set(['server/database/schema.mjs', 'server/database/schema-definition.mjs']);
  const sources = catalog?.sources;
  ensure(catalog?.id === 'AUTH-2FA-SCHEMA-CATALOG' && Array.isArray(sources) && sources.length === expected.size &&
    sources.every(source => expected.has(source?.path)) && new Set(sources.map(source => source.path)).size === expected.size,
  '2FA catalog sources must contain the two fixed schema source paths exactly once');
  for (const source of sources) checksum(root, source, '2FA catalog source changed; regenerate the catalog', true);
}

function checkSharedSource(root, path) {
  checkTwoFactorCatalogSources(root, path);
  if (path === 'specifications/requirements/ai-public-terms-catalog.json') {
    checkPublicTermsPage(file(root, 'app/pages/auth/terms.vue').toString('utf8'));
    const generated = buildPublicTermsCatalog({ zh: json(root, 'i18n/locales/zh.json'), en: json(root, 'i18n/locales/en.json') });
    ensure(JSON.stringify(json(root, path)) === JSON.stringify(generated), 'Public terms catalog is stale; regenerate and review shared copies');
  }
}

function sharedCopies(root, workspaceRoot, entries) {
  ensure(Array.isArray(entries), 'Shared file registry must be an array');
  unique(entries.map(entry => entry?.source?.path), 'Shared sources');
  for (const entry of entries) {
    const source = entry?.source;
    relativePath(source?.path);
    const sourceDirectory = source.path.startsWith('specifications/requirements/') ? 'specifications/requirements' :
      source.path.startsWith('specifications/scenarios/') ? 'specifications/scenarios' : null;
    ensure(sourceDirectory, 'Invalid shared source path');
    checksum(publicDirectory(root, sourceDirectory), { path: source.path.slice(sourceDirectory.length + 1), sha256: source.sha256 },
      'Shared source changed; review requirements before re-pinning', true);
    checkSharedSource(root, source.path);
    const copies = entry.copies;
    ensure(copies && typeof copies === 'object' && !Array.isArray(copies) && copies.rust && copies.go &&
      Object.keys(copies).every(backend => ['rust', 'go', 'flutter'].includes(backend)), 'Shared copies must include Rust and Go');
    for (const [backend, path] of Object.entries(copies)) {
      relativePath(path);
      ensure(path.startsWith('contracts/'), 'Invalid shared copy path');
      if (workspaceRoot) checksum(publicDirectory(resolve(workspaceRoot, backend), 'contracts'),
        { path: path.slice('contracts/'.length), sha256: source.sha256 }, `Shared copy mismatch: ${backend}`, true);
    }
  }
  return entries.length;
}

function plainFileSnapshot(path) {
  const stat = lstatSync(path, { throwIfNoEntry: false });
  if (!stat) return null;
  ensure(stat.isFile(), `Shared path must be a regular file: ${path}`);
  return readFileSync(path);
}

function normalizedText(bytes, path) {
  const text = bytes.toString('utf8');
  ensure(Buffer.from(text).equals(bytes) && !text.startsWith('\uFEFF'), `Invalid shared UTF-8 file: ${path}`);
  return text.replaceAll('\r\n', '\n');
}

export function syncSharedFiles({ projectRoot, workspaceRoot, paths }) {
  ensure(workspaceRoot, '--workspace-root is required for sync-shared');
  const workspace = realPath(workspaceRoot);
  const root = publicDirectory(workspace, 'nuxt');
  ensure(realPath(projectRoot) === root, '--workspace-root must contain this Nuxt project');
  strings(paths, 'Selected shared paths');
  ensure(paths.length > 0, 'At least one --shared path is required');
  unique(paths, 'Selected shared paths');
  const registryPath = resolve(publicDirectory(root, 'specifications'), 'parity.json');
  const registry = plainFileSnapshot(registryPath);
  ensure(registry, 'Parity registry not found');
  const registryText = normalizedText(registry, registryPath);
  const ledger = JSON.parse(registryText);
  ensure(ledger.schemaVersion === 1 && Array.isArray(ledger.sharedFiles), 'Invalid shared file registry');
  unique(ledger.sharedFiles.map(entry => entry?.source?.path), 'Shared sources');

  const writes = [];
  const inputs = [];
  let changedHashes = 0;
  for (const path of paths) {
    relativePath(path);
    const match = /^specifications\/(requirements|scenarios)\/([^/]+\.(?:json|md))$/.exec(path);
    ensure(match, `Invalid shared source path: ${path}`);
    const entry = ledger.sharedFiles.find(row => row.source?.path === path);
    ensure(entry, `Shared path is not registered: ${path}`);
    const oldHash = entry.source.sha256;
    ensure(oldHash === undefined || /^[a-f0-9]{64}$/.test(oldHash), `Invalid previous checksum: ${path}`);
    const sourcePath = resolve(publicDirectory(root, `specifications/${match[1]}`), match[2]);
    const original = plainFileSnapshot(sourcePath);
    ensure(original, `Missing shared source: ${path}`);
    inputs.push({ path: sourcePath, before: original });
    const contents = normalizedText(original, path);
    if (path.endsWith('.json')) {
      try { JSON.parse(contents); }
      catch { throw new Error(`Invalid shared JSON: ${path}`); }
    }
    checkSharedSource(root, path);
    const sha256 = digest(contents);

    const entries = Object.entries(entry.copies ?? {});
    const copyPath = `contracts/${match[1]}/${match[2]}`;
    ensure(entries.some(([stack]) => stack === 'go') && entries.some(([stack]) => stack === 'rust') &&
      entries.every(([stack, target]) => ['go', 'rust', 'flutter'].includes(stack) && target === copyPath),
    `Invalid shared copy mapping: ${path}`);
    for (const [stack] of entries) {
      const folder = publicDirectory(workspace, `${stack}/contracts/${match[1]}`);
      const destination = resolve(folder, match[2]);
      const before = plainFileSnapshot(destination);
      const previous = before === null ? null : digest(normalizedText(before, `${stack}/${copyPath}`));
      ensure(previous === null || previous === sha256 || previous === oldHash,
        `Local edits in ${stack}/${copyPath}; reconcile this copy before syncing`);
      if (previous !== sha256) writes.push({ path: destination, before, contents });
      else inputs.push({ path: destination, before });
    }
    if (oldHash !== sha256) {
      entry.source.sha256 = sha256;
      changedHashes++;
    }
  }
  const copiedFiles = writes.length;
  if (changedHashes) {
    const next = JSON.stringify(ledger, null, 2) + '\n';
    const contents = registry.includes(13) ? next.replaceAll('\n', '\r\n') : next;
    writes.push({ path: registryPath, before: registry, contents });
  } else {
    inputs.push({ path: registryPath, before: registry });
  }
  if (!writes.length) return { selectedFiles: paths.length, copiedFiles, changedHashes };
  const lockPath = resolve(dirname(registryPath), '.parity-sync.lock');
  let lock;
  try {
    lock = openSync(lockPath, 'wx');
  } catch (error) {
    if (error.code === 'EEXIST') throw new Error('Shared sync is already locked (specifications/.parity-sync.lock)');
    throw error;
  }
  const staged = [];
  try {
    writeFileSync(lock, `${process.pid}\n`);
    for (const write of writes) {
      const temporary = resolve(dirname(write.path), `.parity-${randomUUID()}.tmp`);
      const fd = openSync(temporary, 'wx');
      staged.push({ ...write, temporary });
      try { writeFileSync(fd, write.contents); }
      finally { closeSync(fd); }
    }
    for (const { path, before } of [...inputs, ...writes]) {
      const current = plainFileSnapshot(path);
      ensure(before === null ? current === null : current?.equals(before), `Shared file changed during sync: ${path}`);
    }
    // Publish the registry last so interrupted copies can be retried using the previous hashes.
    for (const { path, temporary } of staged) renameSync(temporary, path);
  } finally {
    try {
      for (const { temporary } of staged) rmSync(temporary, { force: true });
    } finally {
      closeSync(lock);
      rmSync(lockPath, { force: true });
    }
  }
  return { selectedFiles: paths.length, copiedFiles, changedHashes };
}
function sourceInventory(root, directory) {
  return readdirSync(inside(root, directory), { withFileTypes: true }).flatMap(item => {
    const path = `${directory}/${item.name}`;
    ensure(!item.isSymbolicLink(), `Source inventory does not follow symlinks: ${path}`);
    return item.isDirectory() ? sourceInventory(root, path) : /\.(ts|mts|cts|mjs|cjs|js|tsx|jsx|json|sql)$/.test(item.name) ? [path] : [];
  });
}
function strings(values, description) {
  ensure(Array.isArray(values) && values.every(nonempty), `${description}: expected nonempty strings`);
}
function unique(values, description) {
  ensure(new Set(values).size === values.length, `${description}: duplicate value`);
}

function checkReceipt(projectRoot, workspaceRoot, feature, backend, implementation, path) {
  const receipt = json(projectRoot, path);
  ensure(receipt.schemaVersion === 1 && receipt.featureId === feature.id && receipt.revision === feature.revision &&
    receipt.backend === backend && receipt.result === 'passed', `${feature.id}/${backend}: evidence identity or revision mismatch`);
  ensure(receipt.mode === 'native' && receipt.nuxtDependency === (backend === 'nuxt' ? 'self' : 'blocked'),
    `${feature.id}/${backend}: independent native evidence required`);
  checkRequirementEvidence(projectRoot, feature, receipt, `${feature.id}/${backend}`);
  ensure(backend === 'nuxt' || workspaceRoot, `${feature.id}/${backend}: --workspace-root required to verify accepted sources`);
  const componentRoot = backend === 'nuxt' ? projectRoot : resolve(workspaceRoot, backend);
  ensure(Array.isArray(receipt.sources) && receipt.sources.length > 0, `${feature.id}/${backend}: source evidence required`);
  unique(receipt.sources.map(source => source.path), 'Evidence sources');
  strings(implementation.sourceFiles, `${feature.id}/${backend}: implementation source files`);
  ensure(implementation.sourceFiles.length > 0, `${feature.id}/${backend}: implementation source coverage required`);
  const requiredSources = backend === 'nuxt' ? [...feature.sourceFiles, ...implementation.sourceFiles] : implementation.sourceFiles;
  ensure(requiredSources.every(source => receipt.sources.some(recorded => recorded.path === source)),
    `${feature.id}/${backend}: evidence source coverage is incomplete`);
  for (const source of receipt.sources) checksum(componentRoot, source, `${feature.id}/${backend}: source checksum mismatch`);
}

function checkRequirementEvidence(projectRoot, feature, receipt, label) {
  ensure(nonempty(feature.definition) && digest(file(projectRoot, feature.definition)) === receipt.requirementsSha256,
    `${label}: requirement checksum mismatch`);
  ensure(Array.isArray(receipt.scenarios), `${label}: evidence scenarios required`);
  unique(receipt.scenarios.map(scenario => scenario.id), 'Evidence scenarios');
  const expected = feature.scenarios.map(scenario => scenario.id).sort();
  ensure(JSON.stringify(receipt.scenarios.map(scenario => scenario.id).sort()) === JSON.stringify(expected),
    `${label}: evidence must cover all current scenarios`);
  for (const scenario of feature.scenarios) {
    const recorded = receipt.scenarios.find(item => item.id === scenario.id);
    ensure(recorded.sha256 === digest(file(projectRoot, scenario.file)), `${label}: scenario checksum mismatch`);
  }
  const dependencies = feature.sharedDependencies ?? [];
  if (dependencies.length || receipt.dependencies !== undefined) {
    ensure(Array.isArray(receipt.dependencies), `${label}: shared dependency evidence required`);
    unique(receipt.dependencies.map(item => item.path), 'Evidence dependencies');
    ensure(JSON.stringify(receipt.dependencies.map(item => item.path).sort()) === JSON.stringify([...dependencies].sort()),
      `${label}: dependency evidence must cover every shared dependency`);
    for (const dependency of receipt.dependencies) checksum(projectRoot, dependency,
      `${label}: dependency evidence checksum mismatch`);
  }
}

function clientPath(componentRoot, path, prefixes, label) {
  relativePath(path);
  ensure(prefixes.some(prefix => path.startsWith(prefix)), `${label}: invalid client source path: ${path}`);
  if (componentRoot) {
    const actual = relative(realPath(componentRoot), inside(componentRoot, path)).split(sep).join('/');
    ensure(prefixes.some(prefix => actual.startsWith(prefix)), `${label}: client source path redirects outside its scope: ${path}`);
    file(componentRoot, path);
  }
}

function checkClientReceipt(root, workspaceRoot, feature, client, implementation, path) {
  const label = `${feature.id}/client/${client}`;
  relativePath(path);
  ensure(path.startsWith('specifications/evidence/'), `${label}: invalid client evidence path`);
  const receipt = json(root, path);
  ensure(receipt.schemaVersion === 1 && receipt.featureId === feature.id && receipt.revision === feature.revision &&
    receipt.client === client && receipt.result === 'passed', `${label}: client evidence identity or revision mismatch`);
  checkRequirementEvidence(root, feature, receipt, label);
  ensure(Array.isArray(receipt.backends), `${label}: client backend matrix required`);
  unique(receipt.backends.map(row => row.backend), 'Client backend matrix');
  ensure(JSON.stringify(receipt.backends.map(row => row.backend).sort()) === JSON.stringify([...backends].sort()),
    `${label}: client backend matrix must cover nuxt/rust/go`);
  for (const row of receipt.backends) {
    const backend = feature.implementations[row.backend];
    ensure(backend.state === 'accepted', `${label}: client requires current native backend acceptance: ${row.backend}`);
    ensure(nonempty(row.backendReceipt) && backend.evidence.includes(row.backendReceipt), `${label}: unregistered client backend receipt`);
    ensure(row.result === 'passed' && nonempty(row.command), `${label}: client backend execution result and command required`);
  }
  ensure(client === 'nuxtWeb' || workspaceRoot, `${label}: --workspace-root required to verify Flutter sources`);
  const component = client === 'nuxtWeb' ? root : resolve(workspaceRoot, 'flutter');
  ensure(Array.isArray(receipt.sources) && receipt.sources.length > 0, `${label}: client source evidence required`);
  unique(receipt.sources.map(source => source.path), 'Client evidence sources');
  ensure([...implementation.sourceFiles, ...implementation.testFiles].every(path => receipt.sources.some(source => source.path === path)),
    `${label}: client source coverage is incomplete`);
  const prefixes = client === 'nuxtWeb' ? ['app/', 'i18n/', 'tests/', 'e2e/'] : ['lib/', 'test/', 'integration_test/'];
  for (const source of receipt.sources) {
    clientPath(component, source.path, prefixes, label);
    checksum(component, source, `${label}: client source checksum mismatch`);
  }
}

function checkClients(root, workspaceRoot, feature, pending) {
  const scope = feature.clientScope;
  ensure(scope && ['required', 'not-required', 'unreviewed'].includes(scope.state), `${feature.id}: explicit client scope required`);
  ensure(nonempty(scope.reason), `${feature.id}: client scope reason required`);
  if (scope.state !== 'required') {
    ensure(feature.clients === undefined || (feature.clients && typeof feature.clients === 'object' && !Array.isArray(feature.clients) && Object.keys(feature.clients).length === 0),
      `${feature.id}: client scope cannot hide implementations`);
    if (scope.state === 'not-required') return true;
    strings(scope.tasks, `${feature.id}: client scope review tasks`);
    ensure(scope.tasks.length > 0, `${feature.id}: client scope review task required`);
    pending.push(`${feature.id}:scope`);
    return false;
  }
  ensure(feature.clients && Object.keys(feature.clients).length === clients.length && clients.every(client => feature.clients[client]),
    `${feature.id}: both nuxtWeb and flutter client implementations required`);
  for (const client of clients) {
    const implementation = feature.clients[client];
    const label = `${feature.id}/client/${client}`;
    ensure(['not-started', 'in-progress', 'implemented', 'accepted'].includes(implementation.state), `${label}: invalid client state`);
    ensure(implementation.targetRevision === feature.revision, `${label}: client target revision is stale`);
    strings(implementation.tasks, `${label}: client tasks`);
    ensure(implementation.tasks.length > 0, `${label}: client task required`);
    strings(implementation.sourceFiles, `${label}: client source files`);
    strings(implementation.testFiles, `${label}: client test files`);
    unique([...implementation.sourceFiles, ...implementation.testFiles], 'Client source and test files');
    if (['implemented', 'accepted'].includes(implementation.state)) ensure(implementation.sourceFiles.length > 0 && implementation.testFiles.length > 0,
      `${label}: client source and test coverage required`);
    const component = client === 'nuxtWeb' ? root : workspaceRoot ? resolve(workspaceRoot, 'flutter') : null;
    for (const path of implementation.sourceFiles) clientPath(component, path, client === 'nuxtWeb' ? ['app/', 'i18n/'] : ['lib/'], label);
    for (const path of implementation.testFiles) clientPath(component, path, client === 'nuxtWeb' ? ['tests/', 'e2e/'] : ['test/', 'integration_test/'], label);
    ensure(Array.isArray(implementation.evidence), `${label}: client evidence list required`);
    if (implementation.state === 'accepted') {
      ensure(feature.review === 'reviewed' && implementation.evidence.length > 0, `${label}: client accepted state requires reviewed evidence`);
      for (const path of implementation.evidence) checkClientReceipt(root, workspaceRoot, feature, client, implementation, path);
    } else {
      ensure(implementation.evidence.length === 0, `${label}: client evidence belongs to accepted state only`);
      pending.push(`${feature.id}:${client}`);
    }
  }
  return clients.every(client => feature.clients[client].state === 'accepted');
}

function checkFeature(root, workspaceRoot, feature, operations, owners, scenarioIds, sharedSources, clientPending) {
  ensure(nonempty(feature.id) && /^[A-Za-z0-9._:-]+$/.test(feature.id), 'Invalid feature ID');
  ensure(Number.isSafeInteger(feature.revision) && feature.revision > 0, `${feature.id}: invalid revision`);
  ensure(['unreviewed', 'reviewed'].includes(feature.review), `${feature.id}: invalid requirement review state`);
  strings(feature.operations, `${feature.id}: operations`);
  for (const operation of feature.operations) {
    ensure(operations.has(operation), `${feature.id}: unknown operation ${operation}`);
    ensure(!owners.has(operation), `Duplicate operation owner: ${operation}`);
    owners.set(operation, feature.id);
  }
  ensure(Array.isArray(feature.scenarios), `${feature.id}: scenarios required`);
  for (const scenario of feature.scenarios) {
    ensure(nonempty(scenario.id) && !scenarioIds.has(scenario.id), `${feature.id}: invalid or duplicate scenario ID`);
    scenarioIds.add(scenario.id);
    const definition = json(root, scenario.file);
    ensure(definition.id === scenario.id && Array.isArray(definition.cases) && definition.cases.length > 0,
      `${feature.id}: scenario requires an ID and nonempty cases`);
  }
  if (feature.review === 'reviewed') {
    file(root, feature.definition);
    ensure(feature.scenarios.length > 0, `${feature.id}: reviewed requirement requires scenarios`);
    ensure(sharedSources.has(feature.definition), `${feature.id}: reviewed requirement must be registered in shared files: ${feature.definition}`);
    for (const scenario of feature.scenarios) ensure(sharedSources.has(scenario.file),
      `${feature.id}: reviewed scenario must be registered in shared files: ${scenario.file}`);
    strings(feature.sharedDependencies ?? [], `${feature.id}: shared dependencies`);
    unique(feature.sharedDependencies ?? [], `${feature.id}: shared dependencies`);
    for (const dependency of feature.sharedDependencies ?? []) ensure(sharedSources.has(dependency),
      `${feature.id}: shared dependency must be registered in shared files: ${dependency}`);
  }
  ensure(feature.implementations && Object.keys(feature.implementations).length === backends.length,
    `${feature.id}: each nuxt/rust/go implementation task is required`);
  for (const backend of backends) {
    const implementation = feature.implementations[backend];
    ensure(implementation && states.has(implementation.state), `${feature.id}/${backend}: implementation task required`);
    ensure(implementation.targetRevision === feature.revision, `${feature.id}/${backend}: task target revision is stale`);
    strings(implementation.tasks, `${feature.id}/${backend}: tasks`);
    ensure(implementation.tasks.length > 0, `${feature.id}/${backend}: task required`);
    ensure(Array.isArray(implementation.evidence), `${feature.id}/${backend}: evidence list required`);
    if (implementation.state === 'accepted') {
      ensure(implementation.evidence.length > 0, `${feature.id}/${backend}: accepted state requires evidence`);
      ensure(feature.review === 'reviewed', `${feature.id}/${backend}: accepted state requires reviewed requirements`);
      for (const receipt of implementation.evidence) checkReceipt(root, workspaceRoot, feature, backend, implementation, receipt);
    } else ensure(implementation.evidence.length === 0, `${feature.id}/${backend}: evidence belongs to accepted state only`);
  }
  const clientReady = checkClients(root, workspaceRoot, feature, clientPending);
  return clientReady && feature.review === 'reviewed' && backends.every(backend => feature.implementations[backend].state === 'accepted');
}

export function checkParity({ projectRoot, workspaceRoot, release = false }) {
  const root = realPath(projectRoot);
  if (workspaceRoot) {
    workspaceRoot = realPath(workspaceRoot);
    ensure(realPath(resolve(workspaceRoot, 'nuxt')) === root, '--workspace-root must contain this Nuxt project');
  }
  const ledger = json(publicDirectory(root, 'specifications'), 'parity.json');
  ensure(ledger.schemaVersion === 1, 'Unsupported parity schema version');
  ensure(ledger.clientTrackingVersion === 1, 'Client tracking version 1 required; review and migrate client scopes');
  const sharedFileCount = sharedCopies(root, workspaceRoot, ledger.sharedFiles ?? []);
  const sharedSources = new Set((ledger.sharedFiles ?? []).map(entry => entry.source.path));
  checksum(root, ledger.baseline?.openapi, 'Baseline changed; review and update requirements before re-pinning', true);
  ensure(Array.isArray(ledger.baseline.sources) && ledger.baseline.sources.length > 0, 'Source baseline required');
  strings(ledger.baseline.sourceRoots, 'Source roots');
  ensure(ledger.baseline.sourceRoots.length > 0, 'Nonempty source roots required');
  unique(ledger.baseline.sources.map(source => source.path), 'Source baseline');
  for (const source of ledger.baseline.sources) checksum(root, source, 'Baseline changed; review and update requirements before re-pinning', true);
  const actualSources = ledger.baseline.sourceRoots.flatMap(directory => sourceInventory(root, directory)).sort();
  ensure(JSON.stringify(actualSources) === JSON.stringify(ledger.baseline.sources.map(source => source.path).sort()),
    'Source inventory changed; audit added/removed source files before updating the baseline');
  const spec = json(root, ledger.baseline.openapi.path);
  ensure(spec.paths && typeof spec.paths === 'object', 'OpenAPI paths required');
  const operations = new Set(Object.entries(spec.paths).flatMap(([path, item]) =>
    Object.keys(item).filter(method => methods.has(method)).map(method => `${method.toUpperCase()} ${path}`)));
  ensure(operations.size > 0 && Array.isArray(ledger.features) && ledger.features.length > 0, 'Nonempty operations and features required');
  unique(ledger.features.map(feature => feature.id), 'Features');
  const owners = new Map();
  const scenarioIds = new Set();
  const pending = [];
  const clientPending = [];
  for (const feature of ledger.features) if (!checkFeature(root, workspaceRoot, feature, operations, owners, scenarioIds, sharedSources, clientPending)) pending.push(feature.id);
  for (const operation of operations) ensure(owners.has(operation), `Unowned operation: ${operation}`);
  const audits = ledger.sourceAudits ?? [];
  ensure(Array.isArray(audits), 'Source audits must be an array');
  unique(audits.map(audit => audit.id), 'Source audit IDs');
  const ownedSources = new Set();
  for (const feature of ledger.features) {
    strings(feature.sourceFiles, `${feature.id}: source files`);
    for (const path of feature.sourceFiles) {
      ensure(actualSources.includes(path), `${feature.id}: source outside baseline: ${path}`);
      ownedSources.add(path);
    }
  }
  for (const audit of audits) {
    ensure(nonempty(audit.id) && ['unreviewed', 'feature', 'alias', 'diagnostic'].includes(audit.disposition), 'Invalid source audit');
    ensure(!ledger.features.some(feature => feature.id === audit.id), `${audit.id}: source audit ID conflicts with feature ID`);
    ensure(actualSources.includes(audit.source), `${audit.id}: audit source outside baseline`);
    ownedSources.add(audit.source);
    strings(audit.featureIds, `${audit.id}: feature references`);
    if (audit.disposition === 'unreviewed') pending.push(audit.id);
    else {
      ensure(nonempty(audit.reason), `${audit.id}: audit rationale required`);
      if (audit.disposition !== 'diagnostic') ensure(audit.featureIds.length > 0, `${audit.id}: feature reference required`);
      for (const id of audit.featureIds) {
        const feature = ledger.features.find(candidate => candidate.id === id);
        ensure(feature, `${audit.id}: unknown feature ${id}`);
        ensure(feature.sourceFiles.includes(audit.source), `${audit.id}: audit source must be in referenced feature evidence scope`);
      }
    }
  }
  for (const source of actualSources) ensure(ownedSources.has(source), `Unowned source: ${source}`);
  if (release) ensure(pending.length === 0, `Parity not ready: ${pending.join(', ')}`);
  return { features: ledger.features.length, operations: operations.size, scenarios: scenarioIds.size,
    accepted: ledger.features.filter(feature => !pending.includes(feature.id)).length,
    sourceAudits: audits.length, sharedFiles: sharedFileCount, sharedScope: workspaceRoot ? 'workspace' : 'Nuxt-only',
    clientTracking: {
      required: ledger.features.filter(feature => feature.clientScope.state === 'required').length,
      notRequired: ledger.features.filter(feature => feature.clientScope.state === 'not-required').length,
      unreviewed: ledger.features.filter(feature => feature.clientScope.state === 'unreviewed').length,
      sourceScope: workspaceRoot ? 'workspace' : 'Nuxt-only'
    }, clientPending, ready: pending.length === 0, pending };
}
