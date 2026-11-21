import { execFile } from 'node:child_process';
import { open } from 'node:fs/promises';
import { promisify } from 'node:util';
import type { FileMetadata } from './types';

const runProbe = promisify(execFile);
const probeBudgetMs = 8000;
const probeSlots = 4;
let active = 0;
const waiters = new Set<() => void>();

const formats: ReadonlyMap<string, string> = new Map([
  ['audio/wav', 'wav'], ['audio/mpeg', 'mp3'], ['audio/ogg', 'ogg'],
  ['video/ogg', 'ogg'], ['video/mp4', 'mov'], ['video/webm', 'matroska'],
]);

export function mediaProbeArgs(filePath: string, mimeType: string): string[] | null {
  const format = formats.get(mimeType);
  if (!format) return null;
  return [
    ...(format === 'mov' ? ['-enable_drefs', '0', '-use_absolute_path', '0'] : []),
    '-v', 'quiet', '-protocol_whitelist', 'file', '-f', format,
    '-print_format', 'json', '-show_format', '-show_streams', '-i', filePath,
  ];
}

async function acquireSlot(): Promise<boolean> {
  if (active < probeSlots) {
    active++;
    return true;
  }
  return await new Promise(resolve => {
    const grant = () => { clearTimeout(timer); resolve(true); };
    const timer = setTimeout(() => { waiters.delete(grant); resolve(false); }, probeBudgetMs);
    waiters.add(grant);
  });
}

function releaseSlot(): void {
  const next = waiters.values().next().value;
  if (next) {
    waiters.delete(next);
    next();
  } else active--;
}

interface MediaProbeStream {
  codec_type?: string;
  width?: number;
  height?: number;
  duration?: string;
}

export function parseMediaProbe(stdout: string): FileMetadata {
  const report = JSON.parse(stdout) as { format?: { duration?: string }; streams?: MediaProbeStream[] };
  const video = report.streams?.find(stream => stream.codec_type === 'video');
  const audio = report.streams?.find(stream => stream.codec_type === 'audio');
  const raw = report.format?.duration || video?.duration || audio?.duration;
  const seconds = typeof raw === 'string' && raw.trim() ? Number(raw) : NaN;
  const duration = Math.round(seconds);
  return {
    width: typeof video?.width === 'number' && Number.isSafeInteger(video.width) && video.width > 0 ? video.width : null,
    height: typeof video?.height === 'number' && Number.isSafeInteger(video.height) && video.height > 0 ? video.height : null,
    duration: Number.isSafeInteger(duration) && seconds >= 0 ? duration : null,
  };
}

export async function probeRichMedia(binary: string | undefined, filePath: string, mimeType: string): Promise<FileMetadata | null> {
  const args = mediaProbeArgs(filePath, mimeType);
  if (!binary || !args) return null;
  const deadline = performance.now() + probeBudgetMs;
  if (!await acquireSlot()) return null;
  try {
    const timeout = Math.floor(deadline - performance.now());
    if (timeout <= 0) return null;
    const { stdout } = await runProbe(binary, args, {
      timeout, maxBuffer:65536, killSignal:'SIGKILL', windowsHide:true,
    });
    return parseMediaProbe(stdout);
  } catch {
    return null;
  } finally {
    releaseSlot();
  }
}

export async function pcmWaveDuration(filePath: string): Promise<number | null> {
  const file = await open(filePath, 'r');
  try {
    const header = Buffer.alloc(12);
    if ((await file.read(header, 0, 12, 0)).bytesRead !== 12 ||
        header.toString('ascii',0,4) !== 'RIFF' || header.toString('ascii',8,12) !== 'WAVE') return null;
    const end = header.readUInt32LE(4) + 8;
    if (end < 12 || end > (await file.stat()).size) return null;
    let position = 12;
    let byteRate = 0;
    let blockAlign = 0;
    let payloadSize: number | null = null;
    const chunk = Buffer.alloc(8);
    const format = Buffer.alloc(16);
    for (let chunks = 0; position + 8 <= end && chunks < 1024; chunks++) {
      if ((await file.read(chunk, 0, 8, position)).bytesRead !== 8) return null;
      const size = chunk.readUInt32LE(4);
      const start = position + 8;
      position = start + size + (size % 2);
      if (position > end) return null;
      switch (chunk.toString('ascii',0,4)) {
        case 'fmt ': {
          if (byteRate || size < 16 || (await file.read(format, 0, 16, start)).bytesRead !== 16) return null;
          const kind = format.readUInt16LE(0);
          const channels = format.readUInt16LE(2);
          const sampleRate = format.readUInt32LE(4);
          const bits = format.readUInt16LE(14);
          byteRate = format.readUInt32LE(8);
          blockAlign = format.readUInt16LE(12);
          if ((kind !== 1 && kind !== 3) || !channels || !sampleRate || !bits || bits % 8 ||
              channels * (bits / 8) !== blockAlign || sampleRate * blockAlign !== byteRate) return null;
          break;
        }
        case 'data':
          if (payloadSize !== null) return null;
          payloadSize = size;
      }
    }
    if (position !== end || !byteRate || payloadSize === null || payloadSize % blockAlign) return null;
    return Math.round(payloadSize / byteRate);
  } finally {
    await file.close();
  }
}
