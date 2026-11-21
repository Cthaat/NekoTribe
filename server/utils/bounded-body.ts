import type { Readable } from 'node:stream';

/** Count stream bytes before retaining them, including requests without Content-Length. */
export function readBoundedBody(stream: Readable, maxBytes: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const invalid = () => new Error('Invalid request body');
    if (stream.destroyed || stream.readableEnded) {
      reject(invalid());
      return;
    }

    const chunks: Buffer[] = [];
    let size = 0;
    const cleanup = () => {
      stream.off('data', onData);
      stream.off('end', onEnd);
      stream.off('error', onError);
      stream.off('close', onClose);
    };
    const onError = () => {
      cleanup();
      reject(invalid());
    };
    const onClose = () => {
      if (!stream.readableEnded) onError();
    };
    const onEnd = () => {
      cleanup();
      resolve(Buffer.concat(chunks, size));
    };
    const onData = (chunk: Buffer | string) => {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += bytes.length;
      if (size > maxBytes) {
        cleanup();
        const ignoreError = () => {};
        stream.once('error', ignoreError);
        stream.once('close', () => stream.off('error', ignoreError));
        stream.resume();
        reject(invalid());
        return;
      }
      chunks.push(bytes);
    };
    stream.on('error', onError);
    stream.on('close', onClose);
    stream.on('end', onEnd);
    stream.on('data', onData);
  });
}
