import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

test('Compose keeps container listeners stable when local HOST and PORT differ', {
  skip: process.env.NEKO_TEST_COMPOSE !== 'true'
}, () => {
  const root = fileURLToPath(new URL('..', import.meta.url));
  for (const file of ['docker-compose.yml', 'docker-compose.local.yml']) {
    const result = spawnSync('docker', ['compose', '--env-file', '.env.example', '-f', file, 'config', '--format', 'json'], {
      cwd: root, encoding: 'utf8', windowsHide: true,
      env: { ...process.env, ENV_FILE: './.env.example', HOST: '127.0.0.1', PORT: '31999' }
    });
    assert.equal(result.status, 0, 'Compose configuration must parse successfully');
    const app = JSON.parse(result.stdout).services.app;
    assert.equal(app.environment.HOST, '0.0.0.0');
    assert.equal(app.environment.PORT, '3000');
    assert.equal(app.ports[0].target, 3000);
  }
});
