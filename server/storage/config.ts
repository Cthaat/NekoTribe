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
