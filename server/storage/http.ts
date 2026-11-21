import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import type formidable from 'formidable';
import type { StorageReadRequest, StorageReadResult } from './types';

export function classifyMultipartPartsByFilename(form: ReturnType<typeof formidable>): void {
  const handlePart = form.onPart.bind(form);
  form.onPart = part => {
    // Formidable uses the MIME value to choose between file and field parsing.
    part.mimetype = part.originalFilename === null ? null : (part.mimetype || 'application/octet-stream');
    return handlePart(part);
  };
}

const MIME_BY_EXTENSION: Record<string, string> = {
  '.7z': 'application/x-7z-compressed',
  '.avif': 'image/avif',
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
  '.oga': 'audio/ogg',
  '.ogm': 'video/ogg',
  '.ogv': 'video/ogg',
  '.opus': 'audio/ogg',
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
  '.spx': 'audio/ogg',
  '.tar': 'application/x-tar',
  '.tsv': 'text/tab-separated-values',
  '.txt': 'text/plain',
  '.wav': 'audio/wav',
  '.webm': 'video/webm',
  '.webp': 'image/webp',
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

export function parseLocalByteRange(header:string|null|undefined,size:number):ParsedByteRange|null {
  const value=header?.trim();
  return value?parseRangeHeader(value,size):null;
}

export class StorageHttpError extends Error {
  constructor(
    public readonly statusCode: number,
    message: string,
    public readonly headers: Record<string,string> = {}
  ) {
    super(message);
    this.name = 'StorageHttpError';
  }
}

export function inferMimeType(filePath: string): string {
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
      'Invalid range header',
      {'Content-Range':`bytes */${fileSize}`}
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
        'Invalid range header',
        {'Content-Range':`bytes */${fileSize}`}
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
      'Requested range not satisfiable',
      {'Content-Range':`bytes */${fileSize}`}
    );
  }

  return { start, end };
}

export async function createLocalReadResult(
  filePath: string,
  request: StorageReadRequest
): Promise<StorageReadResult> {
  const file=await fs.promises.open(filePath,fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
  try {
    const stat=await file.stat();
    if(!stat.isFile())throw new StorageHttpError(404,'文件不存在');
    const contentType=inferMimeType(filePath);
    const headers:Record<string,string>={
      'Accept-Ranges':'bytes',
      'Cache-Control':'public, max-age=31536000, immutable',
      'Content-Type':contentType,
      'X-Content-Type-Options':'nosniff',
      ETag:`"${stat.size}-${stat.mtimeMs}"`,
      'Last-Modified':stat.mtime.toUTCString()
    };
    const range=request.headOnly ? null : parseLocalByteRange(request.rangeHeader,stat.size);
    headers['Content-Length']=String(range?range.end-range.start+1:stat.size);
    if(range)headers['Content-Range']=`bytes ${range.start}-${range.end}/${stat.size}`;
    if (request.headOnly) {
      await file.close();
      return { statusCode: 200, headers, stream: Readable.from([]) };
    }
    return {
      statusCode:range?206:200,
      headers,
      stream:file.createReadStream(range?{start:range.start,end:range.end}:{})
    };
  } catch(error) { await file.close(); throw error; }
}
