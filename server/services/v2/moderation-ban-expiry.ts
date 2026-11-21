import type { Connection } from 'oracledb';
import contract from '../../../specifications/requirements/moderation-ban-expiry.json';
import { v2Execute, v2Number, v2One, v2Rows, v2ServerError } from '~/server/utils/v2';

export const banExpiryIntervalMs = contract.intervalSeconds * 1000;

export async function restoreExpiredBan(connection: Connection, userId: number, skipLocked = false): Promise<void> {
  const key = { user_id: userId };
  const { lock, restore, expire } = contract.sql;
  const lockStatement = skipLocked ? lock + ' SKIP LOCKED' : lock;
  try {
    if (await v2One(connection, lockStatement, key) && await v2Execute(connection, restore, key, false) === 1) {
      if (await v2Execute(connection, expire, key, false) < 1) v2ServerError();
    }
    await connection.commit();
  } catch (error) {
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}

export async function sweepExpiredBans(connection: Connection): Promise<void> {
  const deadline = performance.now() + 25_000;
  const rows = await v2Rows(connection, contract.sql.candidates);
  for (const row of rows) {
    if (performance.now() >= deadline) break;
    await restoreExpiredBan(connection, v2Number(row.USER_ID), true);
  }
}
