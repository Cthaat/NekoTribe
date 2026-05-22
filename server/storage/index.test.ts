import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import type { File } from 'formidable';
import { validateMediaFile } from './index';

let tempDir = '';

before(async () => {
  tempDir = await fs.mkdtemp(
    path.join(os.tmpdir(), 'nekotribe-storage-test-')
  );
});

after(async () => {
  if (!tempDir) return;
  await fs.rm(tempDir, { recursive: true, force: true });
});

async function writeUploadFixture(
  fileName: string,
  mimeType: string,
  content: Buffer | string
): Promise<File> {
  const filePath = path.join(tempDir, fileName);
  await fs.writeFile(filePath, content);
  const stat = await fs.stat(filePath);

  return {
    filepath: filePath,
    originalFilename: fileName,
    mimetype: mimeType,
    size: stat.size
  } as File;
}

describe('validateMediaFile', () => {
  it('accepts PDF documents as file attachments', async () => {
    const file = await writeUploadFixture(
      'project-plan.pdf',
      'application/pdf',
      Buffer.from('%PDF-1.4\n%NekoTribe fixture\n', 'utf8')
    );

    const result = await validateMediaFile(file);

    assert.equal(result.mediaType, 'file');
    assert.equal(result.mimeType, 'application/pdf');
    assert.equal(result.extension, '.pdf');
    assert.equal(result.originalName, 'project-plan.pdf');
  });

  it('accepts text documents using the browser-provided MIME type', async () => {
    const file = await writeUploadFixture(
      'notes.txt',
      'text/plain',
      'NekoTribe upload notes'
    );

    const result = await validateMediaFile(file);

    assert.equal(result.mediaType, 'file');
    assert.equal(result.mimeType, 'text/plain');
    assert.equal(result.extension, '.txt');
    assert.equal(result.originalName, 'notes.txt');
  });
});
