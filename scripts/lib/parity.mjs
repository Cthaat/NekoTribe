import { readFileSync, readdirSync, realpathSync } from 'node:fs';
import { isAbsolute, relative, resolve, sep } from 'node:path';
import { createHash } from 'node:crypto';

const backends = ['nuxt', 'rust', 'go'];
const states = new Set(['not-started', 'in-progress', 'proxy', 'implemented', 'accepted']);
const methods = new Set(['get', 'post', 'put', 'patch', 'delete', 'head', 'options', 'trace']);
const ensure = (condition, message) => { if (!condition) throw new Error(message); };
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const nonempty = value => typeof value === 'string' && value.trim().length > 0;

function inside(root, path) {
  ensure(nonempty(path) && !isAbsolute(path) && !path.includes('\\') &&
    path.split('/').every(part => part && part !== '..' && part !== '.') && !path.includes(':'), `Invalid relative path: ${path}`);
  const absolute = resolve(root, path);
  const actual = realpathSync(absolute);
  const delta = relative(realpathSync(root), actual);
  ensure(delta && delta !== '..' && !delta.startsWith(`..${sep}`) && !isAbsolute(delta), `Path escapes project: ${path}`);
  return actual;
}
function file(root, path) { return readFileSync(inside(root, path)); }
function json(root, path) { return JSON.parse(file(root, path).toString('utf8')); }
function checksum(root, entry, description, normalize = false) {
  ensure(entry && /^[a-f0-9]{64}$/.test(entry.sha256), `${description}: invalid checksum`);
  const bytes = file(root, entry.path);
  ensure(digest(normalize ? bytes.toString('utf8').replaceAll('\r\n', '\n') : bytes) === entry.sha256, `${description}: ${entry.path}`);
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
  ensure(nonempty(feature.definition) && digest(file(projectRoot, feature.definition)) === receipt.requirementsSha256,
    `${feature.id}/${backend}: requirement checksum mismatch`);
  ensure(Array.isArray(receipt.scenarios), `${feature.id}/${backend}: evidence scenarios required`);
  unique(receipt.scenarios.map(scenario => scenario.id), 'Evidence scenarios');
  const expected = feature.scenarios.map(scenario => scenario.id).sort();
  ensure(JSON.stringify(receipt.scenarios.map(scenario => scenario.id).sort()) === JSON.stringify(expected),
    `${feature.id}/${backend}: evidence must cover all current scenarios`);
  for (const scenario of feature.scenarios) {
    const recorded = receipt.scenarios.find(item => item.id === scenario.id);
    ensure(recorded.sha256 === digest(file(projectRoot, scenario.file)), `${feature.id}/${backend}: scenario checksum mismatch`);
  }
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

function checkFeature(root, workspaceRoot, feature, operations, owners, scenarioIds) {
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
  return feature.review === 'reviewed' && backends.every(backend => feature.implementations[backend].state === 'accepted');
}

export function checkParity({ projectRoot, workspaceRoot, release = false }) {
  const root = realpathSync(projectRoot);
  if (workspaceRoot) ensure(realpathSync(resolve(workspaceRoot, 'nuxt')) === root, '--workspace-root must contain this Nuxt project');
  const ledger = json(root, 'specifications/parity.json');
  ensure(ledger.schemaVersion === 1, 'Unsupported parity schema version');
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
  for (const feature of ledger.features) if (!checkFeature(root, workspaceRoot, feature, operations, owners, scenarioIds)) pending.push(feature.id);
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
    sourceAudits: audits.length, ready: pending.length === 0, pending };
}
