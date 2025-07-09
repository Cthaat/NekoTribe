import formidable from 'formidable';
import fs from 'fs';
import path from 'path';

const MAX_SIZE = 10 * 1024 * 1024; // 10MB
const ALLOWED_MIME = ['image/jpeg', 'image/png', 'image/gif'];

// 定义一个事件处理器，用于处理上传头像的请求
export default defineEventHandler(async event => {
  const form = formidable({
    multiples: false,
    maxFileSize: MAX_SIZE,
    filter: ({ mimetype }) => {
      // 只允许指定的图片类型
      return ALLOWED_MIME.includes(mimetype || '');
    },
    uploadDir: '../uploads/avatars', // 根据你的图片目录调整
    keepExtensions: true
  });

  // 确保上传目录存在，如果不存在则创建
  await fs.promises.mkdir('../uploads/avatars', { recursive: true });

  // 返回一个 Promise，处理文件上传逻辑
  return new Promise((resolve, reject) => {
    form.parse(event.req, async (err, fields, files) => {
      if (err) {
        // formidable 有自动文件大小/type校验，出错时返回原因
        return resolve({ code: 400, message: err.message });
      }
      const file = files.avatar?.[0];
      if (!file) return resolve({ code: 400, message: '请上传头像文件' });
      // 保险起见，再双重校验
      if (!ALLOWED_MIME.includes(file.mimetype || '')) {
        return resolve({ code: 400, message: '文件类型不被支持' });
      }
      if ((file.size || 0) > MAX_SIZE) {
        return resolve({ code: 400, message: '文件超过最大限制 10MB' });
      }
      // 业务逻辑：保存文件，返回URL等
      const filename = path.basename(file.filepath);
      resolve({ code: 200, url: `/avatars/${filename}` });
    });
  });
});
