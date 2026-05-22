import fs from 'node:fs';
import path from 'node:path';
import type { StorageReadRequest, StorageReadResult } from './types';

const MIME_BY_EXTENSION: Record<string, string> = {
  '.7z': 'application/x-7z-compressed',
  '.csv': 'text/csv',
  '.doc': 'application/msword',
  '.docx':
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.gif': 'image/gif',
  '.gz': 'application/gzip',
  '.jpeg': 'image/jpeg',
  '.jpg': 'image/jpeg',
  '.json': 'application/json',
  '.md': 'text/markdown',
  '.mp3': 'audio/mpeg',
  '.mp4': 'video/mp4',
  '.odp': 'application/vnd.oasis.opendocument.presentation',
  '.ods': 'application/vnd.oasis.opendocument.spreadsheet',
  '.odt': 'application/vnd.oasis.opendocument.text',
  '.ogg': 'audio/ogg',
  '.pdf': 'application/pdf',
  '.png': 'image/png',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx':
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.rar': 'application/vnd.rar',
  '.rtf': 'application/rtf',
  '.tar': 'application/x-tar',
  '.tsv': 'text/tab-separated-values',
  '.txt': 'text/plain',
  '.wav': 'audio/wav',
  '.webm': 'video/webm',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx':
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.xml': 'application/xml',
  '.zip': 'application/zip'
};

interface ParsedByteRange {
  start: number;
  end: number;
}

export class StorageHttpError extends Error {
  constructor(
    public readonly statusCode: number,
    message: string
  ) {
    super(message);
    this.name = 'StorageHttpError';
  }
}

function inferMimeType(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  return (
    MIME_BY_EXTENSION[ext] || 'application/octet-stream'
  );
}

function parseRangeHeader(
  rangeHeader: string,
  fileSize: number
): ParsedByteRange {
  const matched = /^bytes=(\d*)-(\d*)$/i.exec(
    rangeHeader.trim()
  );

  if (!matched) {
    throw new StorageHttpError(
      416,
      'Invalid range header'
    );
  }

  const rawStart = matched[1];
  const rawEnd = matched[2];

  let start = rawStart ? Number.parseInt(rawStart, 10) : NaN;
  let end = rawEnd ? Number.parseInt(rawEnd, 10) : NaN;

  if (Number.isNaN(start)) {
    const suffixLength = Number.isNaN(end) ? 0 : end;
    if (suffixLength <= 0) {
      throw new StorageHttpError(
        416,
        'Invalid range header'
      );
    }

    start = Math.max(fileSize - suffixLength, 0);
    end = fileSize - 1;
  } else {
    if (Number.isNaN(end) || end >= fileSize) {
      end = fileSize - 1;
    }
  }

  if (
    start < 0 ||
    end < start ||
    start >= fileSize
  ) {
    throw new StorageHttpError(
      416,
      'Requested range not satisfiable'
    );
  }

  return { start, end };
}

export async function createLocalReadResult(
  filePath: string,
  request: StorageReadRequest
): Promise<StorageReadResult> {
  const stat = await fs.promises.stat(filePath);
  const contentType = inferMimeType(filePath);
  const headers: Record<string, string> = {
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'public, max-age=31536000, immutable',
    'Content-Type': contentType,
    ETag: `"${stat.size}-${stat.mtimeMs}"`,
    'Last-Modified': stat.mtime.toUTCString()
  };

  const rangeHeader = request.rangeHeader?.trim();
  if (!rangeHeader) {
    headers['Content-Length'] = String(stat.size);
    return {
      statusCode: 200,
      headers,
      stream: fs.createReadStream(filePath)
    };
  }

  const range = parseRangeHeader(rangeHeader, stat.size);
  const contentLength = range.end - range.start + 1;

  headers['Content-Length'] = String(contentLength);
  headers['Content-Range'] =
    `bytes ${range.start}-${range.end}/${stat.size}`;

  return {
    statusCode: 206,
    headers,
    stream: fs.createReadStream(filePath, {
      start: range.start,
      end: range.end
    })
  };
}
