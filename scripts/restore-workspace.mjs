import { createHash } from 'node:crypto';
import { constants, createReadStream } from 'node:fs';
import { copyFile, lstat, mkdir, readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const layout = { nuxt: 'master', rust: 'Rust', flutter: 'Flutter', go: 'codex/go' };
const managementFiles = ['README.md', 'NekoTribe.code-workspace', 'docs/plans/2026-09-08-workspace-reorganization.md'];
async function statIfPresent(path) {
  try { return await lstat(path); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
function git(args, cwd) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}
export async function restoreWorkspace(kitRoot, destination) {
  const kit = resolve(kitRoot); const target = resolve(destination);
  if (await statIfPresent(target)) throw new Error('Target already exists; choose a new directory. Nothing was overwritten.');
  const manifest = JSON.parse(await readFile(join(kit, 'manifest.json'), 'utf8'));
  if (manifest.schemaVersion !== 1 || typeof manifest.file !== 'string' || basename(manifest.file) !== manifest.file
      || !/^[\w.-]+\.bundle$/.test(manifest.file) || !/^[a-f0-9]{64}$/.test(manifest.sha256 ?? '')) {
    throw new Error('Invalid workspace bundle manifest.');
  }
  const expectedBranches = Object.values(layout).sort();
  if (JSON.stringify(Object.keys(manifest.refs ?? {}).sort()) !== JSON.stringify(expectedBranches)
      || !Object.values(manifest.refs).every(commit => typeof commit === 'string' && /^[a-f0-9]{40}$/.test(commit))) {
    throw new Error('Manifest must pin the four approved branches.');
  }
  const bundle = join(kit, manifest.file);
  if (!(await lstat(bundle)).isFile()) throw new Error('Bundle must be an ordinary file.');
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(bundle)) hash.update(chunk);
  if (hash.digest('hex') !== manifest.sha256) throw new Error('Bundle SHA-256 mismatch; target was not created.');
  for (const file of managementFiles) {
    if (!(await lstat(join(kit, 'management', file))).isFile()) throw new Error('Management files must be ordinary files.');
  }
  git(['--version'], kit);
  const heads = Object.fromEntries(git(['bundle', 'list-heads', bundle], kit).split(/\r?\n/).map(line => {
    const [commit, ref] = line.split(' '); return [ref, commit];
  }));
  for (const branch of expectedBranches) {
    if (heads[`refs/heads/${branch}`] !== manifest.refs[branch]) throw new Error('Bundle branch does not match the pinned source.');
  }
  // mkdir is deliberately non-recursive and atomic: an existing/racing target
  // is never adopted. A failed partial restore is retained, never auto-deleted.
  await mkdir(target);
  const nuxt = join(target, 'nuxt');
  try {
    git(['clone', '--branch', 'master', '--', bundle, nuxt], kit);
    for (const [directory, branch] of Object.entries(layout)) {
      if (directory !== 'nuxt') git(['-C', nuxt, 'worktree', 'add', '--track', '-b', branch, join(target, directory), `origin/${branch}`], kit);
      if (git(['-C', join(target, directory), 'rev-parse', 'HEAD'], kit) !== manifest.refs[branch]) throw new Error('Restored branch revision mismatch.');
    }
    git(['bundle', 'verify', bundle], nuxt);
    for (const file of managementFiles) {
      const output = join(target, file);
      await mkdir(dirname(output), { recursive: true });
      await copyFile(join(kit, 'management', file), output, constants.COPYFILE_EXCL);
    }
    execFileSync(process.execPath, ['scripts/contracts.mjs', 'check', '--workspace-root', target], {
      cwd: nuxt, encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'pipe', 'pipe']
    });
    return { target, refs: manifest.refs };
  } catch (error) {
    throw new Error(`Restore failed; partial directory preserved at ${target}.`, { cause: error });
  }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length > 3) throw new Error('Usage: node restore-workspace.mjs [NEW_TARGET_DIRECTORY]');
    const kit = dirname(fileURLToPath(import.meta.url));
    const result = await restoreWorkspace(kit, process.argv[2] ?? join(kit, 'NekoTribe'));
    console.log(`Restored four workspaces at ${result.target}. No services were started.`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
