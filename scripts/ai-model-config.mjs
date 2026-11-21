import { randomUUID } from 'node:crypto';
import { lstat, mkdir, open, readdir, rename, rm, rmdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { isDeepStrictEqual } from 'node:util';
import { AiInferenceTransport, AiTransportError } from '../server/services/ai/inference-transport.ts';
import { parseKnowledgeAnswer } from '../server/services/ai/knowledge-citations.ts';
import { MAX_STORED_MODEL_REVISION, parseModelConfigBytes, readModelConfigFile } from '../server/services/ai/model-source.ts';
import groupDraft from '../specifications/requirements/ai-group-draft.json' with { type: 'json' };
import { requestJson } from './knowledge-index/http.mjs';

const [command, ...args] = process.argv.slice(2);
const roles = ['knowledge', 'writing', 'agent', 'moderation'];
const validRevision = value => typeof value === 'string' && /^(?:0|[1-9][0-9]{0,14})$/.test(value) && value.trim() === value;

async function writeAtomically(target, bytes) {
  const temp = `${target}.${randomUUID()}.tmp`;
  const file = await open(temp, 'wx', 0o600);
  try {
    try {
      await file.writeFile(bytes);
      await file.sync();
    } finally {
      await file.close();
    }
    await rename(temp, target);
  } finally {
    await rm(temp, { force: true });
  }
}

async function archiveCurrent(directory, current) {
  await mkdir(directory, { mode: 0o700 }).catch(error => {
    if (error.code !== 'EEXIST') throw error;
  });
  if (!(await lstat(directory)).isDirectory()) throw Error('CONFIGURATION_HISTORY_CONFLICT');
  const target = join(directory, `${current.revision}.json`);
  const info = await lstat(target).catch(error => {
    if (error.code === 'ENOENT') return null;
    throw error;
  });
  if (!info) {
    await writeAtomically(target, current.bytes);
    return;
  }
  if (!info.isFile() || !(await readModelConfigFile(target)).bytes.equals(current.bytes)) {
    throw Error('CONFIGURATION_HISTORY_CONFLICT');
  }
}

async function restorePrevious(directory, current) {
  const info = await lstat(directory).catch(error => {
    if (error.code === 'ENOENT') return null;
    throw error;
  });
  if (!info) throw Error('NO_PREVIOUS_CONFIGURATION');
  if (!info.isDirectory()) throw Error('CONFIGURATION_HISTORY_CONFLICT');
  let previousRevision = 0;
  for (const name of await readdir(directory)) {
    if (!name.endsWith('.json') || !validRevision(name.slice(0, -5))) continue;
    const revision = Number(name.slice(0, -5));
    if (revision < current.revision && revision > previousRevision) previousRevision = revision;
  }
  if (!previousRevision) throw Error('NO_PREVIOUS_CONFIGURATION');
  const previousPath = join(directory, `${previousRevision}.json`);
  if (!(await lstat(previousPath)).isFile()) throw Error('CONFIGURATION_HISTORY_CONFLICT');
  const previous = await readModelConfigFile(previousPath);
  if (previous.revision !== previousRevision) throw Error('CONFIGURATION_HISTORY_CONFLICT');
  return restoreRevision(previous, current);
}

function restoreRevision(previous, current) {
  if (previous.revision >= current.revision) throw Error('ROLLBACK_REQUIRES_OLDER_CONFIGURATION');
  return nextRevision(JSON.parse(previous.bytes.toString('utf8')), current.revision);
}

async function readActive(target, expectedRevision) {
  const current = await readModelConfigFile(target).catch(error => {
    if (error.code === 'ENOENT') return null;
    throw error;
  });
  if ((current?.revision ?? 0) !== expectedRevision) throw Error('STALE_CONFIGURATION');
  return current;
}

async function publish(target, expectedRevision, chooseCandidate) {
  const lock = `${target}.lock`;
  try {
    await mkdir(lock, { mode: 0o700 });
  } catch (error) {
    if (error.code === 'EEXIST') throw Error('PUBLICATION_BUSY');
    throw error;
  }
  const directory = `${target}.history`;
  try {
    const current = await readActive(target, expectedRevision);
    const candidate = await chooseCandidate(current, directory);
    if (candidate === current) return current.revision;
    if (candidate.revision <= expectedRevision) throw Error('REVISION_REUSED');
    if (current) await archiveCurrent(directory, current);
    await writeAtomically(target, candidate.bytes);
    return candidate.revision;
  } finally {
    await rmdir(lock);
  }
}

function publishSnapshot(target, original, candidate) {
  return publish(target, original?.revision ?? 0, current => {
    if (original && !current.bytes.equals(original.bytes)) throw Error('STALE_CONFIGURATION');
    return candidate === original ? current : candidate;
  });
}

function nextRevision(configuration, revision) {
  if (revision >= MAX_STORED_MODEL_REVISION) throw Error('REVISION_LIMIT');
  return parseModelConfigBytes(Buffer.from(JSON.stringify({ ...configuration, revision: revision + 1 }) + '\n'));
}

function parseBindings(values) {
  const bindings = new Map();
  for (let index = 0; index < values.length; index += 2) {
    const role = values[index];
    if (!roles.includes(role)) throw Error('UNKNOWN_ROLE');
    if (bindings.has(role)) throw Error('DUPLICATE_ROLE');
    bindings.set(role, values[index + 1]);
  }
  return bindings;
}

function bind(current, bindings) {
  const configuration = JSON.parse(current.bytes.toString('utf8'));
  const changes = [...bindings].filter(([role, profile]) => configuration.bindings[role] !== profile);
  if (!changes.length) return { candidate: current, purposes: [] };
  Object.assign(configuration.bindings, Object.fromEntries(changes));
  return {
    candidate: nextRevision(configuration, current.revision),
    purposes: changes.map(([role]) => role),
  };
}

const probeSchema = {
  type: 'object',
  properties: { status: { type: 'string', enum: ['ready'] } },
  required: ['status'],
  additionalProperties: false,
};
const probeTool = groupDraft.tools.find(tool => tool.name === groupDraft.requiredTool);
const probeSearchTerm = 'neko-probe';
const probeCitation = {kind:'group_post', id:1, version:'a'.repeat(64)};

async function probeRole(transport, selection) {
  if (selection.role === 'knowledge') {
    const result = await transport.infer(selection, {
      messages: [
        {role:'system', content:'Answer using the provided source. Return only a JSON object with answer and citations. Each citation contains only the exact kind, id and version of the source.'},
        {role:'user', content:JSON.stringify({
          question:'What is the exact status reported by the source?',
          sources:[{...probeCitation, post_id:1, group_id:1, content:'The status is NEKO_PROBE_KNOWLEDGE_OK.'}],
        })},
      ],
    });
    if (result.finishReason !== 'stop' || result.toolCalls.length) return false;
    const answer = parseKnowledgeAnswer(result.text, [probeCitation]);
    return answer.answer.trim() === 'NEKO_PROBE_KNOWLEDGE_OK';
  }
  if (selection.role === 'moderation') {
    const result = await transport.infer(selection, {
      messages: [{role: 'user', content: 'Return the JSON object {"status":"ready"} with no other fields.'}],
      responseSchema: probeSchema,
    });
    const value = JSON.parse(result.text);
    return result.finishReason === 'stop' && result.toolCalls.length === 0 &&
      value !== null && typeof value === 'object' &&
      Object.keys(value).length === 1 && value.status === 'ready';
  }
  if (selection.role === 'agent') {
    const messages = [{role:'user',content:`Call ${probeTool.name} once with the exact search_term "${probeSearchTerm}". On receiving the tool result, reply only with its status value.`}];
    const proposal = await transport.infer(selection, {messages, tools: [probeTool]});
    const [call] = proposal.toolCalls;
    if (proposal.finishReason !== 'tool-calls' || proposal.toolCalls.length !== 1 ||
        call.name !== probeTool.name || Object.keys(call.arguments).length !== 1 ||
        call.arguments.search_term !== probeSearchTerm) return false;
    const result = await transport.infer(selection, {messages: [
      ...messages,
      {role: 'assistant', content: '', toolCalls: [call]},
      {role: 'tool', content: '{"status":"NEKO_PROBE_OK"}', toolCallId: call.id},
    ]});
    return result.finishReason === 'stop' && result.toolCalls.length === 0 && result.text.trim() === 'NEKO_PROBE_OK';
  }
  const result = await transport.infer(selection, {
    messages: [{role: 'user', content: 'Plain text connectivity check. Respond with the single word Ready.'}],
  });
  return result.finishReason === 'stop' && Boolean(result.text.trim());
}

async function probeModels({router}, purposes = roles) {
  const transport = new AiInferenceTransport(name => process.env[name]);
  const results = [];
  for (const role of purposes) {
    const selection = router.select(role);
    try {
      const ok = await probeRole(transport, selection);
      results.push(ok ? {role, ok} : {role, ok, code: 'UNEXPECTED_PROBE_OUTPUT'});
    } catch (error) {
      results.push({role, ok:false, code: error instanceof AiTransportError ? error.code : 'UNEXPECTED_PROBE_OUTPUT'});
    }
  }
  return results;
}

function listModels({bytes, revision}) {
  const {bindings, models} = JSON.parse(bytes.toString('utf8'));
  return {
    command: 'list',
    revision,
    bindings,
    profiles: models.map(({id, modelVersion, capabilities}) => ({
      id, modelVersion: modelVersion ?? null, capabilities,
    })),
  };
}

function compareModels(active, candidate) {
  const fields = ['profileId', 'providerId', 'adapter', 'baseUrl', 'model', 'modelVersion',
    'apiKeyEnv', 'capabilities', 'contextWindowTokens', 'maxOutputTokens'];
  const results = roles.map(role => {
    const before = active.router.select(role);
    const after = candidate.router.select(role);
    const changedFields = fields.filter(field => {
      if (field === 'capabilities') {
        return !isDeepStrictEqual([...before.capabilities].sort(), [...after.capabilities].sort());
      }
      return before[field] !== after[field];
    });
    return { role, activeProfile: before.profileId, candidateProfile: after.profileId, changedFields };
  });
  return { command: 'diff', activeRevision: active.revision, candidateRevision: candidate.revision, results };
}

async function probeAndPublishChange(target, original, candidate, purposes) {
  const results = candidate === original ? [] : await probeModels(candidate, purposes);
  if (results.some(result => !result.ok)) {
    console.info(JSON.stringify({command, revision: original.revision, results}));
    process.exitCode = 1;
    return;
  }
  const revision = await publishSnapshot(target, original, candidate);
  console.info(JSON.stringify({command, revision, results}));
}

async function verifyActive(expectedRevision, {addresses, waitMs, requiredRoles}) {
  const token = process.env.NEKO_AI_STATUS_TOKEN;
  if (!token || !/^[A-Za-z0-9._~-]{1,8192}$/.test(token)) throw Error('STATUS_TOKEN_REQUIRED');
  const endpoints = addresses.map(address => {
    let url;
    try { url = new URL(address); }
    catch { throw Error('INVALID_STATUS_ENDPOINT'); }
    const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
    if ((url.protocol !== 'https:' && !(loopback && url.protocol === 'http:')) ||
        url.username || url.password || url.search || url.hash) throw Error('INVALID_STATUS_ENDPOINT');
    url.pathname = url.pathname.replace(/\/+$/, '') + '/api/v2/ai/availability';
    return url;
  });
  const check = async (endpoint, index, timeout) => {
    const target = index + 1;
    try {
      const result = await requestJson(endpoint, { headers: { authorization: `Bearer ${token}` }, timeout, limit: 8192 });
      if (result?.code !== 200 || !result.data || !Object.hasOwn(result.data, 'model_config_revision')) {
        return { target, ok: false, code: 'STATUS_UNSUPPORTED' };
      }
      const revision = result.data.model_config_revision;
      if (revision === null) return { target, ok: false, code: 'MODEL_UNCONFIGURED' };
      if (!Number.isSafeInteger(revision) || revision < 1 || revision > MAX_STORED_MODEL_REVISION) {
        return { target, ok: false, code: 'STATUS_UNSUPPORTED' };
      }
      if (revision !== expectedRevision) return { target, ok: false, revision, code: 'REVISION_MISMATCH' };
      if (requiredRoles.length) {
        const inference = result.data.inference;
        const flag = role => inference?.[role === 'agent' ? 'group' : role];
        if (requiredRoles.some(role => typeof flag(role) !== 'boolean')) {
          return { target, ok: false, revision, code: 'STATUS_UNSUPPORTED' };
        }
        const unreadyRoles = requiredRoles.filter(role => !flag(role));
        if (unreadyRoles.length) return { target, ok: false, revision, code: 'INFERENCE_UNAVAILABLE', unreadyRoles };
      }
      return { target, ok: true, revision };
    } catch {
      return { target, ok: false, code: 'STATUS_UNAVAILABLE' };
    }
  };
  const deadline = performance.now() + waitMs;
  let results;
  do {
    const timeout = waitMs ? Math.max(1, Math.min(5000, Math.ceil(deadline - performance.now()))) : 5000;
    results = await Promise.all(endpoints.map((endpoint, index) => check(endpoint, index, timeout)));
    const remaining = deadline - performance.now();
    if (!waitMs || remaining <= 0 || results.every(result => result.ok) ||
        results.some(result => !result.ok && (result.code === 'STATUS_UNSUPPORTED' || result.revision > expectedRevision))) break;
    await delay(Math.min(500, remaining));
  } while (performance.now() < deadline);
  console.info(JSON.stringify({ command: 'verify-active', expectedRevision, results }));
  if (results.some(result => !result.ok)) process.exitCode = 1;
}

function parseRoles(value) {
  const requested = value.split(',');
  if (requested.some(role => !roles.includes(role)) || new Set(requested).size !== requested.length) return null;
  return requested;
}

function parseProbeRoles(options) {
  if (!options.length) return roles;
  if (options.length !== 2 || options[0] !== '--roles') return null;
  return parseRoles(options[1]);
}

function parseVerifyOptions(values) {
  const firstOption = values.findIndex(value => value.startsWith('--'));
  const addresses = firstOption === -1 ? values : values.slice(0, firstOption);
  const options = firstOption === -1 ? [] : values.slice(firstOption);
  if (!addresses.length || options.length % 2) return null;
  let waitMs = 0;
  let requiredRoles = [];
  for (let i = 0; i < options.length; i += 2) {
    const [flag, value] = [options[i], options[i + 1]];
    if (flag === '--wait-ms' && !waitMs && /^[1-9]\d{0,4}$/.test(value) && Number(value) <= 60000) {
      waitMs = Number(value);
    } else if (flag === '--require-ready' && !requiredRoles.length) {
      const requested = parseRoles(value);
      if (!requested) return null;
      requiredRoles = requested;
    } else return null;
  }
  return { addresses, waitMs, requiredRoles };
}

const [first, second, third] = args;
const inspecting = ['check', 'list'].includes(command) && args.length === 1 && first;
const probing = command === 'probe' && first && parseProbeRoles(args.slice(1));
const comparing = command === 'diff' && args.length === 2 && first && second;
const explicitRollback = command === 'rollback' || command === 'rollback-checked';
const publishing = (command === 'publish' || command === 'publish-checked' || explicitRollback) &&
  args.length === 3 && first && second && validRevision(third) && (!explicitRollback || third !== '0');
const binding = ['bind', 'bind-checked'].includes(command) && args.length >= 4 && args.length % 2 === 0 &&
  args.every(Boolean) && validRevision(second) && second !== '0';
const restoring = ['rollback-last', 'rollback-last-checked'].includes(command) && args.length === 2 &&
  first && validRevision(second) && second !== '0';
const verifying = command === 'verify-active' && validRevision(first) && first !== '0' &&
  parseVerifyOptions(args.slice(1));

if (!inspecting && !probing && !comparing && !publishing && !binding && !restoring && !verifying) {
  console.error([
    'Usage: node --experimental-strip-types scripts/ai-model-config.mjs <command> [arguments]',
    '  check|list <configuration>',
    '  probe <configuration> [--roles knowledge,writing,agent,moderation]',
    '  diff <active> <candidate>',
    '  publish|publish-checked <candidate> <active> <expected-revision>',
    '  rollback|rollback-checked <previous> <active> <expected-revision>',
    '  bind|bind-checked <active> <expected-revision> <role> <profile> [<role> <profile> ...]',
    '  rollback-last|rollback-last-checked <active> <expected-revision>',
    '  verify-active <expected-revision> <backend-base>... [--wait-ms 1..60000] [--require-ready knowledge,writing,agent,moderation]',
  ].join('\n'));
  process.exitCode = 2;
} else {
  try {
    if (verifying) {
      await verifyActive(Number(first), verifying);
    } else if (comparing) {
      const [active, candidate] = await Promise.all([readModelConfigFile(first), readModelConfigFile(second)]);
      console.info(JSON.stringify(compareModels(active, candidate)));
    } else if (command === 'bind-checked') {
      const target = resolve(first);
      const bindings = parseBindings(args.slice(2));
      const original = await readActive(target, Number(second));
      const {candidate, purposes} = bind(original, bindings);
      await probeAndPublishChange(target, original, candidate, purposes);
    } else if (command === 'rollback-last-checked' || command === 'rollback-checked') {
      const target = resolve(explicitRollback ? second : first);
      const original = await readActive(target, Number(explicitRollback ? third : second));
      const candidate = explicitRollback
        ? restoreRevision(await readModelConfigFile(first), original)
        : await restorePrevious(`${target}.history`, original);
      await probeAndPublishChange(target, original, candidate);
    } else if (binding || restoring) {
      const bindings = binding ? parseBindings(args.slice(2)) : null;
      const revision = await publish(resolve(first), Number(second), (current, directory) =>
        bindings ? bind(current, bindings).candidate : restorePrevious(directory, current));
      console.info(JSON.stringify({ command, revision }));
    } else {
      const candidate = await readModelConfigFile(first);
      if (command === 'list') {
        console.info(JSON.stringify(listModels(candidate)));
      } else if (probing || command === 'publish-checked') {
        const target = command === 'publish-checked' ? resolve(second) : null;
        const expected = Number(third);
        let original = null;
        if (target !== null) {
          original = await readActive(target, expected);
          if (candidate.revision <= expected) throw Error('REVISION_REUSED');
        }
        const results = await probeModels(candidate, probing || roles);
        const ok = results.every(result => result.ok);
        if (target !== null && ok) await publishSnapshot(target, original, candidate);
        console.info(JSON.stringify({ command, revision: candidate.revision, results }));
        if (!ok) process.exitCode = 1;
      } else {
        const revision = publishing ? await publish(resolve(second), Number(third), current => {
          return command === 'publish' ? candidate : restoreRevision(candidate, current);
        }) : candidate.revision;
        console.info(JSON.stringify({ command, revision }));
      }
    }
  } catch (error) {
    const codes = new Set(['INVALID_CONFIGURATION', 'PUBLICATION_BUSY', 'STALE_CONFIGURATION', 'REVISION_REUSED',
      'REVISION_LIMIT', 'UNKNOWN_ROLE', 'DUPLICATE_ROLE', 'ROLLBACK_REQUIRES_OLDER_CONFIGURATION', 'NO_PREVIOUS_CONFIGURATION',
      'CONFIGURATION_HISTORY_CONFLICT', 'STATUS_TOKEN_REQUIRED', 'INVALID_STATUS_ENDPOINT']);
    const code = [error.code, error.message].find(value => codes.has(value)) ?? 'MODEL_CONFIG_IO_ERROR';
    console.error(`Model configuration ${command} failed: ${code}`);
    process.exitCode = 1;
  }
}
