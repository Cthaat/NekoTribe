export type SchemaFeature = 'two-factor' | 'groups' | 'moderation' | 'media' | 'user-settings' | 'ai-conversations' | 'ai-terms' | 'ai-skills' | 'recommendation-feedback' | 'ai-moderation-feedback' | 'media-access-scope' | 'ai-user-provider' | 'direct-message-extras' | 'post-polls' | 'post-drafts' | 'profile-pinned-post' | 'post-markdown' | 'passkey-auth' | 'github-oauth';
export interface SchemaAdapter {
  execute(sql: string, binds?: Record<string, unknown>): Promise<{
    rows?: Record<string, unknown>[];
    outBinds?: Record<string, unknown>;
  }>;
}
export interface SchemaCheck {
  feature: SchemaFeature;
  id: string;
  status: 'ready' | 'missing' | 'incompatible' | 'repair';
  recorded: boolean;
}
export class SchemaReadinessError extends Error {}
export function describeIndex(step: { sql: string }): { table: string; columns: string[] };
export function planSchema(): { feature: SchemaFeature; steps: { id: string; kind: string; name: string; checksum: string }[] }[];
export function checkSchema(adapter: SchemaAdapter, feature?: SchemaFeature): Promise<SchemaCheck[]>;
export function assertSchemaReady(adapter: SchemaAdapter, feature: SchemaFeature): Promise<void>;
export function coalesceReadinessCheck(connection: object, feature: SchemaFeature, check: () => Promise<void>): Promise<void>;
export function applySchema(adapter: SchemaAdapter): Promise<{ steps: number }>;
export function normalizeExpression(value: unknown): string;
