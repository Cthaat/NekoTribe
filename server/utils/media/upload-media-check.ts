import path from 'path';
import type { File } from 'formidable';
import { fileTypeFromFile } from 'file-type';
import sharp from 'sharp';
import ffprobe from 'ffprobe-static';
import { promisify } from 'util';
import { exec } from 'child_process';

const execAsync = promisify(exec);

const ALLOWED_MIME = [
  'image/jpeg',
  'image/png',
  'image/gif',
  'video/mp4',
  'video/webm',
  'video/ogg',
  'audio/mpeg',
  'audio/wav',
  'audio/ogg'
];
const ALLOWED_EXTS = [
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.mp4',
  '.webm',
  '.ogg',
  '.mp3',
  '.wav'
];
const MAX_SIZE = 500 * 1024 * 1024; // 500MB

function getMediaType(
  mime: string
): 'image' | 'gif' | 'video' | 'audio' | 'unknown' {
  if (mime.startsWith('image/')) {
    if (mime === 'image/gif') return 'gif';
    return 'image';
  }
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return 'audio';
  return 'unknown';
}

// 获取图片尺寸
async function getImageDimensions(
  filePath: string
): Promise<{ width: number; height: number } | null> {
  try {
    const metadata = await sharp(filePath).metadata();
    return {
      width: metadata.width || 0,
      height: metadata.height || 0
    };
  } catch (error) {
    console.error('获取图片尺寸失败:', error);
    return null;
  }
}

// 获取视频/音频信息 - 修复 ffprobe 路径问题
async function getMediaInfo(filePath: string): Promise<{
  width?: number;
  height?: number;
  duration?: number;
} | null> {
  try {
    // 正确获取 ffprobe 路径
    const ffprobePath = ffprobe.path || ffprobe;

    // 处理文件路径中的特殊字符和空格
    const escapedFilePath = `"${filePath.replace(/"/g, '\\"')}"`;

    // 构建命令，确保路径正确
    const command = `"${ffprobePath}" -v quiet -print_format json -show_format -show_streams ${escapedFilePath}`;

    console.log('执行命令:', command);

    const { stdout } = await execAsync(command, {
      timeout: 30000, // 30秒超时
      encoding: 'utf8'
    });

    const info = JSON.parse(stdout);

    const videoStream = info.streams?.find(
      (stream: any) => stream.codec_type === 'video'
    );
    const audioStream = info.streams?.find(
      (stream: any) => stream.codec_type === 'audio'
    );

    const result: {
      width?: number;
      height?: number;
      duration?: number;
    } = {};

    // 获取视频尺寸
    if (videoStream) {
      result.width = videoStream.width || 0;
      result.height = videoStream.height || 0;
    }

    // 获取时长
    if (info.format?.duration) {
      result.duration = Math.round(
        parseFloat(info.format.duration)
      );
    } else if (videoStream?.duration) {
      result.duration = Math.round(
        parseFloat(videoStream.duration)
      );
    } else if (audioStream?.duration) {
      result.duration = Math.round(
        parseFloat(audioStream.duration)
      );
    }

    return result;
  } catch (error) {
    console.error('获取媒体信息失败:', error);
    return null;
  }
}

// 生成缩略图
async function generateThumbnail(
  filePath: string,
  outputPath: string,
  mediaType: string
): Promise<string | null> {
  try {
    if (mediaType === 'image' || mediaType === 'gif') {
      // 图片缩略图
      await sharp(filePath)
        .resize(300, 300, {
          fit: 'inside',
          withoutEnlargement: true
        })
        .jpeg({ quality: 80 })
        .toFile(outputPath);
      return outputPath;
    } else if (mediaType === 'video') {
      // 视频缩略图 - 提取第一帧
      const command = `ffmpeg -i "${filePath}" -vframes 1 -vf scale=300:300:force_original_aspect_ratio=decrease -y "${outputPath}"`;
      await execAsync(command);
      return outputPath;
    }
    return null;
  } catch (error) {
    console.error('生成缩略图失败:', error);
    return null;
  }
}

export async function checkMediaFile(
  file: File,
  options?: {
    generateThumbnail?: boolean;
    thumbnailDir?: string;
    tweetId?: string;
  }
): Promise<{
  valid: boolean;
  message?: string;
  fileType?:
    | 'image'
    | 'gif'
    | 'video'
    | 'audio'
    | 'unknown';
  width?: number;
  height?: number;
  duration?: number;
  thumbnailPath?: string;
}> {
  // 读取文件真实类型
  const typeInfo = await fileTypeFromFile(file.filepath);
  const realMime = typeInfo?.mime || '';
  const ext = path
    .extname(file.originalFilename || '')
    .toLowerCase();

  // 检查真实类型
  if (!ALLOWED_MIME.includes(realMime)) {
    return {
      valid: false,
      message:
        '仅支持图片(jpg、png、gif)、视频(mp4、webm、ogg)、音频(mp3、wav、ogg)格式文件'
    };
  }
  // 检查扩展名
  if (!ALLOWED_EXTS.includes(ext)) {
    return { valid: false, message: '文件扩展名不被支持' };
  }
  // 检查大小
  if ((file.size || 0) > MAX_SIZE) {
    return { valid: false, message: '文件不能超过500MB' };
  }

  const fileType = getMediaType(realMime);

  // 获取媒体信息
  let width: number | undefined;
  let height: number | undefined;
  let duration: number | undefined;
  let thumbnailPath: string | undefined;

  try {
    if (fileType === 'image' || fileType === 'gif') {
      // 获取图片尺寸
      const dimensions = await getImageDimensions(
        file.filepath
      );
      if (dimensions) {
        width = dimensions.width;
        height = dimensions.height;
      }
    } else if (
      fileType === 'video' ||
      fileType === 'audio'
    ) {
      // 获取视频/音频信息
      const mediaInfo = await getMediaInfo(file.filepath);
      if (mediaInfo) {
        width = mediaInfo.width;
        height = mediaInfo.height;
        duration = mediaInfo.duration;
      }
    }

    // 生成缩略图
    if (
      options?.generateThumbnail &&
      options?.thumbnailDir &&
      options?.tweetId
    ) {
      const thumbnailFileName = `thumb_${options.tweetId}_${Date.now()}.jpg`;
      const thumbnailFullPath = path.join(
        options.thumbnailDir,
        thumbnailFileName
      );

      const generatedThumbnail = await generateThumbnail(
        file.filepath,
        thumbnailFullPath,
        fileType
      );
      if (generatedThumbnail) {
        thumbnailPath = `/upload/media/${options.tweetId}/thumbnails/${thumbnailFileName}`;
      }
    }
  } catch (error) {
    console.error('处理媒体文件信息时出错:', error);
    // 继续执行，不因为获取元数据失败而拒绝文件
  }

  return {
    valid: true,
    fileType,
    width,
    height,
    duration,
    thumbnailPath
  };
}

// 简化版本，只做基本检查
export async function checkMediaFileBasic(
  file: File
): Promise<{
  valid: boolean;
  message?: string;
  fileType?:
    | 'image'
    | 'gif'
    | 'video'
    | 'audio'
    | 'unknown';
}> {
  const typeInfo = await fileTypeFromFile(file.filepath);
  const realMime = typeInfo?.mime || '';
  const ext = path
    .extname(file.originalFilename || '')
    .toLowerCase();

  if (!ALLOWED_MIME.includes(realMime)) {
    return {
      valid: false,
      message:
        '仅支持图片(jpg、png、gif)、视频(mp4、webm、ogg)、音频(mp3、wav、ogg)格式文件'
    };
  }

  if (!ALLOWED_EXTS.includes(ext)) {
    return { valid: false, message: '文件扩展名不被支持' };
  }

  if ((file.size || 0) > MAX_SIZE) {
    return { valid: false, message: '文件不能超过500MB' };
  }

  return {
    valid: true,
    fileType: getMediaType(realMime)
  };
}
