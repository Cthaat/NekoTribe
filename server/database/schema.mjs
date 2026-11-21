import { createHash } from 'node:crypto';
import { schemaFeatures } from './schema-definition.mjs';

export class SchemaReadinessError extends Error {
  constructor() { super('Database schema is not ready; run the explicit migration tool.'); }
}
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const identifier = value => {
  if (!/^[A-Z][A-Z0-9_]{0,127}$/.test(value)) throw new Error('Invalid schema identifier.');
  return value;
};
// Preserve case and spaces inside SQL string literals, normalize only SQL syntax.
export function normalizeExpression(value) {
  let normalized = String(value ?? '').trim().split(/('(?:[^']|'')*')/)
    .map((part, i) => i % 2 ? part : part.replace(/[\s"]/g, '').toUpperCase()).join('');
  // Recognize harmless Oracle parentheses and IN-set ordering without weakening
  // comparisons of arbitrary predicates or case-sensitive SQL string values.
  while (normalized.startsWith('(') && normalized.endsWith(')')) {
    let depth = 0; let closesEarly = false; let quoted = false;
    for (let i = 0; i < normalized.length - 1; i++) {
      if (normalized[i] === "'") {
        if (quoted && normalized[i + 1] === "'") { i++; continue; }
        quoted = !quoted;
      }
      if (!quoted) {
        if (normalized[i] === '(') depth++;
        if (normalized[i] === ')' && --depth === 0) { closesEarly = true; break; }
      }
    }
    if (closesEarly) break;
    normalized = normalized.slice(1, -1);
  }
  const set = normalized.match(/^([A-Z][A-Z0-9_]*)IN\((.*)\)$/);
  if (set) {
    const members = parts(set[2]);
    if (members.every(x => /^(?:'(?:[^']|'')*'|-?\d+(?:\.\d+)?)$/.test(x))) normalized = `${set[1]}IN(${[...new Set(members)].sort().join(',')})`;
  }
  return normalized;
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const inFlightReadiness = new WeakMap();
// Share concurrent checks on the same live connection only. Never cache a ready
// result: once settled, the next call must inspect that connection/schema again.
export function coalesceReadinessCheck(connection, feature, check) {
  let active = inFlightReadiness.get(connection);
  if (!active) { active = new Map(); inFlightReadiness.set(connection, active); }
  if (active.has(feature)) return active.get(feature);
  const pending = Promise.resolve().then(check).finally(() => {
    active.delete(feature);
    if (!active.size) inFlightReadiness.delete(connection);
  });
  active.set(feature, pending);
  return pending;
}

function parts(value) {
  const result = []; let start = 0; let depth = 0; let quoted = false;
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "'") {
      if (quoted && value[i + 1] === "'") { i++; continue; }
      quoted = !quoted;
    }
    if (!quoted) {
      if (value[i] === '(') depth++;
      if (value[i] === ')') depth--;
      if (value[i] === ',' && !depth) { result.push(value.slice(start, i).trim()); start = i + 1; }
    }
  }
  result.push(value.slice(start).trim()); return result;
}

// This parser accepts only the reviewed, fixed DDL grammar in schema-definition.mjs.
// Unexpected definitions fail at import; arbitrary SQL is never accepted from CLI input.
export function describeStep(step) {
  if (!['table', 'column'].includes(step.kind)) return step;
  const table = step.sql.match(/(?:CREATE|ALTER) TABLE\s+(\w+)/)[1].toUpperCase();
  const columns = []; const constraints = [];
  function constraint(raw, name, column) {
    const value = { name: name || `NT13_${digest([table, raw]).slice(0, 20).toUpperCase()}` };
    if (raw.includes('PRIMARY KEY')) Object.assign(value, { type: 'P', columns: column ? [column] : parts(raw.match(/PRIMARY KEY\s*\(([^)]+)\)/)[1]).map(x => x.toUpperCase()) });
    else if (raw.startsWith('UNIQUE')) Object.assign(value, { type: 'U', columns: parts(raw.match(/UNIQUE\s*\(([^)]+)\)/)[1]).map(x => x.toUpperCase()) });
    else if (raw.startsWith('FOREIGN KEY')) {
      const m = raw.match(/FOREIGN KEY\s*\(([^)]+)\)\s*REFERENCES\s+(\w+)\s*\(([^)]+)\)/);
      Object.assign(value, { type: 'R', columns: parts(m[1]).map(x => x.toUpperCase()), referencedTable: m[2].toUpperCase(), referencedColumns: parts(m[3]).map(x => x.toUpperCase()), deleteRule: raw.includes('ON DELETE CASCADE') ? 'CASCADE' : 'NO ACTION' });
    } else {
      const m = raw.match(/CHECK\s*\(([\s\S]*)\)/);
      if (!m) throw new Error('Unsupported schema constraint definition.');
      Object.assign(value, { type: 'C', expression: m[1] });
      if (['N_MODERATION_REPORTS', 'N_MODERATION_CASES'].includes(table) && m[1].startsWith('target_type IN')) value.legacyExpression = "target_type IN ('post', 'comment', 'user')";
    }
    constraints.push(value);
  }
  for (const raw of parts(step.sql.slice(step.sql.indexOf('(') + 1, step.sql.lastIndexOf(')')))) {
    const named = raw.match(/^CONSTRAINT\s+(\w+)\s+([\s\S]+)$/);
    if (named) { constraint(named[2], named[1].toUpperCase()); continue; }
    const m = raw.match(/^(\w+)\s+(VARCHAR2\(\d+(?: CHAR)?\)|NUMBER(?:\(\d+(?:,\s*\d+)?\))?|TIMESTAMP|CLOB)([\s\S]*)$/);
    if (!m) throw new Error('Unsupported schema column definition.');
    const tail = m[3]; const defaultValue = tail.match(/\bDEFAULT\s+(.+?)(?=\s+NOT NULL|\s+CHECK|$)/);
    const charUsed = m[2].endsWith(' CHAR)') ? 'C' : undefined;
    columns.push({ name: m[1].toUpperCase(), type: m[2].replace(' CHAR)', ')').replace(/\s/g, ''), nullable: !/NOT NULL|PRIMARY KEY/.test(tail), default: defaultValue?.[1] ?? null, ...(charUsed ? { charUsed } : {}) });
    if (/PRIMARY KEY|CHECK\s*\(/.test(tail)) constraint(tail, undefined, m[1].toUpperCase());
  }
  return { ...step, table, columns, constraints };
}

const features = schemaFeatures.map(f => ({ ...f, steps: f.steps.map(describeStep) }));
const steps = features.flatMap(f => f.steps);
const ledger = describeStep({ id: 'ledger', kind: 'table', name: 'N_SCHEMA_MIGRATIONS', sql: 'CREATE TABLE N_SCHEMA_MIGRATIONS (step_id VARCHAR2(128) PRIMARY KEY, checksum VARCHAR2(64) NOT NULL, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)' });
export function planSchema() {
  return features.map(f => ({ feature: f.id, steps: f.steps.map(s => ({ id: s.id, kind: s.kind, name: s.name, checksum: digest(s) })) }));
}
async function rows(adapter, sql, binds = {}) {
  const result = await adapter.execute(sql, binds);
  if (!result || !Array.isArray(result.rows)) throw new Error('Schema adapter must return object rows.');
  return result.rows;
}
async function exists(adapter, type, name) {
  const sources = { table: ['user_tables', 'table_name'], sequence: ['user_sequences', 'sequence_name'] };
  const [view, column] = sources[type];
  return (await rows(adapter, `SELECT ${column} AS NAME FROM ${view} WHERE ${column} = :name`, { name })).length > 0;
}
async function constraintsFor(adapter, table) {
  const constraints = await rows(adapter, `SELECT c.constraint_name, c.constraint_type, c.search_condition_vc, c.delete_rule, c.status, c.validated, r.table_name AS referenced_table, c.r_owner AS referenced_owner
    FROM user_constraints c LEFT JOIN user_constraints r ON r.constraint_name = c.r_constraint_name AND c.r_owner = USER WHERE c.table_name = :table_name`, { table_name: table });
  const columns = await rows(adapter, `SELECT c.constraint_name, c.column_name, c.position, r.column_name AS referenced_column
    FROM user_cons_columns c LEFT JOIN user_constraints f ON f.constraint_name = c.constraint_name
    LEFT JOIN user_cons_columns r ON r.constraint_name = f.r_constraint_name AND r.position = c.position AND f.r_owner = USER
    WHERE c.table_name = :table_name ORDER BY c.constraint_name, c.position`, { table_name: table });
  return constraints.map(c => ({ ...c, columns: columns.filter(x => x.CONSTRAINT_NAME === c.CONSTRAINT_NAME).map(x => x.COLUMN_NAME), referencedColumns: columns.filter(x => x.CONSTRAINT_NAME === c.CONSTRAINT_NAME).map(x => x.REFERENCED_COLUMN) }));
}
function matchingConstraint(expected, actual) {
  if (actual.CONSTRAINT_TYPE !== expected.type || actual.STATUS !== 'ENABLED' || actual.VALIDATED !== 'VALIDATED') return false;
  if (expected.type === 'C') return normalizeExpression(actual.SEARCH_CONDITION_VC) === normalizeExpression(expected.expression);
  return same(actual.columns, expected.columns) && (expected.type !== 'R' || (actual.REFERENCED_TABLE === expected.referencedTable && actual.DELETE_RULE === expected.deleteRule && same(actual.referencedColumns, expected.referencedColumns)));
}
function matchingColumn(expected, actual) {
  if (!actual || actual.NULLABLE !== (expected.nullable ? 'Y' : 'N')) return false;
  if (normalizeExpression(actual.DATA_DEFAULT) !== normalizeExpression(expected.default)) return false;
  const number = expected.type.match(/^NUMBER(?:\((\d+)(?:,(\d+))?\))?$/);
  if (number) return actual.DATA_TYPE === 'NUMBER' && (number[1] ? Number(actual.DATA_PRECISION) === Number(number[1]) && Number(actual.DATA_SCALE) === Number(number[2] ?? 0) : actual.DATA_PRECISION == null && actual.DATA_SCALE == null);
  const varchar = expected.type.match(/^VARCHAR2\((\d+)\)$/);
  if (varchar) return actual.DATA_TYPE === 'VARCHAR2' && Number(actual.CHAR_LENGTH) === Number(varchar[1]) &&
    (expected.charUsed === undefined || expected.charUsed === actual.CHAR_USED);
  if (expected.type === 'TIMESTAMP') return actual.DATA_TYPE === 'TIMESTAMP(6)';
  return actual.DATA_TYPE === expected.type;
}

async function inspect(adapter, step) {
  if (step.kind === 'sequence') {
    const found = await rows(adapter, 'SELECT sequence_name, increment_by, cycle_flag FROM user_sequences WHERE sequence_name = :name', { name: step.name });
    return !found.length ? 'missing' : Number(found[0].INCREMENT_BY) === 1 && found[0].CYCLE_FLAG === 'N' ? 'ready' : 'incompatible';
  }
  if (step.kind === 'index') {
    const found = await rows(adapter, 'SELECT index_name, table_name, uniqueness, status FROM user_indexes WHERE index_name = :name', { name: step.name });
    if (!found.length) return 'missing';
    const cols = await rows(adapter, 'SELECT column_name, descend FROM user_ind_columns WHERE index_name = :name ORDER BY column_position', { name: step.name });
    const expected = step.sql.match(/ON\s+(\w+)\s*\(([^)]+)\)/);
    return found[0].TABLE_NAME === expected[1].toUpperCase() && found[0].UNIQUENESS === 'NONUNIQUE' && found[0].STATUS === 'VALID' && same(cols.map(c => c.COLUMN_NAME), parts(expected[2]).map(x => x.toUpperCase())) && cols.every(c => c.DESCEND === 'ASC') ? 'ready' : 'incompatible';
  }
  if (step.kind === 'seed') {
    if (!await exists(adapter, 'table', 'N_MODERATION_SETTINGS')) return 'missing';
    const found = await rows(adapter, 'SELECT setting_key, value_type FROM n_moderation_settings WHERE setting_key = :setting_key', { setting_key: step.setting.key });
    // Values/labels are administrator-owned after insertion, never overwritten.
    return !found.length ? 'missing' : found[0].VALUE_TYPE === step.setting.value_type ? 'ready' : 'incompatible';
  }
  if (!await exists(adapter, 'table', step.table)) return step.kind === 'table' ? 'missing' : 'incompatible';
  const found = await rows(adapter, 'SELECT column_name, data_type, data_precision, data_scale, char_length, nullable, data_default, char_used FROM user_tab_columns WHERE table_name = :table_name', { table_name: step.table });
  if (step.previousCharUsed || step.previousType) {
    const [expected] = step.columns;
    const actual = found.find(c => c.COLUMN_NAME === expected.name);
    if (matchingColumn(expected, actual)) return 'ready';
    const previous = step.previousType
      ? { ...expected, type: step.previousType }
      : { ...expected, charUsed: step.previousCharUsed };
    return matchingColumn(previous, actual) ? 'missing' : 'incompatible';
  }
  if (step.kind === 'column' && !found.some(c => c.COLUMN_NAME === step.columns[0].name)) return 'missing';
  for (const column of step.columns) {
    const actual = found.find(row => row.COLUMN_NAME === column.name);
    if (matchingColumn(column, actual)) continue;
    // A completed widening is valid when inspecting the original CREATE step.
    const widening = step.kind === 'table' && steps.find(later => later.table === step.table &&
      later.previousType === column.type && later.columns[0].name === column.name);
    if (!widening || !matchingColumn(widening.columns[0], actual)) return 'incompatible';
  }
  const actual = await constraintsFor(adapter, step.table);
  let repair = false;
  for (const expected of step.constraints) {
    const matches = actual.some(c => matchingConstraint(expected, c));
    const legacy = expected.legacyExpression && actual.some(c => c.CONSTRAINT_TYPE === 'C' && normalizeExpression(c.SEARCH_CONDITION_VC) === normalizeExpression(expected.legacyExpression));
    if (!matches || legacy) repair = true;
    if (expected.legacyExpression && actual.some(c => {
      if (c.CONSTRAINT_TYPE !== 'C' || !c.columns.includes('TARGET_TYPE') || matchingConstraint(expected, c)) return false;
      const expression = normalizeExpression(c.SEARCH_CONDITION_VC);
      // Oracle exposes NOT NULL as a separate check constraint. Its nullability
      // was already verified above; it is not an additional target restriction.
      const requiredNotNull = same(c.columns, ['TARGET_TYPE']) && expression === 'TARGET_TYPEISNOTNULL'
        && step.columns.some(column => column.name === 'TARGET_TYPE' && !column.nullable);
      return !requiredNotNull && expression !== normalizeExpression(expected.legacyExpression);
    })) return 'incompatible';
  }
  return repair ? 'repair' : 'ready';
}

async function recorded(adapter) {
  if (!await exists(adapter, 'table', ledger.table)) return new Map();
  if (await inspect(adapter, ledger) !== 'ready') throw new Error('Migration ledger schema is incompatible.');
  const records = await rows(adapter, 'SELECT step_id, checksum FROM n_schema_migrations');
  const expected = new Map(steps.map(s => [s.id, digest(s)]));
  for (const row of records) if (!expected.has(row.STEP_ID) || expected.get(row.STEP_ID) !== row.CHECKSUM) throw new Error('Recorded migration checksum drift; operator review required.');
  return new Map(records.map(r => [r.STEP_ID, r.CHECKSUM]));
}
async function requireOwnSchema(adapter) {
  const found = await rows(adapter, "SELECT USER AS USER_NAME, SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS SCHEMA_NAME FROM dual");
  if (!found[0]?.USER_NAME || found[0].USER_NAME !== found[0].SCHEMA_NAME) throw new Error('Connect as the target schema owner; CURRENT_SCHEMA switching is unsupported.');
}
export async function checkSchema(adapter, feature) {
  await requireOwnSchema(adapter);
  const selected = feature === undefined ? features : features.filter(f => f.id === feature);
  if (!selected.length) throw new Error('Unknown schema feature.');
  const records = await recorded(adapter);
  const result = [];
  for (const f of selected) for (const s of f.steps) result.push({ feature: f.id, id: s.id, status: await inspect(adapter, s), recorded: records.has(s.id) });
  return result;
}
export async function assertSchemaReady(adapter, feature) {
  const result = await checkSchema(adapter, feature);
  if (result.some(s => s.status !== 'ready')) throw new SchemaReadinessError();
}

async function repairConstraints(adapter, step) {
  let actual = await constraintsFor(adapter, step.table);
  for (const expected of step.constraints) {
    const legacy = expected.legacyExpression ? actual.filter(c => c.CONSTRAINT_TYPE === 'C' && normalizeExpression(c.SEARCH_CONDITION_VC) === normalizeExpression(expected.legacyExpression)) : [];
    const matched = actual.find(c => matchingConstraint(expected, c));
    const name = identifier(expected.name);
    if (!legacy.length && matched) continue;
    if (expected.type !== 'C') throw new Error('Missing key/foreign/unique constraint requires operator review.');
    const temporary = `NT13_${digest([step.table, expected]).slice(0, 20).toUpperCase()}`;
    if (!matched) {
      const desired = legacy.length ? temporary : name;
      await adapter.execute(`ALTER TABLE ${identifier(step.table)} ADD CONSTRAINT ${desired} CHECK (${expected.expression}) ENABLE VALIDATE`);
      actual = await constraintsFor(adapter, step.table);
      if (!actual.some(c => matchingConstraint(expected, c))) throw new Error('Replacement constraint verification failed.');
    }
    // A validated replacement exists before any old, narrower constraint is dropped.
    for (const old of legacy) await adapter.execute(`ALTER TABLE ${identifier(step.table)} DROP CONSTRAINT ${identifier(old.CONSTRAINT_NAME)}`);
    const replacement = matched?.CONSTRAINT_NAME ?? (legacy.length ? temporary : name);
    if (legacy.some(c => c.CONSTRAINT_NAME === name) && replacement !== name) await adapter.execute(`ALTER TABLE ${identifier(step.table)} RENAME CONSTRAINT ${identifier(replacement)} TO ${name}`);
    actual = await constraintsFor(adapter, step.table);
  }
}
async function applyStep(adapter, step, status) {
  if (status === 'incompatible') throw new Error(`Incompatible schema step: ${step.id}`);
  if (status === 'ready') return;
  if (status === 'repair') { await repairConstraints(adapter, step); return; }
  if (step.kind === 'seed') {
    const s = step.setting;
    await adapter.execute(`MERGE INTO n_moderation_settings s USING (SELECT :setting_key AS setting_key FROM dual) src ON (s.setting_key = src.setting_key)
      WHEN NOT MATCHED THEN INSERT (setting_key, setting_value, value_type, label, description) VALUES (:setting_key, :setting_value, :value_type, :label, :description)`, { setting_key: s.key, setting_value: s.value, value_type: s.value_type, label: s.label, description: s.description });
  } else if (step.kind === 'sequence') {
    let start = Number(step.sql.match(/START WITH\s+(\d+)/)[1]);
    if (await exists(adapter, 'table', step.targetTable)) {
      const maximum = await rows(adapter, `SELECT MAX(${identifier(step.targetColumn)}) AS MAX_ID FROM ${identifier(step.targetTable)}`);
      const next = Number(maximum[0]?.MAX_ID ?? 0) + 1;
      if (!Number.isSafeInteger(next)) throw new Error('Sequence start cannot be represented safely.');
      start = Math.max(start, next);
    }
    await adapter.execute(step.sql.replace(/START WITH\s+\d+/, `START WITH ${start}`));
  } else await adapter.execute(step.sql);
}
const lockExpression = "DBMS_UTILITY.GET_HASH_VALUE('NEKOTRIBE_SCHEMA:' || SYS_CONTEXT('USERENV','CURRENT_SCHEMA'), 0, 1073741823)";
export async function applySchema(adapter) {
  await requireOwnSchema(adapter);
  const lock = await adapter.execute(`BEGIN :lock_result := DBMS_LOCK.REQUEST(id => ${lockExpression}, lockmode => 6, timeout => 0, release_on_commit => FALSE); END;`, { lock_result: { out: 'number' } });
  if (lock?.outBinds?.lock_result !== 0) throw new Error('Cannot acquire schema migration session lock.');
  try {
    const records = await recorded(adapter);
    if (!await exists(adapter, 'table', ledger.table)) await adapter.execute(ledger.sql);
    if (await inspect(adapter, ledger) !== 'ready') throw new Error('Migration ledger verification failed.');
    for (const step of steps) {
      await applyStep(adapter, step, await inspect(adapter, step));
      if (await inspect(adapter, step) !== 'ready') throw new Error(`Migration verification failed: ${step.id}`);
      if (!records.has(step.id)) {
        await adapter.execute('INSERT INTO n_schema_migrations (step_id, checksum) VALUES (:step_id, :checksum)', { step_id: step.id, checksum: digest(step) });
      }
    }
    return { steps: steps.length };
  } finally {
    const released = await adapter.execute(`BEGIN :lock_result := DBMS_LOCK.RELEASE(id => ${lockExpression}); END;`, { lock_result: { out: 'number' } });
    if (released?.outBinds?.lock_result !== 0) throw new Error('Schema migration session lock release failed.');
  }
}
