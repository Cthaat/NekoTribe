import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { restoreWorkspace } from '../scripts/restore-workspace.mjs';

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'neko-restore-'));
  t.after(() => {
    assert(root.startsWith(resolve(tmpdir()) + sep + 'neko-restore-'));
    rmSync(root, { recursive: true, force: true });
  });
  const source = join(root, 'source'); const kit = join(root, 'kit'); const target = join(root, 'restored');
  mkdirSync(join(source, 'scripts'), { recursive: true }); mkdirSync(kit);
  const git = args => execFileSync('git', args, { cwd: source, encoding: 'utf8', windowsHide: true, stdio: 'pipe' }).trim();
  git(['init', '--initial-branch', 'master']);
  writeFileSync(join(source, 'scripts/contracts.mjs'), "if (!process.cwd().endsWith('nuxt')) throw Error('Wrong checkout'); console.log('contract fixture checked');\n");
  git(['add', 'scripts/contracts.mjs']);
  git(['-c', 'user.name=Workspace Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-m', 'fixture']);
  for (const branch of ['Rust', 'Flutter', 'codex/go']) git(['branch', branch]);
  const commit = git(['rev-parse', 'HEAD']);
  const bundle = join(kit, 'NekoTribe.bundle');
  git(['bundle', 'create', bundle, 'master', 'Rust', 'Flutter', 'codex/go']);
  const manifest = { schemaVersion: 1, file: 'NekoTribe.bundle', sha256: createHash('sha256').update(readFileSync(bundle)).digest('hex'),
    refs: Object.fromEntries(['master', 'Rust', 'Flutter', 'codex/go'].map(branch => [branch, commit])) };
  const save = value => writeFileSync(join(kit, 'manifest.json'), JSON.stringify(value));
  save(manifest);
  mkdirSync(join(kit, 'management/docs/plans'), { recursive: true });
  writeFileSync(join(kit, 'management/README.md'), 'Workspace fixture');
  writeFileSync(join(kit, 'management/NekoTribe.code-workspace'), '{}');
  writeFileSync(join(kit, 'management/docs/plans/2026-09-08-workspace-reorganization.md'), 'Approved plan fixture');
  writeFileSync(join(kit, 'management/.env'), 'PRIVATE_FIXTURE=not-for-copy');
  return { root, kit, target, bundle, manifest, save, commit };
}

test('real bundle restores four pinned worktrees and only the explicit management files', async t => {
  const f = fixture(t); const result = await restoreWorkspace(f.kit, f.target);
  assert.equal(result.target, f.target);
  for (const [directory, branch] of Object.entries({ nuxt: 'master', rust: 'Rust', flutter: 'Flutter', go: 'codex/go' })) {
    const cwd = join(f.target, directory);
    assert.equal(execFileSync('git', ['branch', '--show-current'], { cwd, encoding: 'utf8', windowsHide: true }).trim(), branch);
    assert.equal(execFileSync('git', ['rev-parse', 'HEAD'], { cwd, encoding: 'utf8', windowsHide: true }).trim(), f.commit);
  }
  assert.equal(readFileSync(join(f.target, 'README.md'), 'utf8'), 'Workspace fixture');
  assert(!existsSync(join(f.target, '.env')));
  assert(!existsSync(join(f.target, 'nuxt/node_modules')));
});

test('existing directory or file is never adopted or overwritten', async t => {
  const f = fixture(t); mkdirSync(f.target); writeFileSync(join(f.target, 'keep'), 'preserved');
  await assert.rejects(restoreWorkspace(f.kit, f.target), /Target already exists/);
  assert.equal(readFileSync(join(f.target, 'keep'), 'utf8'), 'preserved');
  const file = join(f.root, 'existing-file'); writeFileSync(file, 'preserved file');
  await assert.rejects(restoreWorkspace(f.kit, file), /Target already exists/);
  assert.equal(readFileSync(file, 'utf8'), 'preserved file');
});

test('corrupt bundle fails SHA-256 before creating any target', async t => {
  const f = fixture(t); writeFileSync(f.bundle, 'corrupted fixture');
  await assert.rejects(restoreWorkspace(f.kit, f.target), /SHA-256 mismatch/);
  assert(!existsSync(f.target));
});

test('manifest cannot select files outside its kit', async t => {
  const f = fixture(t); f.save({ ...f.manifest, file: '../outside.bundle' });
  await assert.rejects(restoreWorkspace(f.kit, f.target), /Invalid workspace bundle manifest/);
  assert(!existsSync(f.target));
});

test('missing or incorrectly pinned branches fail before a target is created', async t => {
  const f = fixture(t); f.save({ ...f.manifest, refs: { master: f.commit } });
  await assert.rejects(restoreWorkspace(f.kit, f.target), /four approved branches/);
  f.save({ ...f.manifest, refs: { ...f.manifest.refs, Rust: '0'.repeat(40) } });
  await assert.rejects(restoreWorkspace(f.kit, f.target), /pinned source/);
  assert(!existsSync(f.target));
});
