#!/usr/bin/env node
// Offline checks use only this checkout and Node built-ins. Git is needed only for sync provenance.
import { mkdirSync, readFileSync, writeFileSync, readdirSync, realpathSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { dirname, resolve, relative, sep } from 'node:path';

const methods = new Set(['get', 'post', 'put', 'patch', 'delete', 'head', 'options', 'trace']);
const sources = ['doc/v2.openapi.json', 'doc/runtime-addresses.md'];
const authority = 'Nuxt doc/v2.openapi.json';
const manifestPath = 'doc/contracts.manifest.json';
const copies = [
  ['rust', 'manifest.json'], ['flutter', 'source.json'], ['go', 'manifest.json']
];
const nativeLaunchFiles = [
  'scripts/start-native.mjs',
  'scripts/package-native.mjs',
  'scripts/release/native/start.cmd',
  'scripts/release/native/start.sh',
];
const endpointCheck = 'scripts/check-deployment-endpoints.mjs';
const sourceLaunchFiles = ['start.cmd', 'start.sh'].map(name => [`scripts/source/native/${name}`, name]);
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const blob = (bytes) => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const fail = (message) => { throw new Error(message); };
const requireThat = (value, message) => { if (!value) fail(message); };
const canonical = (path) => path.replace(/\{[^}]+\}/g, '{}').replace(/\/$/, '');
const operationKey = (method, path) => `${method.toUpperCase()} ${canonical(path)}`;
const json = (value) => Buffer.from(JSON.stringify(value, null, 2) + '\n');

function read(path, normalize = false) {
  let bytes = readFileSync(path);
  // Reject invalid bytes before decoding for normalization, so sync cannot replace data silently.
  requireThat(Buffer.from(bytes.toString('utf8')).equals(bytes), `${path}: invalid UTF-8`);
  if (normalize) bytes = Buffer.from(bytes.toString('utf8').replaceAll('\r\n', '\n'));
  requireThat(!bytes.includes(13) && !bytes.subarray(0, 3).equals(Buffer.from([239, 187, 191])), `${path}: use UTF-8 without BOM and LF line endings`);
  return bytes;
}

function resolveRef(spec, ref) {
  requireThat(ref.startsWith('#/'), `External or invalid $ref is not supported offline: ${ref}`);
  let value = spec;
  for (const part of ref.slice(2).split('/')) value = value?.[part.replaceAll('~1', '/').replaceAll('~0', '~')];
  requireThat(value !== undefined, `Unresolved $ref: ${ref}`);
  return value;
}

function validateSpec(spec) {
  requireThat(spec.openapi === '3.0.1' && typeof spec.info?.version === 'string', 'Expected OpenAPI 3.0.1 and info.version');
  const ids = new Set();
  const operations = new Map();
  let schemaGaps = 0;
  let proxyOperations = 0;
  let schemasChecked = 0;
  const schemaTypes = new Set(['array', 'boolean', 'integer', 'number', 'object', 'string']);
  function schema(value, path) {
    requireThat(value && typeof value === 'object' && !Array.isArray(value), `Invalid Schema Object: ${path}`);
    schemasChecked++;
    if (value.type !== undefined) requireThat(schemaTypes.has(value.type), `Invalid OAS 3.0.1 schema type at ${path}: ${JSON.stringify(value.type)}`);
    if (value.nullable !== undefined) requireThat(typeof value.nullable === 'boolean', `Invalid nullable at ${path}`);
    if (value.type === 'array') requireThat(value.items && typeof value.items === 'object' && !Array.isArray(value.items), `Invalid array schema without object items: ${path}`);
    for (const [name, child] of Object.entries(value.properties ?? {})) schema(child, `${path}/properties/${name}`);
    for (const key of ['items', 'not', 'additionalProperties']) if (value[key] && typeof value[key] === 'object') schema(value[key], `${path}/${key}`);
    for (const key of ['allOf', 'anyOf', 'oneOf']) {
      if (value[key] !== undefined) {
        requireThat(Array.isArray(value[key]) && value[key].length > 0, `Invalid ${key} schema: ${path}`);
        value[key].forEach((child, i) => schema(child, `${path}/${key}/${i}`));
      }
    }
  }
  function documentSchemas(value, path = '#') {
    if (!value || typeof value !== 'object') return;
    for (const [key, child] of Object.entries(value)) {
      if (['example', 'examples', 'default', 'enum'].includes(key)) continue;
      if (key === 'schema') schema(child, `${path}/${key}`);
      else if (path === '#/components' && key === 'schemas') {
        for (const [name, definition] of Object.entries(child)) schema(definition, `${path}/schemas/${name}`);
      } else documentSchemas(child, `${path}/${key}`);
    }
  }
  documentSchemas(spec);
  function refs(value) {
    if (!value || typeof value !== 'object') return;
    if (value.$ref) resolveRef(spec, value.$ref);
    for (const child of Object.values(value)) refs(child);
  }
  refs(spec);
  for (const [path, item] of Object.entries(spec.paths ?? {})) {
    for (const [method, operation] of Object.entries(item)) {
      if (!methods.has(method)) continue;
      requireThat(typeof operation.operationId === 'string' && operation.operationId.length > 0 && !ids.has(operation.operationId), `Missing or duplicate operationId: ${operation.operationId}`);
      ids.add(operation.operationId);
      const key = operationKey(method, path);
      requireThat(!operations.has(key), `Duplicate templated operation: ${key}`);
      const parameters = [...(item.parameters ?? []), ...(operation.parameters ?? [])].map((p) => p.$ref ? resolveRef(spec, p.$ref) : p);
      const names = [...path.matchAll(/\{([^}]+)\}/g)].map((m) => m[1]);
      for (const name of names) requireThat(parameters.some((p) => p.in === 'path' && p.name === name && p.required === true), `Missing required path parameter ${name}: ${key}`);
      for (const p of parameters.filter((p) => p.in === 'path')) requireThat(names.includes(p.name) && p.required === true, `Invalid path parameter ${p.name}: ${key}`);
      operations.set(key, { path, method, operation });
      if (operation['x-schema-audit-status']) schemaGaps++;
      if (operation['x-implementation-kind'] === 'dynamic-proxy') proxyOperations++;
    }
  }
  return { operations, schemaGaps, proxyOperations, schemasChecked };
}

function filesUnder(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = resolve(directory, entry.name);
    requireThat(!entry.isSymbolicLink(), `Symlink is not a contract source: ${path}`);
    return entry.isDirectory() ? filesUnder(path) : [path];
  });
}

function validateRoutes(projectRoot, inventory) {
  const routes = new Map();
  const routeRoot = resolve(projectRoot, 'server/api/v2');
  let catchalls = 0;
  for (const file of filesUnder(routeRoot).filter((file) => file.endsWith('.ts'))) {
    const path = relative(routeRoot, file).split(sep).join('/');
    if (path.includes('[...')) { catchalls++; continue; }
    const match = path.match(/^(.*)\.(get|post|put|patch|delete|head|options|trace)\.ts$/);
    requireThat(match, `Explicit route without an HTTP method needs manual audit: ${path}`);
    const url = '/api/v2/' + match[1].replace(/(^|\/)index$/, '').replace(/\[([^\]]+)\]/g, '{$1}');
    const key = operationKey(match[2], url);
    requireThat(inventory.operations.has(key), `Undocumented source route: ${key}`);
    routes.set(key, relative(projectRoot, file).split(sep).join('/'));
  }
  for (const [key, { path, operation }] of inventory.operations) {
    const source = operation['x-implementation-source'];
    requireThat(operation['x-implementation-kind'] !== 'dynamic-proxy', `Shared operation must have a native implementation: ${key}`);
    if (path.startsWith('/api/v2/')) {
      requireThat(routes.has(key), `Documented operation has no explicit source route: ${key}`);
      if (source) requireThat(source === routes.get(key), `Wrong implementation source: ${key}`);
    } else if (path === '/metrics') {
      requireThat(key === 'GET /metrics' && source === 'server/routes/metrics.get.ts', `Wrong metrics implementation source: ${key}`);
      requireThat(statSync(resolve(projectRoot, source)).isFile(), `Missing metrics route: ${source}`);
      routes.set(key, source);
    }
  }
  return { explicitRoutes: routes.size, catchalls };
}

function git(projectRoot, ...args) {
  return execFileSync('git', ['-c', `safe.directory=${projectRoot.replaceAll('\\', '/')}`, '-c', 'core.longpaths=true', '-C', projectRoot, ...args], { maxBuffer: 8 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
}

function makeManifest(projectRoot, spec, bytes) {
  const commit = git(projectRoot, 'rev-parse', 'HEAD').toString().trim();
  return {
    schemaVersion: 2,
    authority,
    contractVersion: spec.info.version,
    revision: spec.info['x-contract-revision'] ?? spec.info.version,
    normalization: 'UTF-8 without BOM; LF. SHA-256 and Git blob identify exact snapshot bytes.',
    source: { project: 'nuxt', branch: git(projectRoot, 'branch', '--show-current').toString().trim(), commit },
    files: sources.map((sourcePath, i) => {
      const committed = git(projectRoot, 'show', `${commit}:${sourcePath}`);
      return {
        path: sourcePath.split('/').at(-1), sourcePath,
        sha256: hash(bytes[i]), gitBlob: blob(bytes[i]),
        committedSource: { commit, gitBlob: blob(committed), sha256: hash(committed) },
        differsFromCommittedSource: !bytes[i].equals(committed)
      };
    })
  };
}

function validateManifest(manifest, spec, bytes) {
  requireThat(manifest.schemaVersion === 2 && manifest.authority === authority && manifest.source?.project === 'nuxt', 'Wrong manifest authority or schema version');
  requireThat(typeof manifest.source.branch === 'string' && /^[0-9a-f]{40}$/.test(manifest.source.commit), 'Invalid source provenance');
  requireThat(manifest.contractVersion === spec.info.version && manifest.revision === (spec.info['x-contract-revision'] ?? spec.info.version), 'Wrong contract version or revision');
  requireThat(manifest.files?.length === sources.length, 'Missing manifest file entries');
  for (const [i, sourcePath] of sources.entries()) {
    const file = manifest.files[i];
    requireThat(file.sourcePath === sourcePath && file.path === sourcePath.split('/').at(-1), `Wrong source path: ${file.sourcePath}`);
    requireThat(file.sha256 === hash(bytes[i]) && file.gitBlob === blob(bytes[i]), `${sourcePath}: snapshot hash drift`);
    const committed = file.committedSource;
    requireThat(committed?.commit === manifest.source.commit && /^[0-9a-f]{40}$/.test(committed.gitBlob) && /^[0-9a-f]{64}$/.test(committed.sha256), `Invalid committed source metadata: ${sourcePath}`);
    requireThat(file.differsFromCommittedSource === (file.gitBlob !== committed.gitBlob) && (file.differsFromCommittedSource || file.sha256 === committed.sha256), `Inconsistent committed source metadata: ${sourcePath}`);
  }
}

function run() {
  const args = process.argv.slice(2);
  const command = args.shift() ?? 'check';
  requireThat(['check', 'sync'].includes(command), 'Usage: node scripts/contracts.mjs [check|sync] [--workspace-root PATH]');
  let workspaceRoot;
  if (args.length) {
    requireThat(args.length === 2 && args[0] === '--workspace-root' && args[1], 'Expected --workspace-root PATH');
    workspaceRoot = realpathSync.native(args[1]);
  }
  requireThat(command !== 'sync' || workspaceRoot, 'sync requires explicit --workspace-root PATH');
  const projectRoot = realpathSync.native(process.cwd());
  if (workspaceRoot) requireThat(realpathSync.native(resolve(workspaceRoot, 'nuxt')) === projectRoot, '--workspace-root must contain this Nuxt checkout at nuxt/');
  const bytes = sources.map((path) => read(resolve(projectRoot, path), command === 'sync'));
  const spec = JSON.parse(bytes[0]);
  const inventory = validateSpec(spec);
  const routes = validateRoutes(projectRoot, inventory);
  // Preflight all destinations before writing anything; never infer or create sibling projects.
  if (workspaceRoot) for (const [project] of copies) requireThat(statSync(resolve(workspaceRoot, project, 'contracts')).isDirectory(), `Missing ${project}/contracts`);
  const manifest = command === 'sync' ? makeManifest(projectRoot, spec, bytes) : JSON.parse(read(resolve(projectRoot, manifestPath)));
  validateManifest(manifest, spec, bytes);
  const manifestBytes = json(manifest);
  const launchFiles = workspaceRoot
    ? [...nativeLaunchFiles, endpointCheck].map(path => [path, read(resolve(projectRoot, path), true)]).concat(
        sourceLaunchFiles.map(([source, target]) => [target, read(resolve(projectRoot, source), true)])
      )
    : [];
  if (command === 'sync') {
    sources.forEach((path, i) => writeFileSync(resolve(projectRoot, path), bytes[i]));
    writeFileSync(resolve(projectRoot, manifestPath), manifestBytes);
  }
  if (workspaceRoot) for (const [project, name] of copies) {
    const directory = resolve(workspaceRoot, project, 'contracts');
    const expected = [...manifest.files.map((file, i) => [file.path, bytes[i]]), [name, manifestBytes]];
    for (const [path, content] of expected) {
      const destination = resolve(directory, path);
      if (command === 'sync') writeFileSync(destination, content);
      else requireThat(read(destination).equals(content), `${project}/contracts/${path}: bytes/hash drift from Nuxt source`);
    }
    for (const [path, content] of launchFiles) {
      if (project === 'flutter' && path !== endpointCheck) continue;
      const destination = resolve(workspaceRoot, project, path);
      if (command === 'sync') {
        mkdirSync(dirname(destination), { recursive: true });
        writeFileSync(destination, content);
      } else {
        requireThat(read(destination, true).equals(content), `${project}/${path}: launcher script drift from Nuxt source`);
      }
    }
  }
  console.log(JSON.stringify({ command, scope: workspaceRoot ? 'workspace' : 'Nuxt-only offline', contractVersion: spec.info.version, sha256: hash(bytes[0]), operations: inventory.operations.size, ...routes, proxyOperations: inventory.proxyOperations, schemaGaps: inventory.schemaGaps, schemasChecked: inventory.schemasChecked }));
}

try { run(); } catch (error) { console.error(`contracts: ${error.message}`); process.exitCode = 1; }
