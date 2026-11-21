import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

test('Compose can select imported backend image tags while keeping defaults', {
  skip: process.env.NEKO_TEST_COMPOSE !== 'true'
}, () => {
  const targets = [
    ['nuxt', 'docker-compose.yml', 'app', 'NUXT_IMAGE', 'ghcr.io/cthaat/nekotribe:master'],
    ['nuxt', 'docker-compose.local.yml', 'app', 'NUXT_IMAGE', 'nekotribe:local'],
    ['nuxt', 'docker-compose.external.yml', 'app', 'NUXT_IMAGE', 'nekotribe:external'],
    ['go', 'compose.yaml', 'go', 'GO_APP_IMAGE', undefined],
    ['rust', 'compose.yaml', 'rust', 'RUST_APP_IMAGE', undefined],
  ];
  for (const [worktree, file, service, variable, defaultImage] of targets) {
    const sample = worktree === 'nuxt' ? '.env.example' : 'env.example';
    const envVariable = worktree === 'nuxt' ? 'ENV_FILE' : `${worktree.toUpperCase()}_APP_ENV_FILE`;
    const env = { ...process.env, [envVariable]: `./${sample}` };
    delete env[variable];
    delete env.NUXT_IMAGE_PULL_POLICY;
    const render = overrides => {
      const result = spawnSync('docker', ['compose', '--env-file', sample, '-f', file, 'config', '--format', 'json'], {
        cwd: fileURLToPath(new URL(`../../${worktree}/`, import.meta.url)),
        encoding: 'utf8', windowsHide: true, env: { ...env, ...overrides }
      });
      assert.ifError(result.error);
      assert.equal(result.status, 0, `${worktree}/${file} configuration must parse successfully`);
      return JSON.parse(result.stdout).services[service];
    };
    const tag = `nekotribe-${worktree}:release-1`;
    const current = render({});
    const imported = render({ [variable]: tag, NUXT_IMAGE_PULL_POLICY: 'never' });
    assert.equal(current.image || undefined, defaultImage);
    assert.equal(imported.image, tag);
    if (file === 'docker-compose.yml') {
      assert.equal(current.pull_policy, 'always');
      assert.equal(imported.pull_policy, 'never');
    } else {
      assert.ok(imported.build?.context);
    }
  }
});

test('Compose keeps container listeners stable when local HOST and PORT differ', {
  skip: process.env.NEKO_TEST_COMPOSE !== 'true'
}, () => {
  const root = fileURLToPath(new URL('..', import.meta.url));
  for (const file of ['docker-compose.yml', 'docker-compose.local.yml']) {
    const result = spawnSync('docker', ['compose', '--env-file', '.env.example', '-f', file, 'config', '--format', 'json'], {
      cwd: root, encoding: 'utf8', windowsHide: true,
      env: { ...process.env, ENV_FILE: './.env.example', HOST: '127.0.0.1', PORT: '31999' }
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, 'Compose configuration must parse successfully');
    const app = JSON.parse(result.stdout).services.app;
    assert.equal(app.environment.HOST, '0.0.0.0');
    assert.equal(app.environment.PORT, '3000');
    assert.equal(app.ports[0].target, 3000);
  }
});

test('Nuxt Compose shares the gateway API upstream and permits an explicit SSR override', {
  skip: process.env.NEKO_TEST_COMPOSE !== 'true'
}, () => {
  const root = fileURLToPath(new URL('..', import.meta.url));
  const go = 'http://host.docker.internal:30006';
  const rust = 'http://host.docker.internal:30003';
  const internal = 'http://internal-api:8080';
  const baseEnv = { ...process.env, ENV_FILE: './.env.example', NUXT_ENV_FILE: './.env.nuxt.example' };
  for (const name of ['API_BACKEND_UPSTREAM', 'NUXT_API_SERVER_BASE', 'WS_BACKEND_UPSTREAM', 'MEDIA_BACKEND_UPSTREAM']) {
    delete baseEnv[name];
  }
  function render(file, overrides) {
    const result = spawnSync('docker', ['compose', '--env-file', '.env.example', '-f', file, 'config', '--format', 'json'], {
      cwd: root, encoding: 'utf8', windowsHide: true, env: { ...baseEnv, ...overrides }
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, `Compose configuration must parse successfully for ${file}`);
    return JSON.parse(result.stdout).services;
  }

  for (const upstream of [go, rust]) {
    const { gateway } = render('docker-compose.gateway.yml', { API_BACKEND_UPSTREAM: upstream });
    assert.equal(gateway.environment.API_BACKEND_UPSTREAM, upstream);
    assert.equal(gateway.environment.WS_BACKEND_UPSTREAM, upstream);
    assert.equal(gateway.environment.MEDIA_BACKEND_UPSTREAM, upstream);
  }

  for (const file of ['docker-compose.yml', 'docker-compose.local.yml', 'docker-compose.external.yml']) {
    const { app } = render(file, { API_BACKEND_UPSTREAM: go });
    assert.equal(app.environment.NUXT_API_SERVER_BASE, go);
    assert(app.extra_hosts.includes('host.docker.internal=host-gateway'));
    assert.equal(render(file, { API_BACKEND_UPSTREAM: rust }).app.environment.NUXT_API_SERVER_BASE, rust);
    assert.equal(render(file, { API_BACKEND_UPSTREAM: go, NUXT_API_SERVER_BASE: internal }).app.environment.NUXT_API_SERVER_BASE, internal);
    assert.equal(render(file, { API_BACKEND_UPSTREAM: go, NUXT_API_SERVER_BASE: '' }).app.environment.NUXT_API_SERVER_BASE, '');
    assert.equal(render(file, {}).app.environment.NUXT_API_SERVER_BASE, '');
  }
});

test('a private knowledge index is reachable from independently deployed backends', {
  skip: process.env.NEKO_TEST_COMPOSE !== 'true'
}, () => {
  const network = 'nekotribe-test-knowledge';
  function render(worktree, files, envFiles) {
    const result = spawnSync('docker', ['compose', '--env-file', envFiles.sample,
      ...files.flatMap(file => ['-f', file]), 'config', '--format', 'json'], {
      cwd: fileURLToPath(new URL(`../../${worktree}/`, import.meta.url)),
      encoding: 'utf8', windowsHide: true,
      env: { ...process.env, ...envFiles.overrides, NEKO_KNOWLEDGE_NETWORK: network }
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, `Compose configuration must parse for ${files.join(' + ')}`);
    const config = JSON.parse(result.stdout);
    assert.equal(config.networks['neko-knowledge'].name, network);
    assert.equal(config.networks['neko-knowledge'].external, true);
    return config.services;
  }

  const nuxtEnv = { sample: '.env.example', overrides: { ENV_FILE: './.env.example',
    AI_INDEX_APP_ENV_FILE: './.env.knowledge-index.example' } };
  const index = render('nuxt', ['docker-compose.knowledge-index.yml', 'docker-compose.knowledge-index-private.yml'], nuxtEnv)['knowledge-index'];
  assert.equal(index.ports?.length ?? 0, 0);
  assert.deepEqual(index.networks['neko-knowledge'].aliases, ['knowledge-index']);

  function assertClient(service, originalNetwork) {
    assert.equal(service.environment.AI_KNOWLEDGE_INDEX_URL, 'http://knowledge-index:3818');
    assert(Object.hasOwn(service.networks, 'neko-knowledge'));
    assert(Object.hasOwn(service.networks, originalNetwork));
  }
  for (const base of ['docker-compose.yml', 'docker-compose.local.yml', 'docker-compose.external.yml']) {
    const { app } = render('nuxt', [base, 'docker-compose.knowledge-client.yml'], nuxtEnv);
    assertClient(app, base === 'docker-compose.external.yml' ? 'default' : 'neko-network');
  }
  for (const backend of ['go', 'rust']) {
    const envFiles = { sample: 'env.example', overrides: { [`${backend.toUpperCase()}_APP_ENV_FILE`]: './env.example' } };
    const services = render(backend, ['compose.yaml', 'compose.knowledge-client.yaml'], envFiles);
    assertClient(services[backend], 'default');
  }
});
