import type { Connection } from 'oracledb';
import contract from '../../../specifications/requirements/ai-knowledge-scope.json';
import { v2Conflict, v2Forbidden, v2One } from '~/server/utils/v2';

export type KnowledgeScope = 'public' | 'personal' | 'group';
export interface KnowledgeFilter {
  kind: KnowledgeScope;
  groupId: number | null;
}

export const publicKnowledge: KnowledgeFilter = { kind: 'public', groupId: null };
export const scopedKnowledgeSql = contract.sql;

export function isKnowledgeScope(value: unknown): value is KnowledgeScope {
  return typeof value === 'string' && contract.scopes.includes(value);
}

export async function requireKnowledgeMembership(connection: Connection, user: number, group: number) {
  if (!await v2One(connection, contract.sql.membership, { viewer_id: user, group_id: group })) {
    v2Forbidden('权限不足');
  }
}

/** Serialize the commit with status changes to both the group and its membership. */
export async function lockKnowledgeMembership(connection: Connection, user: number, group: number) {
  try {
    if (!await v2One(connection, contract.sql.lock_group, { group_id: group }) ||
        !await v2One(connection, contract.sql.lock_membership, { viewer_id: user, group_id: group })) {
      v2Forbidden('权限不足');
    }
  } catch (error) {
    if (typeof error === 'object' && error !== null && 'errorNum' in error && error.errorNum === 54) {
      v2Conflict('会话已变更，请重试');
    }
    throw error;
  }
}
