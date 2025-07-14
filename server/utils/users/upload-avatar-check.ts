import path from 'path';
import type { File } from 'formidable';
import { fileTypeFromFile } from 'file-type';

const ALLOWED_MIME = [
  'image/jpeg',
  'image/png',
  'image/gif'
];
const ALLOWED_EXTS = ['.jpg', '.jpeg', '.png', '.gif'];
const MAX_SIZE = 10 * 1024 * 1024; // 10MB

export async function checkAvatarFile(file: File): Promise<{
  valid: boolean;
  message?: string;
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
      message: '仅支持jpg、png、gif格式的图片'
    };
  }
  // 检查扩展名
  if (!ALLOWED_EXTS.includes(ext)) {
    return { valid: false, message: '文件扩展名不被支持' };
  }
  // 检查大小
  if ((file.size || 0) > MAX_SIZE) {
    return { valid: false, message: '文件不能超过10MB' };
  }
  return { valid: true };
}
