import { createError } from 'h3';
import oracledb from 'oracledb';
import { logError } from '~/server/utils/logging';
import { assertSchemaReady, coalesceReadinessCheck, type SchemaFeature } from './schema.mjs';

export function requireFeatureSchema(
  connection: oracledb.Connection,
  feature: SchemaFeature
): Promise<void> {
  return coalesceReadinessCheck(connection, feature, () => checkFeatureSchema(connection, feature));
}

async function checkFeatureSchema(
  connection: oracledb.Connection,
  feature: SchemaFeature
): Promise<void> {
  try {
    await assertSchemaReady({
      async execute(sql, binds = {}) {
        // This adapter is deliberately SELECT-only even if the shared engine changes.
        if (!/^SELECT\b/i.test(sql.trim())) {
          throw new Error('Schema readiness must be read-only.');
        }
        const parameters: Record<string, string | number | null> = {};
        for (const [key, value] of Object.entries(binds)) {
          if (value !== null && typeof value !== 'string' && typeof value !== 'number') {
            throw new Error('Unsupported readiness bind.');
          }
          parameters[key] = value;
        }
        const result = await connection.execute<Record<string, unknown>>(
          sql, parameters, { outFormat: oracledb.OUT_FORMAT_OBJECT }
        );
        return { rows: result.rows ?? [] };
      }
    }, feature);
  } catch {
    logError('database:schema:not-ready', { feature, action: 'Run the explicit schema migration check.' });
    // Do not leak Oracle SQL, identifiers, connection values or driver messages.
    throw createError({
      statusCode: 503,
      statusMessage: 'Service temporarily unavailable',
      data: {
        code: 50301,
        message: '服务暂不可用，请稍后重试。',
        data: null,
        meta: null
      }
    });
  }
}
