import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { requestJson } from './http.mjs';
import { openOracleState, positiveId, readTokenClaims } from './oracle-state.mjs';

const names = ['nuxt', 'go', 'rust'];
const scenarioUrl = new URL('../../specifications/scenarios/backend-comparison.json', import.meta.url);
const redacted = '[redacted]';
const fixtureSymbols = { userId: '$userId', sessionId: '$sessionId', postId: '$postId', postContent: '$postContent' };
const own = (value, key) => value !== null && typeof value === 'object' && Object.hasOwn(value, key);
const snake = value => value.replace(/([a-z\d])([A-Z])/gu, '$1_$2').toLowerCase();
const field = (object, path) => path.split('.').reduce((value, key) => own(value, key) ? value[key] : undefined, object);
const replacePaths = (path, vars) => path.replace(/\{([A-Za-z]+)\}/gu, (_, key) => encodeURIComponent(vars[key]));

function bodyFrom(template, vars) {
  if (typeof template === 'string' && template.startsWith('$')) return vars[template.slice(1)];
  if (Array.isArray(template)) return template.map(item => bodyFrom(item, vars));
  if (template !== null && typeof template === 'object') {
    return Object.fromEntries(Object.entries(template).map(([key, value]) => [key, bodyFrom(value, vars)]));
  }
  return template;
}

function tokenFor(token, userId, sessionId, type) {
  const claims = readTokenClaims(token);
  return claims?.userId === userId && claims.sessionId === sessionId && claims.type === type;
}

function captures(step, body, vars) {
  const values = Object.fromEntries(Object.entries(step.capture ?? {}).map(([key, path]) => [key, field(body, path)]));
  if (step.probe === 'sessionActive') {
    const { userId, sessionId, accessToken, refreshToken } = values;
    if (!positiveId(userId) || typeof sessionId !== 'string' || !sessionId || sessionId.length > 128 ||
        !tokenFor(accessToken, userId, sessionId, 'access') || !tokenFor(refreshToken, userId, sessionId, 'refresh')) return false;
    Object.assign(vars, values, { originalAccessToken: accessToken });
  } else if (Object.hasOwn(values, 'rotatedRefreshToken')) {
    if (!tokenFor(values.accessToken, vars.userId, vars.sessionId, 'access') ||
        !tokenFor(values.rotatedRefreshToken, vars.userId, vars.sessionId, 'refresh')) return false;
    Object.assign(vars, values);
  } else if (Object.hasOwn(values, 'postId')) {
    if (!positiveId(values.postId)) return false;
    vars.postId = values.postId;
  }
  return true;
}

function ready(step, state) {
  const { vars, sessionOwned, postOwned } = state;
  if ((step.auth || step.path.includes('/tokens/current')) && !sessionOwned) return false;
  if (step.id === 'reject-old-refresh' && !vars.rotatedRefreshToken) return false;
  if (step.path.includes('{postId}') && !postOwned) return false;
  return true;
}

async function observe(step, context) {
  const { target, vars, db, timeoutMs, request } = context;
  const observation = { id: step.id, status: null, body: null, probe: null };
  if (step.probe) observation.probe = { name: step.probe, passed: false };
  if (!ready(step, context)) {
    observation.error = 'missing-previous-proof';
    return observation;
  }
  if (step.probe === 'sessionActive') context.loginAttempted = true;
  if (step.probe === 'postCreated') context.postAttempted = true;
  let response;
  try {
    response = await request(target, {
      method: step.method, path: replacePaths(step.path, vars),
      body: step.body === undefined ? undefined : bodyFrom(step.body, vars),
      token: step.auth ? vars.accessToken : undefined, timeoutMs,
      headers: step.probe === 'sessionActive' ? { 'X-Device-Info': vars.sessionMarker } : undefined,
    });
    if (!Number.isInteger(response?.status) || !Object.hasOwn(response, 'body')) throw new Error('invalid-observation');
    observation.status = response.status;
    observation.body = response.body;
    if (step.capture && response.status === step.status && !captures(step, response.body, vars)) {
      observation.error = 'invalid-captured-fields';
    }
  } catch (error) {
    if (Number.isInteger(error?.status) && error.status >= 100 && error.status <= 599) observation.status = error.status;
    observation.error = 'http-request-failed';
    if (step.probe === 'postCreated') context.postTransportFailed = true;
  }
  if (step.probe) {
    try {
      observation.probe.passed = (await db.assert(step.probe, vars)) === true;
    } catch {
      observation.probe.reason = 'oracle-assertion-unavailable';
    }
    if (step.probe === 'sessionActive') context.sessionOwned = observation.probe.passed;
    if (step.probe === 'postCreated') context.postOwned = observation.probe.passed;
    if (step.probe === 'postDeleted') context.postDeleted = observation.probe.passed;
  }
  return observation;
}

async function cleanupPost(context) {
  const { target, vars, db, timeoutMs, request, postTransportFailed } = context;
  if (context.postDeleted) return true;
  const postId = context.postOwned ? vars.postId : await db.findPost(vars);
  if (postId === null && !postTransportFailed) return true;
  if (!positiveId(postId)) return false;
  const response = await request(target, {
    method: 'DELETE', path: `/api/v2/posts/${postId}`, token: vars.accessToken, timeoutMs,
  });
  return response.status === 200 && await db.assert('postDeleted', { ...vars, postId }) === true;
}

async function cleanupSession(context) {
  const { target, vars, db, timeoutMs, request } = context;
  if (!context.sessionOwned) return false;
  const response = await request(target, {
    method: 'DELETE', path: '/api/v2/auth/tokens/current', token: vars.accessToken, timeoutMs,
    body: { refresh_token: vars.rotatedRefreshToken ?? vars.refreshToken },
  });
  return response.status === 200 && await db.assert('sessionRevoked', vars) === true;
}

async function clean(action, operation) {
  try {
    return await operation() ? { action, passed: true } : { action, passed: false, reason: 'cleanup-unconfirmed' };
  } catch {
    return { action, passed: false, reason: 'cleanup-failed' };
  }
}

async function runTarget(target, scenario, { timeoutMs, request, oracle }) {
  const vars = {
    account: target?.account,
    password: target?.password,
    postContent: `nekotribe-parity-${randomUUID()}`,
    sessionMarker: `nekotribe-parity-session-${randomUUID()}`,
  };
  const result = { cases: [], cleanup: [] };
  let db;
  try {
    if (typeof vars.account !== 'string' || !vars.account || typeof vars.password !== 'string' || !vars.password) {
      result.error = 'fixture-unavailable';
      return { result, vars };
    }
    db = await oracle(target.oracle, { timeoutMs });
  } catch {
    result.error = 'oracle-unavailable';
    return { result, vars };
  }
  const context = { target, vars, db, timeoutMs, request };
  try {
    for (const entry of scenario.cases) {
      const recorded = { id: entry.id, steps: [] };
      result.cases.push(recorded);
      for (const step of entry.steps) recorded.steps.push(await observe(step, context));
    }
  } finally {
    if (context.postAttempted) result.cleanup.push(await clean('post', () => cleanupPost(context)));
    if (context.loginAttempted) result.cleanup.push(await clean('session', () => cleanupSession(context)));
    const release = await clean('oracle', async () => { await db.close(); return true; });
    if (!release.passed) result.cleanup.push(release);
  }
  return { result, vars };
}

function validTimestamp(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/u.exec(value);
  if (!match || !Number.isFinite(Date.parse(value))) return false;
  const [year, month, day] = match.slice(1).map(Number);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  return month >= 1 && month <= 12 && day >= 1 &&
    day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];
}

function redact(value, secrets) {
  let normalized = value;
  for (const secret of secrets) {
    if (normalized === secret) return redacted;
    if (secret.length >= 6) normalized = normalized.replaceAll(secret, redacted);
  }
  return normalized;
}

function normalize(value, vars, secrets, key = '') {
  if (Array.isArray(value)) return value.map(item => normalize(item, vars, secrets, key));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(
    ([name, item]) => [redact(name, secrets), normalize(item, vars, secrets, name)],
  ));
  const name = snake(key);
  if (typeof value === 'string' && /(?:^|_)(?:access_token|refresh_token|token|password|secret|credential|credentials|authorization|cookie|connect_string|dsn|api_key|stack|exception)$/u.test(name)) return redacted;
  if (value === vars.userId && /(?:^|_)(?:user|author|actor|owner)_id$/u.test(name)) return fixtureSymbols.userId;
  if (value === vars.postId && /(?:^|_)post_id$/u.test(name)) return fixtureSymbols.postId;
  if (value === vars.sessionId && name === 'session_id') return fixtureSymbols.sessionId;
  if (typeof value !== 'string') return value;
  if ((name === 'timestamp' || name.endsWith('_at')) && validTimestamp(value)) return '$timestamp';
  if (value === vars.postContent) return fixtureSymbols.postContent;
  if (/\b(?:ORA-\d{5}|NJS-\d{3}|DPI-\d{4}):|\n\s+at\s+/u.test(value)) return redacted;
  return redact(value, secrets);
}

function firstDifference(left, right, path = '') {
  if (left === right) return null;
  if (left && right && typeof left === 'object' && typeof right === 'object' && Array.isArray(left) === Array.isArray(right)) {
    const keys = Array.isArray(left)
      ? Array.from({ length: Math.max(left.length, right.length) }, (_, index) => String(index))
      : [...new Set([...Object.keys(left), ...Object.keys(right)])].sort();
    for (const key of keys) {
      const at = `${path}/${key.replaceAll('~', '~0').replaceAll('/', '~1')}`;
      if (!own(left, key) || !own(right, key)) {
        return { path: at, expected: own(left, key) ? left[key] : '[missing]', actual: own(right, key) ? right[key] : '[missing]' };
      }
      const difference = firstDifference(left[key], right[key], at);
      if (difference) return difference;
    }
    return null;
  }
  return { path: path || '/', expected: left, actual: right };
}

function differencesFor(scenario, targets) {
  const differences = [];
  for (const [target, result] of Object.entries(targets)) {
    if (result.error) differences.push({ kind: 'missing', target, reason: result.error });
    for (const entry of result.cleanup) {
      if (!entry.passed) differences.push({ kind: 'cleanup', target, action: entry.action, reason: entry.reason });
    }
  }
  for (const entry of scenario.cases) {
    for (const step of entry.steps) {
      let reference;
      for (const [target, result] of Object.entries(targets)) {
        const seen = result.cases.find(item => item.id === entry.id)?.steps.find(item => item.id === step.id);
        const context = { target, caseId: entry.id, stepId: step.id };
        if (seen?.status == null || seen.error) {
          differences.push({ kind: 'missing', ...context, reason: seen?.error ?? 'observation-missing' });
        }
        if (step.probe && seen?.probe?.passed !== true) {
          differences.push({ kind: 'probe', ...context, probe: step.probe, expected: true,
            actual: seen?.probe?.passed ?? null, reason: seen?.probe?.reason });
        }
        if (seen?.status == null) continue;
        if (seen.status !== step.status) differences.push({ kind: 'status', ...context, expected: step.status, actual: seen.status });
        if (!reference) {
          reference = { target, body: seen.body, status: seen.status };
          continue;
        }
        if (seen.status !== reference.status) differences.push({ kind: 'status', ...context,
          expected: reference.status, actual: seen.status, reference: reference.target });
        const change = firstDifference(reference.body, seen.body);
        if (change) differences.push({ kind: 'response', ...context, reference: reference.target, ...change });
      }
    }
  }
  return differences;
}

export async function runReplay(targets, { timeoutMs }, dependencies = {}) {
  const scenario = JSON.parse(await readFile(scenarioUrl, 'utf8'));
  if (scenario.id !== 'BACKEND-COMPARISON' || scenario.revision !== 1 || !Array.isArray(scenario.cases)) {
    throw new Error('unsupported backend comparison scenario');
  }
  const request = dependencies.requestJson ?? requestJson;
  const oracle = dependencies.openOracleState ?? openOracleState;
  const observations = await Promise.all(names.map(async name => [
    name, await runTarget(targets?.[name], scenario, { timeoutMs, request, oracle }),
  ]));
  const secrets = [...new Set(observations.flatMap(([name, { vars }]) => [
    targets?.[name]?.account, targets?.[name]?.password,
    targets?.[name]?.oracle?.user, targets?.[name]?.oracle?.password, targets?.[name]?.oracle?.connectString,
    vars.originalAccessToken, vars.accessToken, vars.refreshToken, vars.rotatedRefreshToken,
    vars.sessionMarker,
  ]).filter(value => typeof value === 'string' && value))].sort((left, right) => right.length - left.length);
  const results = Object.fromEntries(observations.map(([name, { result, vars }]) => {
    for (const entry of result.cases) {
      for (const step of entry.steps) step.body = normalize(step.body, vars, secrets);
    }
    return [name, result];
  }));
  const differences = differencesFor(scenario, results);
  for (const [name, result] of Object.entries(results)) {
    result.passed = !differences.some(difference => difference.target === name || difference.reference === name);
  }
  return { passed: differences.length === 0, differences, targets: results };
}
