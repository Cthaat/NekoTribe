import { StorageHttpError } from '../http';
import type {
  StorageCapabilities,
  StorageConfig,
  StorageProvider,
  StorageReadRequest,
  StorageReadResult,
  StorageSaveInput,
  StoredObject
} from '../types';

const S3_CAPABILITIES: StorageCapabilities = {
  multipartUpload: true,
  cdn: true,
  privateObjects: true
};

export class S3StorageProvider implements StorageProvider {
  readonly type = 's3' as const;
  readonly capabilities = S3_CAPABILITIES;

  constructor(private readonly config: StorageConfig) {}

  private notImplemented(): never {
    throw new StorageHttpError(
      501,
      'S3 存储 provider 预留中，当前项目尚未完成实现'
    );
  }

  async saveFromPath(
    _input: StorageSaveInput
  ): Promise<StoredObject> {
    this.notImplemented();
  }

  async deleteObject(_key: string): Promise<void> {
    this.notImplemented();
  }

  getPublicUrl(key: string): string {
    const relativePath =
      `${this.config.publicBasePath}/${key}`;
    const baseUrl =
      this.config.cdnBaseUrl || this.config.publicBaseUrl;

    if (!baseUrl) {
      return relativePath;
    }

    return new URL(relativePath, `${baseUrl}/`).toString();
  }

  async readObject(
    _key: string,
    _request: StorageReadRequest
  ): Promise<StorageReadResult> {
    this.notImplemented();
  }
}
