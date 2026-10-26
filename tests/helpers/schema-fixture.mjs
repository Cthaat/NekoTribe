// Isolated Oracle dictionary/DDL adapter; no driver, sockets or database access.
import { readFileSync } from 'node:fs';
import { schemaFeatures } from '../../server/database/schema-definition.mjs';
import { describeStep } from '../../server/database/schema.mjs';

function columnRow(column) {
  const n = column.type.match(/^NUMBER(?:\((\d+)(?:,(\d+))?\))?$/);
  const v = column.type.match(/^VARCHAR2\((\d+)\)$/);
  return { COLUMN_NAME: column.name, DATA_TYPE: n ? 'NUMBER' : v ? 'VARCHAR2' : column.type === 'TIMESTAMP' ? 'TIMESTAMP(6)' : column.type,
    DATA_PRECISION: n?.[1] ? Number(n[1]) : null, DATA_SCALE: n?.[1] ? Number(n[2] ?? 0) : null,
    CHAR_LENGTH: v ? Number(v[1]) : 0, NULLABLE: column.nullable ? 'Y' : 'N', DATA_DEFAULT: column.default };
}
function tableState(description) {
  return { columns: description.columns.map(columnRow), constraints: description.constraints.map(c => ({ CONSTRAINT_NAME: c.name,
    CONSTRAINT_TYPE: c.type, SEARCH_CONDITION_VC: c.expression, STATUS: 'ENABLED', VALIDATED: 'VALIDATED',
    DELETE_RULE: c.deleteRule, REFERENCED_TABLE: c.referencedTable, REFERENCED_OWNER: c.type === 'R' ? 'NEKO_APP' : null,
    columns: c.columns ?? [], referencedColumns: c.referencedColumns ?? [] })) };
}
function baselineTable(source, name) {
  const start = source.toUpperCase().indexOf(`CREATE TABLE ${name} (`);
  if (start < 0) throw new Error(`Missing baseline table ${name}`);
  let depth = 0; let quoted = false;
  for (let i = source.indexOf('(', start); i < source.length; i++) {
    if (source[i] === "'") {
      if (quoted && source[i + 1] === "'") { i++; continue; }
      quoted = !quoted;
    }
    if (!quoted) {
      if (source[i] === '(') depth++;
      if (source[i] === ')' && --depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error('Unterminated baseline table');
}
export function schemaFixture({ baseline = false } = {}) {
  const state = { tables: new Map(), sequences: new Map(), indexes: new Map(), settings: new Map(), records: new Map(), calls: [], fail: () => false, lockResult: 0 };
  const sqlBaseline = baseline ? readFileSync(new URL('../../data/neko_tribe-oracle-v2.sql', import.meta.url), 'utf8') : '';
  const all = schemaFeatures.flatMap(f => f.steps);
  for (const raw of all) {
    const step = describeStep(raw);
    if (['table', 'column'].includes(step.kind)) {
      if (baseline && !state.tables.has(step.table)) state.tables.set(step.table, tableState(describeStep({ kind: 'table', sql: baselineTable(sqlBaseline, step.table) })));
      else if (!baseline && step.kind === 'table') state.tables.set(step.table, tableState(step));
      else if (!baseline) {
        const table = state.tables.get(step.table) ?? { columns: [], constraints: [] };
        table.columns.push(...step.columns.map(columnRow)); table.constraints.push(...tableState(step).constraints); state.tables.set(step.table, table);
      }
    } else if (step.kind === 'sequence') state.sequences.set(step.name, { SEQUENCE_NAME: step.name, INCREMENT_BY: 1, CYCLE_FLAG: 'N' });
    else if (step.kind === 'index') {
      const m = step.sql.match(/ON\s+(\w+)\s*\(([^)]+)\)/);
      state.indexes.set(step.name, { INDEX_NAME: step.name, TABLE_NAME: m[1].toUpperCase(), UNIQUENESS: 'NONUNIQUE', STATUS: 'VALID', columns: m[2].split(',').map(c => ({ COLUMN_NAME: c.trim().toUpperCase(), DESCEND: 'ASC' })) });
    } else state.settings.set(step.name, { SETTING_KEY: step.name, VALUE_TYPE: step.setting.value_type, SETTING_VALUE: step.setting.value });
  }
  function query(sql, binds = {}) {
    const upper = sql.toUpperCase();
    if (upper.startsWith('SELECT USER AS')) return [{ USER_NAME: 'NEKO_APP', SCHEMA_NAME: 'NEKO_APP' }];
    if (upper.includes('FROM USER_TABLES')) return state.tables.has(binds.name) ? [{ NAME: binds.name }] : [];
    if (upper.includes('FROM USER_SEQUENCES')) return state.sequences.has(binds.name) ? [state.sequences.get(binds.name)] : [];
    if (upper.includes('FROM USER_TAB_COLUMNS')) return state.tables.get(binds.table_name)?.columns ?? [];
    if (upper.includes('FROM USER_CONSTRAINTS C')) return state.tables.get(binds.table_name)?.constraints ?? [];
    if (upper.includes('FROM USER_CONS_COLUMNS C')) return (state.tables.get(binds.table_name)?.constraints ?? []).flatMap(c => c.columns.map((name, i) => ({ CONSTRAINT_NAME: c.CONSTRAINT_NAME, COLUMN_NAME: name, POSITION: i + 1, REFERENCED_COLUMN: c.referencedColumns[i] })));
    if (upper.includes('FROM USER_INDEXES')) return state.indexes.has(binds.name) ? [state.indexes.get(binds.name)] : [];
    if (upper.includes('FROM USER_IND_COLUMNS')) return state.indexes.get(binds.name)?.columns ?? [];
    if (upper.includes('FROM N_SCHEMA_MIGRATIONS')) return [...state.records].map(([STEP_ID, CHECKSUM]) => ({ STEP_ID, CHECKSUM }));
    if (upper.includes('FROM N_MODERATION_SETTINGS WHERE')) return state.settings.has(binds.setting_key) ? [state.settings.get(binds.setting_key)] : [];
    if (/^SELECT MAX\(/.test(upper)) return [{ MAX_ID: state.maxId ?? 0 }];
    return undefined;
  }
  const adapter = {
    state, query,
    async execute(sql, binds = {}) {
      state.calls.push({ sql, binds });
      if (state.fail(sql)) throw new Error('ORA-00054 secret-that-must-not-be-logged');
      const result = query(sql, binds);
      if (result !== undefined) return { rows: result };
      if (sql.includes('DBMS_LOCK.REQUEST')) return { outBinds: { lock_result: state.lockResult } };
      if (sql.includes('DBMS_LOCK.RELEASE')) return { outBinds: { lock_result: 0 } };
      if (sql.startsWith('CREATE TABLE')) {
        const description = describeStep({ kind: 'table', sql }); state.tables.set(description.table, tableState(description)); return {};
      }
      if (sql.startsWith('CREATE SEQUENCE')) {
        const name = sql.match(/CREATE SEQUENCE (\w+)/)[1].toUpperCase(); state.sequences.set(name, { SEQUENCE_NAME: name, INCREMENT_BY: 1, CYCLE_FLAG: 'N' }); return {};
      }
      if (sql.startsWith('CREATE INDEX')) {
        const name = sql.match(/CREATE INDEX (\w+)/)[1].toUpperCase(); const raw = all.find(s => s.name === name);
        const m = sql.match(/ON\s+(\w+)\s*\(([^)]+)\)/); state.indexes.set(raw.name, { INDEX_NAME: name, TABLE_NAME: m[1].toUpperCase(), UNIQUENESS: 'NONUNIQUE', STATUS: 'VALID', columns: m[2].split(',').map(c => ({ COLUMN_NAME: c.trim().toUpperCase(), DESCEND: 'ASC' })) }); return {};
      }
      if (/^ALTER TABLE \w+ ADD \(/.test(sql)) {
        const description = describeStep({ kind: 'column', sql }); const table = state.tables.get(description.table);
        table.columns.push(...description.columns.map(columnRow)); table.constraints.push(...tableState(description).constraints); return {};
      }
      let m = sql.match(/^ALTER TABLE (\w+) ADD CONSTRAINT (\w+) CHECK \(([\s\S]+)\) ENABLE VALIDATE$/);
      if (m) { state.tables.get(m[1]).constraints.push({ CONSTRAINT_NAME: m[2], CONSTRAINT_TYPE: 'C', SEARCH_CONDITION_VC: m[3], STATUS: 'ENABLED', VALIDATED: 'VALIDATED', columns: m[3].includes('target_type') ? ['TARGET_TYPE'] : [], referencedColumns: [] }); return {}; }
      m = sql.match(/^ALTER TABLE (\w+) DROP CONSTRAINT (\w+)$/);
      if (m) { const table = state.tables.get(m[1]); table.constraints = table.constraints.filter(c => c.CONSTRAINT_NAME !== m[2]); return {}; }
      m = sql.match(/^ALTER TABLE (\w+) RENAME CONSTRAINT (\w+) TO (\w+)$/);
      if (m) { state.tables.get(m[1]).constraints.find(c => c.CONSTRAINT_NAME === m[2]).CONSTRAINT_NAME = m[3]; return {}; }
      if (sql.startsWith('MERGE INTO n_moderation_settings')) { if (!state.settings.has(binds.setting_key)) state.settings.set(binds.setting_key, { SETTING_KEY: binds.setting_key, VALUE_TYPE: binds.value_type, SETTING_VALUE: binds.setting_value }); return {}; }
      if (sql.startsWith('INSERT INTO n_schema_migrations')) { state.records.set(binds.step_id, binds.checksum); return {}; }
      throw new Error(`Unexpected fixture SQL: ${sql}`);
    }
  };
  return adapter;
}
