import type { Readable } from 'node:stream';

export type StorageType = 'local' | 's3';

export type StorageVisibility = 'public' | 'private';

export type ManagedMediaType =
  | 'image'
  | 'gif'
  | 'video'
  | 'audio';

export interface StorageCapabilities {
  multipartUpload: boolean;
  cdn: boolean;
  privateObjects: boolean;
}

export interface StorageSaveInput {
  key: string;
  sourcePath: string;
  contentType: string;
  visibility?: StorageVisibility;
}

export interface StoredObject {
  key: string;
  url: string;
  contentType: string;
  size: number;
  visibility: StorageVisibility;
}

export interface StorageReadRequest {
  rangeHeader?: string | null;
}

export interface StorageReadResult {
  statusCode: number;
  headers: Record<string, string>;
  stream: Readable;
}

export interface StorageProvider {
  readonly type: StorageType;
  readonly capabilities: StorageCapabilities;
  saveFromPath(
    input: StorageSaveInput
  ): Promise<StoredObject>;
  deleteObject(key: string): Promise<void>;
  getPublicUrl(
    key: string,
    visibility?: StorageVisibility
  ): string;
  readObject(
    key: string,
    request: StorageReadRequest
  ): Promise<StorageReadResult>;
}

export interface StorageConfig {
  type: StorageType;
  rootPath: string;
  legacyUploadPath: string;
  publicBasePath: string;
  publicBaseUrl: string | null;
  cdnBaseUrl: string | null;
}

export interface FileMetadata {
  width: number | null;
  height: number | null;
  duration: number | null;
}

export interface ValidatedFile {
  originalName: string;
  mimeType: string;
  extension: string;
  size: number;
}

export interface ValidatedAvatarFile extends ValidatedFile {}

export interface ValidatedMediaFile extends ValidatedFile {
  mediaType: ManagedMediaType;
  metadata: FileMetadata;
}

export interface StoredManagedFile extends StoredObject {
  originalName: string;
}

export interface StoredManagedMedia extends StoredManagedFile {
  mediaType: ManagedMediaType;
  metadata: FileMetadata;
  thumbnailUrl: string | null;
}
