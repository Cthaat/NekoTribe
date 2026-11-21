import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { AiModelRouter } from '../server/services/ai/model-configuration.ts';
import { configuredModelRouter, parseModelConfigBytes } from '../server/services/ai/model-source.ts';
import { mkdtemp, readFile, rename, rm, rmdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-model-config.json', import.meta.url)));
assert.equal(fixture.cases.length, 61);
const runModelConfig = promisify(execFile);
const commandPath = fileURLToPath(new URL('../scripts/ai-model-config.mjs', import.meta.url));

test('raw model JSON rejects ambiguous fields and invalid Unicode on both inputs', async () => {
  const base = JSON.stringify(fixture.cases[0].config);
  for (const item of fixture.rawCases) {
    assert.ok(base.includes(item.before), item.id);
    const raw = base.replace(item.before,item.after);
    const read = () => parseModelConfigBytes(Buffer.from(raw)).router;
    const inline = () => configuredModelRouter(raw);
    if (item.expectedError) {
      assert.throws(read,{code:item.expectedError},item.id);
      await assert.rejects(inline,{code:item.expectedError},item.id);
    } else {
      assert.equal(read().select('knowledge').model,item.expectedModel,item.id);
      assert.equal((await inline()).select('knowledge').model,item.expectedModel,item.id);
    }
  }
});

test('model config publisher validates and serializes releases by the expected version', async t => {
  const folder = await mkdtemp(join(tmpdir(), 'neko-model-release-'));
  const active = join(folder, 'model.json');
  const candidate = join(folder, 'candidate.json');
  const competing = join(folder, 'competing.json');
  t.after(async () => {
    await Promise.all([active, candidate, competing, join(`${active}.history`, '1.json')].map(path => rm(path, {force:true})));
    await rmdir(`${active}.history`);
    await rmdir(folder);
  });
  const run = (...args) => runModelConfig(process.execPath, ['--experimental-strip-types', commandPath, ...args]);
  const writeCandidate = (path,revision) => writeFile(path,JSON.stringify({...fixture.cases[0].config,revision}));
  await writeCandidate(candidate,1);
  assert.deepEqual(JSON.parse((await run('check',candidate)).stdout),{command:'check',revision:1});
  await run('publish',candidate,active,'0');
  await assert.rejects(() => run('publish',candidate,active,'1'), /REVISION_REUSED/);
  await writeCandidate(candidate,2);
  await writeCandidate(competing,3);
  const attempts = await Promise.allSettled([
    run('publish',candidate,active,'1'),
    run('publish',competing,active,'1'),
  ]);
  assert.equal(attempts.filter(attempt => attempt.status === 'fulfilled').length,1);
  const failed = attempts.find(attempt => attempt.status === 'rejected');
  assert.match(failed.reason.stderr,/STALE_CONFIGURATION|PUBLICATION_BUSY/);
  const activeBytes = await readFile(active);
  assert.equal(JSON.parse(await readFile(join(`${active}.history`, '1.json'))).revision, 1);
  const {revision} = JSON.parse(activeBytes);
  assert.ok(revision === 2 || revision === 3);
  await writeFile(candidate,'{"revision":4,"unknown":"private-value"}');
  await assert.rejects(() => run('publish',candidate,active,String(revision)), error => {
    assert.match(error.stderr,/INVALID_CONFIGURATION/);
    assert.doesNotMatch(error.stderr,/private-value/);
    return true;
  });
  assert.deepEqual(await readFile(active),activeBytes);
});

test('bind changes one role atomically and rollback republishes an older configuration', async t => {
  const folder = await mkdtemp(join(tmpdir(), 'neko-model-bind-'));
  const active = join(folder, 'model.json');
  const previous = join(folder, 'previous.json');
  t.after(async () => {
    await Promise.all([active, previous, ...[1, 2, 3, 4].map(revision => join(`${active}.history`, `${revision}.json`))]
      .map(path => rm(path, { force: true })));
    await rmdir(`${active}.history`);
    await rmdir(folder);
  });
  const run = (...args) => runModelConfig(process.execPath, ['--experimental-strip-types', commandPath, ...args]);
  const configuration = { ...fixture.cases[0].config, revision: 1 };
  await writeFile(previous, JSON.stringify(configuration));
  await run('publish', previous, active, '0');
  await assert.rejects(() => run('rollback-last', active, '1'), /NO_PREVIOUS_CONFIGURATION/);
  const bound = await run('bind', active, '1', 'knowledge', 'capable');
  assert.deepEqual(JSON.parse(bound.stdout), { command: 'bind', revision: 2 });
  const after = await readFile(active);
  assert.deepEqual(JSON.parse(after), {
    ...configuration, revision: 2, bindings: { ...configuration.bindings, knowledge: 'capable' }
  });
  assert.deepEqual(JSON.parse((await run('bind', active, '2', 'knowledge', 'capable')).stdout), { command: 'bind', revision: 2 });
  await assert.rejects(() => run('bind', active, '1', 'writing', 'capable'), /STALE_CONFIGURATION/);
  await assert.rejects(() => run('bind', active, '2', 'agent', 'small'), /INVALID_CONFIGURATION/);
  await assert.rejects(() => run('rollback', active, active, '2'), /ROLLBACK_REQUIRES_OLDER_CONFIGURATION/);
  assert.deepEqual(await readFile(active), after);
  assert.deepEqual(JSON.parse((await run('rollback', previous, active, '2')).stdout), { command: 'rollback', revision: 3 });
  assert.deepEqual(JSON.parse(await readFile(active)), { ...configuration, revision: 3 });
  assert.deepEqual(JSON.parse((await run('rollback-last', active, '3')).stdout), { command: 'rollback-last', revision: 4 });
  assert.deepEqual(JSON.parse(await readFile(active)), { ...JSON.parse(after), revision: 4 });
  assert.deepEqual(await readFile(join(`${active}.history`, '2.json')), after);
  assert.equal(JSON.parse(await readFile(join(`${active}.history`, '3.json'))).revision, 3);
  await assert.rejects(() => run('rollback-last', active, '3'), /STALE_CONFIGURATION/);
  const currentBytes = await readFile(active);
  await writeFile(join(`${active}.history`, '4.json'), JSON.stringify({ ...configuration, revision:4 }));
  await assert.rejects(() => run('rollback-last', active, '4'), /CONFIGURATION_HISTORY_CONFLICT/);
  assert.deepEqual(await readFile(active), currentBytes);
});

test('offline diff detects changes behind an unchanged model profile without printing private values', async t => {
  const folder = await mkdtemp(join(tmpdir(), 'neko-model-diff-'));
  const active = join(folder, 'active.json');
  const candidate = join(folder, 'candidate.json');
  t.after(async () => {
    await Promise.all([active, candidate].map(path => rm(path, {force:true})));
    await rmdir(folder);
  });
  const original = {...fixture.cases[0].config, revision:1};
  const updated = structuredClone(original);
  updated.revision = 2;
  Object.assign(updated.providers.find(provider => provider.id === 'local'), {
    baseUrl:'http://private-diff.invalid:11434', apiKeyEnv:'PRIVATE_DIFF_KEY',
  });
  updated.models.find(model => model.id === 'small').model = 'private-diff-model';
  updated.models.find(model => model.id === 'capable').capabilities.reverse();
  await Promise.all([writeFile(active, JSON.stringify(original)), writeFile(candidate, JSON.stringify(updated))]);
  const {stdout} = await runModelConfig(process.execPath,
    ['--experimental-strip-types', commandPath, 'diff', active, candidate]);
  assert.doesNotMatch(stdout, /private-diff|PRIVATE_DIFF_KEY/);
  assert.deepEqual(JSON.parse(stdout), {
    command:'diff', activeRevision:1, candidateRevision:2,
    results:['knowledge', 'writing', 'agent', 'moderation'].map((role, index) => ({
      role, activeProfile:original.bindings[role], candidateProfile:updated.bindings[role],
      changedFields:index < 2 ? ['baseUrl', 'model', 'apiKeyEnv'] : [],
    })),
  });
  assert.equal(await readFile(active, 'utf8'), JSON.stringify(original));
  assert.equal(await readFile(candidate, 'utf8'), JSON.stringify(updated));
});

test('active model verification identifies stale and unsupported instances without printing credentials', async t => {
  const token = 'fixture.status.token';
  const server = createServer((request, response) => {
    assert.equal(request.headers.authorization, `Bearer ${token}`);
    assert.ok(request.url.endsWith('/api/v2/ai/availability'));
    const data = request.url.startsWith('/old/') ? { model_config_revision: 4 }
      : request.url.startsWith('/legacy/') ? {} : { model_config_revision: 5 };
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ code: 200, data }));
  });
  await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const run = (...addresses) => runModelConfig(process.execPath,
    ['--experimental-strip-types', commandPath, 'verify-active', '5', ...addresses],
    { env: { ...process.env, NEKO_AI_STATUS_TOKEN: token } });
  const success = await run(base);
  assert.deepEqual(JSON.parse(success.stdout).results, [{ target: 1, ok: true, revision: 5 }]);
  await assert.rejects(run(base, base + '/old/', base + '/legacy/'), error => {
    assert.equal(error.code, 1);
    assert.deepEqual(JSON.parse(error.stdout).results, [
      { target: 1, ok: true, revision: 5 },
      { target: 2, ok: false, revision: 4, code: 'REVISION_MISMATCH' },
      { target: 3, ok: false, code: 'STATUS_UNSUPPORTED' }
    ]);
    assert.ok(!(error.stdout + error.stderr).includes(token));
    return true;
  });
  await assert.rejects(run('http://remote.example.test'), /INVALID_STATUS_ENDPOINT/);
});

test('active model verification can wait for all instances within one deadline', async t => {
  const requests = new Map();
  const server = createServer((request, response) => {
    const path = request.url;
    const attempt = (requests.get(path) ?? 0) + 1;
    requests.set(path, attempt);
    const revision = path.startsWith('/loading/') && attempt === 1 ? null
      : path.startsWith('/stale/') ? 4 : 5;
    const inference = path.startsWith('/no-status/') ? undefined : {
      knowledge: true,
      group: !path.startsWith('/disabled/') && (!path.startsWith('/readying/') || attempt > 1),
    };
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ code: 200, data: { model_config_revision: revision, inference } }));
  });
  await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const run = (...args) => runModelConfig(process.execPath,
    ['--experimental-strip-types', commandPath, 'verify-active', '5', ...args],
    { env: { ...process.env, NEKO_AI_STATUS_TOKEN: 'fixture.status.token' } });

  const result = await run(base + '/ready', base + '/loading', '--wait-ms', '3000');
  assert.deepEqual(JSON.parse(result.stdout).results, [
    { target: 1, ok: true, revision: 5 }, { target: 2, ok: true, revision: 5 },
  ]);
  assert.equal(requests.get('/ready/api/v2/ai/availability'), 2);
  assert.equal(requests.get('/loading/api/v2/ai/availability'), 2);
  await assert.rejects(run(base + '/stale', '--wait-ms', '750'), error => {
    assert.equal(error.code, 1);
    assert.deepEqual(JSON.parse(error.stdout).results, [
      { target: 1, ok: false, revision: 4, code: 'REVISION_MISMATCH' },
    ]);
    return true;
  });
  await assert.rejects(run(base, '--wait-ms', '60001'), error => error.code === 2);
  await assert.rejects(run(base + '/disabled', '--require-ready', 'knowledge,agent'), error => {
    assert.equal(error.code, 1);
    assert.deepEqual(JSON.parse(error.stdout).results, [
      { target: 1, ok: false, revision: 5, code: 'INFERENCE_UNAVAILABLE', unreadyRoles: ['agent'] },
    ]);
    return true;
  });
  const ready = await run(base + '/readying', '--require-ready', 'agent', '--wait-ms', '3000');
  assert.deepEqual(JSON.parse(ready.stdout).results, [{ target: 1, ok: true, revision: 5 }]);
  assert.equal(requests.get('/readying/api/v2/ai/availability'), 2);
  await assert.rejects(run(base + '/no-status', '--wait-ms', '3000', '--require-ready', 'agent'), error => {
    assert.equal(error.code, 1);
    assert.equal(JSON.parse(error.stdout).results[0].code, 'STATUS_UNSUPPORTED');
    return true;
  });
  assert.equal(requests.get('/no-status/api/v2/ai/availability'), 1);
  await assert.rejects(run(base, '--require-ready', 'agent,agent'), error => error.code === 2);
});

test('model probe and checked publication exercise adapters and preserve the probed snapshot', async t => {
  const folder = await mkdtemp(join(tmpdir(), 'neko-model-probe-'));
  const candidate = join(folder, 'candidate.json');
  const active = join(folder, 'model.json');
  const archive = `${active}.history`;
  t.after(async () => {
    await Promise.all([candidate, active, ...[1, 3, 4, 5, 6].map(revision => join(archive, `${revision}.json`))]
      .map(path => rm(path, {force:true})));
    await rmdir(archive).catch(error => { if (error.code !== 'ENOENT') throw error; });
    await rmdir(folder);
  });
  const key = 'fixture-probe-secret';
  let wrongSchemaResponse = false;
  let wrongKnowledgeCitation = false;
  let wrongToolTerm = false;
  let rejectRequests = false;
  let rejectRequestNumber = 0;
  let duringProbe;
  const received = [];
  const server = createServer(async (request,response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks));
    if (duringProbe) {
      const update = duringProbe;
      duringProbe = undefined;
      try { await update(); }
      catch { response.writeHead(500); response.end(); return; }
    }
    received.push({url:request.url, auth:request.headers.authorization, body});
    if (rejectRequests || received.length === rejectRequestNumber) {
      response.writeHead(503);
      response.end();
      return;
    }
    const ollama = request.url === '/api/chat';
    let finish = 'stop';
    let message = {role:'assistant',content:'Ready'};
    if (body.tools) {
      finish = 'tool_calls';
      const args = {search_term:wrongToolTerm?'different-term':'neko-probe'};
      const fn = {name:'public_search',arguments:ollama?args:JSON.stringify(args)};
      message = {role:'assistant',content:'',tool_calls:[ollama?{function:fn}:{type:'function',id:'probe-call',function:fn}]};
    } else if (body.messages.at(-1).role === 'tool') {
      message.content = 'NEKO_PROBE_OK';
    } else if (body.format || body.response_format) {
      message.content = JSON.stringify({status:wrongSchemaResponse?'private-provider-response':'ready'});
    } else if (body.messages[0].role === 'system') {
      const [source] = JSON.parse(body.messages[1].content).sources;
      const {kind,id,version} = source;
      message.content = JSON.stringify({answer:'NEKO_PROBE_KNOWLEDGE_OK',
        citations:[{kind,id:wrongKnowledgeCitation?id+1:id,version}]});
    }
    const envelope = ollama ? {done:true,done_reason:'stop',message}
      : {choices:[{index:0,finish_reason:finish,message}]};
    response.writeHead(200,{'content-type':'application/json'});
    response.end(JSON.stringify(envelope));
  });
  await new Promise((resolve,reject)=>server.once('error',reject).listen(0,'127.0.0.1',resolve));
  t.after(() => new Promise(resolve=>server.close(resolve)));
  const url = `http://127.0.0.1:${server.address().port}`;
  const run = (command = 'probe', ...args) => runModelConfig(process.execPath, ['--experimental-strip-types',commandPath,command,candidate,...args],
    {env:{...process.env,AI_HOSTED_KEY:key}});
  const config = structuredClone(fixture.cases[0].config);
  config.providers[0].baseUrl = url;
  config.providers[1].baseUrl = url + '/v1';
  await writeFile(candidate,JSON.stringify(config));
  const {stdout} = await run();
  assert.deepEqual(JSON.parse(stdout).results,['knowledge','writing','agent','moderation'].map(role=>({role,ok:true})));
  assert.deepEqual(received.map(request=>request.url),['/api/chat','/api/chat',...Array(3).fill('/v1/chat/completions')]);
  assert.equal(received[2].auth,`Bearer ${key}`);
  assert.equal(received[2].body.tools[0].function.parameters.properties.search_term.type,'string');
  assert.equal(received[3].body.messages.at(-1).tool_call_id,'probe-call');
  assert.equal(received[4].body.response_format.type,'json_schema');

  received.length = 0;
  const scoped = await run('probe', '--roles', 'moderation,writing');
  assert.deepEqual(JSON.parse(scoped.stdout).results, [{role:'moderation',ok:true}, {role:'writing',ok:true}]);
  assert.deepEqual(received.map(request => request.url), ['/v1/chat/completions', '/api/chat']);
  received.length = 0;
  for (const selection of ['writing,writing', 'group', 'writing,']) {
    await assert.rejects(() => run('probe', '--roles', selection), error => error.code === 2);
  }
  await assert.rejects(() => run('publish-checked', active, '0', '--roles', 'writing'), error => error.code === 2);
  assert.equal(received.length, 0);

  const probedConfig = JSON.stringify({...config, revision: 1});
  await writeFile(candidate, probedConfig);
  duringProbe = () => writeFile(candidate, JSON.stringify({...config, revision: 2}));
  const checked = await run('publish-checked', active, '0');
  assert.equal(JSON.parse(checked.stdout).revision, 1);
  assert.equal(await readFile(active, 'utf8'), probedConfig);

  wrongKnowledgeCitation = true;
  wrongToolTerm = true;
  received.length = 0;
  await assert.rejects(() => run(), error => {
    assert.deepEqual(JSON.parse(error.stdout).results, [
      {role:'knowledge',ok:false,code:'UNEXPECTED_PROBE_OUTPUT'},
      {role:'writing',ok:true},
      {role:'agent',ok:false,code:'UNEXPECTED_PROBE_OUTPUT'},
      {role:'moderation',ok:true},
    ]);
    return true;
  });
  assert.equal(received.length,4);
  wrongKnowledgeCitation = false;
  wrongToolTerm = false;

  config.providers[1].adapter = 'ollama';
  config.providers[1].baseUrl = url;
  await writeFile(candidate,JSON.stringify({...config, revision: 2}));
  received.length = 0;
  wrongSchemaResponse = true;
  await assert.rejects(() => run('publish-checked', active, '1'),error=>{
    assert.equal(error.code,1);
    assert.deepEqual(JSON.parse(error.stdout).results.at(-1),{role:'moderation',ok:false,code:'UNEXPECTED_PROBE_OUTPUT'});
    assert.doesNotMatch(error.stdout+error.stderr,/fixture-probe-secret|private-provider-response/);
    return true;
  });
  assert.equal(received[3].body.messages.at(-1).tool_name,'public_search');
  assert.deepEqual(received[4].body.format.properties.status.enum,['ready']);
  assert.equal(await readFile(active, 'utf8'), probedConfig);

  wrongSchemaResponse = false;
  const concurrent = JSON.parse(probedConfig);
  concurrent.bindings.writing = 'capable';
  const sameRevision = JSON.stringify(concurrent);
  duringProbe = () => writeFile(active, sameRevision);
  await assert.rejects(() => run('publish-checked', active, '1'), /STALE_CONFIGURATION/);
  assert.equal(await readFile(active, 'utf8'), sameRevision);
  await assert.rejects(readFile(join(archive, '1.json')), {code:'ENOENT'});

  const newer = JSON.stringify({...config, revision: 3});
  duringProbe = () => writeFile(active, newer);
  await assert.rejects(() => run('publish-checked', active, '1'), /STALE_CONFIGURATION/);
  assert.equal(await readFile(active, 'utf8'), newer);

  const listed = await runModelConfig(process.execPath, ['--experimental-strip-types', commandPath, 'list', active]);
  assert.deepEqual(JSON.parse(listed.stdout), {
    command:'list', revision:3, bindings:config.bindings,
    profiles:[
      {id:'small', modelVersion:null, capabilities:[]},
      {id:'capable', modelVersion:null, capabilities:['tools','structured-output']},
    ],
  });
  assert.doesNotMatch(listed.stdout, /AI_HOSTED_KEY|127\.0\.0\.1/);
  const bind = (...args) => runModelConfig(process.execPath, [
    '--experimental-strip-types', commandPath, 'bind-checked', active, ...args,
  ], {env:{...process.env,AI_HOSTED_KEY:key}});
  rejectRequests = true;
  received.length = 0;
  await assert.rejects(() => bind('3', 'knowledge', 'capable'), error => {
    assert.equal(error.code, 1);
    assert.equal(JSON.parse(error.stdout).results[0].ok, false);
    return true;
  });
  assert.equal(received.length, 1);
  assert.equal(await readFile(active, 'utf8'), newer);
  rejectRequests = false;
  received.length = 0;
  const result = JSON.parse((await bind('3', 'knowledge', 'capable')).stdout);
  assert.deepEqual(result, {command:'bind-checked',revision:4,results:[{role:'knowledge',ok:true}]});
  assert.equal(received.length, 1);
  assert.equal(await readFile(join(archive, '3.json'), 'utf8'), newer);
  assert.deepEqual(JSON.parse(await readFile(active)).bindings, {...config.bindings, knowledge:'capable'});
  received.length = 0;
  assert.deepEqual(JSON.parse((await bind('4', 'knowledge', 'capable')).stdout),
    {command:'bind-checked',revision:4,results:[]});
  assert.equal(received.length, 0);
  const edited = (await readFile(active, 'utf8')).trim();
  duringProbe = () => writeFile(active, edited);
  await assert.rejects(() => bind('4', 'writing', 'capable'), /STALE_CONFIGURATION/);
  assert.equal(await readFile(active, 'utf8'), edited);

  const rollback = () => runModelConfig(process.execPath, [
    '--experimental-strip-types', commandPath, 'rollback-last-checked', active, '4',
  ], {env:{...process.env,AI_HOSTED_KEY:key}});
  rejectRequests = true;
  await assert.rejects(rollback, error => {
    assert.equal(error.code, 1);
    assert.equal(JSON.parse(error.stdout).revision, 4);
    assert.equal(JSON.parse(error.stdout).results.every(item => !item.ok), true);
    return true;
  });
  assert.equal(await readFile(active, 'utf8'), edited);
  await assert.rejects(readFile(join(archive, '4.json')), {code:'ENOENT'});

  rejectRequests = false;
  duringProbe = () => writeFile(active, `${edited}\n`);
  await assert.rejects(rollback, /STALE_CONFIGURATION/);
  assert.equal(await readFile(active, 'utf8'), `${edited}\n`);
  const restored = JSON.parse((await rollback()).stdout);
  assert.deepEqual(restored, {command:'rollback-last-checked',revision:5,
    results:['knowledge','writing','agent','moderation'].map(role=>({role,ok:true}))});
  assert.equal(await readFile(join(archive, '4.json'), 'utf8'), `${edited}\n`);
  assert.deepEqual(JSON.parse(await readFile(active)), {...JSON.parse(newer), revision:5});

  const beforeBatch = await readFile(active);
  const batch = ['5', 'knowledge', 'capable', 'writing', 'capable', 'agent', 'capable'];
  received.length = 0;
  await assert.rejects(() => bind('5', 'writing', 'capable', 'writing', 'small'), /DUPLICATE_ROLE/);
  assert.equal(received.length, 0);
  rejectRequestNumber = 2;
  await assert.rejects(() => bind(...batch), error => {
    assert.equal(error.code, 1);
    assert.deepEqual(JSON.parse(error.stdout).results.map(({role, ok}) => ({role, ok})),
      [{role:'knowledge', ok:true}, {role:'writing', ok:false}]);
    return true;
  });
  assert.deepEqual(await readFile(active), beforeBatch);
  await assert.rejects(readFile(join(archive, '5.json')), {code:'ENOENT'});
  received.length = 0;
  rejectRequestNumber = 0;
  assert.deepEqual(JSON.parse((await bind(...batch)).stdout), {
    command:'bind-checked', revision:6, results:[{role:'knowledge', ok:true}, {role:'writing', ok:true}],
  });
  assert.equal(received.length, 2);
  assert.deepEqual(await readFile(join(archive, '5.json')), beforeBatch);
  assert.deepEqual(JSON.parse(await readFile(active)).bindings,
    {...config.bindings, knowledge:'capable', writing:'capable'});

  const beforeRestore = await readFile(active);
  const previous = join(archive, '3.json');
  const restore = source => runModelConfig(process.execPath, [
    '--experimental-strip-types', commandPath, 'rollback-checked', source, active, '6',
  ], {env:{...process.env,AI_HOSTED_KEY:key}});
  received.length = 0;
  await assert.rejects(() => restore(active), /ROLLBACK_REQUIRES_OLDER_CONFIGURATION/);
  assert.equal(received.length, 0);

  rejectRequestNumber = 2;
  await assert.rejects(() => restore(previous), error => {
    assert.equal(error.code, 1);
    const {revision, results} = JSON.parse(error.stdout);
    assert.equal(revision, 6);
    assert.equal(results.find(item => item.role === 'writing').ok, false);
    return true;
  });
  assert.deepEqual(await readFile(active), beforeRestore);
  await assert.rejects(readFile(join(archive, '6.json')), {code:'ENOENT'});

  rejectRequestNumber = 0;
  const concurrentBytes = Buffer.concat([beforeRestore, Buffer.from(' ')]);
  duringProbe = () => writeFile(active, concurrentBytes);
  await assert.rejects(() => restore(previous), /STALE_CONFIGURATION/);
  assert.deepEqual(await readFile(active), concurrentBytes);

  const checkedRollback = JSON.parse((await restore(previous)).stdout);
  assert.deepEqual(checkedRollback, {command:'rollback-checked',revision:7,
    results:['knowledge','writing','agent','moderation'].map(role=>({role,ok:true}))});
  assert.deepEqual(JSON.parse(await readFile(active)), {...JSON.parse(newer), revision:7});
  assert.deepEqual(await readFile(join(archive, '6.json')), concurrentBytes);
});

test('AI model file hot reload keeps an immutable selection and the last good revision', async t => {
  const folder = await mkdtemp(join(tmpdir(), 'neko-ai-config-'));
  const path = join(folder, 'models.json');
  t.after(async () => {
    await Promise.all([rm(path, { force: true }), rm(`${path}.new`, { force: true })]);
    await rmdir(folder);
  });
  const previous = process.env.AI_MODEL_CONFIG_FILE;
  process.env.AI_MODEL_CONFIG_FILE = path;
  t.after(() => {
    if (previous === undefined) delete process.env.AI_MODEL_CONFIG_FILE;
    else process.env.AI_MODEL_CONFIG_FILE = previous;
  });
  const config = structuredClone(fixture.cases[0].config);
  config.models[0].modelVersion = 'build-a';
  const original = config.models[0].model;
  const publish = async raw => {
    await writeFile(`${path}.new`, raw);
    await rename(`${path}.new`, path);
  };
  const selection = async () => (await configuredModelRouter()).select('knowledge');

  await publish(JSON.stringify(config));
  const inFlight = await selection();
  config.revision = 2;
  config.models[0].model = 'fixture/model-b';
  config.models[0].modelVersion = 'build-b';
  await publish(JSON.stringify(config));
  await setTimeout(1010);
  assert.equal((await selection()).model, 'fixture/model-b');
  assert.equal(inFlight.model, original);
  assert.equal(inFlight.modelVersion, 'build-a');
  assert.equal((await selection()).modelVersion, 'build-b');

  config.revision = 9;
  await publish(JSON.stringify(config).replace('"revision"','"revision":42,"revision"'));
  await setTimeout(1010);
  assert.equal((await selection()).configurationRevision, 2);

  config.revision = 3;
  config.models[0].model = original;
  config.models[0].modelVersion = 'build-a';
  await publish(JSON.stringify(config));
  await setTimeout(1010);
  const rolledBack = await selection();
  assert.equal(rolledBack.model, original);
  assert.equal(rolledBack.modelVersion, 'build-a');
  assert.equal(rolledBack.configurationRevision, 3);
});
for (const item of fixture.cases) {
  test(`AI model configuration: ${item.id}`, () => {
    let router;
    let before;
    const config = structuredClone(item.config);
    function execute() {
      router = new AiModelRouter(config);
      if (item.action === 'replace') {
        before = router.select(item.role);
        router.replace(item.nextConfig, item.expectedRevision);
      } else if (item.action === 'isolation') {
        const selected = router.select(item.role);
        config.models[1].model = 'mutated-input';
        try { selected.capabilities[0] = 'vision'; } catch (error) { assert(error instanceof TypeError); }
        try { selected.model = 'mutated-selection'; } catch (error) { assert(error instanceof TypeError); }
      }
      return router.select(item.role, item.requiredCapabilities ?? []);
    }
    if (item.expectedError) {
      assert.throws(execute, error => {
        assert.equal(error.code, item.expectedError);
        assert(!error.message.includes('never-print-fixture'));
        assert(!error.message.includes('https://'));
        return true;
      });
      if (item.expectedAfterError) assert.deepEqual(router.select(item.role), item.expectedAfterError);
    } else {
      assert.deepEqual(execute(), item.expected);
      if (item.expectedBefore) assert.deepEqual(before, item.expectedBefore);
    }
  });
}

test('sparse JavaScript input arrays are rejected with safe configuration errors', () => {
  for (const field of ['providers', 'models']) {
    const config = structuredClone(fixture.cases[0].config);
    delete config[field][0];
    assert.throws(() => new AiModelRouter(config), error => error.code === 'INVALID_CONFIGURATION');
  }
  const config = structuredClone(fixture.cases[0].config);
  config.models[0].capabilities = Array(1);
  assert.throws(() => new AiModelRouter(config), error => error.code === 'INVALID_CONFIGURATION');
});
test('sparse requested capabilities cannot bypass capability checks', () => {
  const router = new AiModelRouter(fixture.cases[0].config);
  assert.throws(() => router.select('knowledge', Array(1)), error => error.code === 'UNSUPPORTED_CAPABILITY');
});
