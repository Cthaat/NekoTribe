import path from 'node:path';
import type { StorageConfig, StorageType } from './types';

const DEFAULT_STORAGE_ROOT = './storage';
const DEFAULT_STORAGE_PUBLIC_BASE = '/storage';

function envValue(key: string): string | undefined {
  const value = process.env[key];
  if (typeof value !== 'string') {
    return undefined;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function normalizePublicBasePath(value: string): string {
  const slashValue = value.replace(/\\/g, '/');
  if (/^\/+$/u.test(slashValue) || slashValue.startsWith('//')) {
    throw new Error('Invalid public storage base path');
  }
  const normalized = value
    .replace(/\\/g, '/')
    .replace(/\/+$/, '');

  if (!normalized.startsWith('/')) {
    return `/${normalized}`;
  }

  return normalized || DEFAULT_STORAGE_PUBLIC_BASE;
}

function resolvePathOrDefault(
  input: string | undefined,
  fallback: string
): string {
  const value = input ?? fallback;
  return path.isAbsolute(value)
    ? value
    : path.resolve(process.cwd(), value);
}

function normalizeBaseUrl(
  value: string | undefined
): string | null {
  if (!value) {
    return null;
  }

  let parsed: URL | null = null;
  try { parsed = new URL(value); } catch { /* Existing invalid-URL behavior remains at use time. */ }
  if (parsed?.username || parsed?.password) {
    throw new Error('Public storage base URL must not contain credentials');
  }
  return value.replace(/\/+$/, '');
}

export function getStorageConfig(): StorageConfig {
  const typeValue = envValue('STORAGE_TYPE');
  const type: StorageType =
    typeValue === 's3' ? 's3' : 'local';
  const storageRootInput =
    envValue('STORAGE_PATH') ||
    envValue('STORAGE_ROOT_DIR');
  const rootPath = resolvePathOrDefault(
    storageRootInput,
    DEFAULT_STORAGE_ROOT
  );

  return {
    type,
    rootPath,
    publicBasePath: normalizePublicBasePath(
      envValue('STORAGE_PUBLIC_BASE') ||
        DEFAULT_STORAGE_PUBLIC_BASE
    ),
    publicBaseUrl: normalizeBaseUrl(envValue('BASE_URL')),
    cdnBaseUrl: normalizeBaseUrl(
      envValue('STORAGE_CDN_BASE_URL')
    )
  };
}
