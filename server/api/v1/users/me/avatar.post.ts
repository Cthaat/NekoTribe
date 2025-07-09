import formidable from 'formidable';
import fs from 'fs';
import path from 'path';
import { checkAvatarFile } from '~/server/utils/users/upload-avatar-check';

// 处理用户头像上传的接口
export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;

  // 创建 formidable 实例，配置上传参数
  const form = formidable({
    multiples: false, // 只允许单文件上传
    uploadDir: `./public/avatars/${user.userId}`, // 上传目录
    keepExtensions: true // 保留原始扩展名
  });

  // 确保上传目录存在
  await fs.promises.mkdir(`./public/avatars/${user.userId}`, {
    recursive: true
  });

  // 返回 Promise 处理异步上传
  return new Promise((resolve, reject) => {
    form.parse(event.req, async (err, fields, files) => {
      // 解析出错
      if (err) {
        return reject(
          createError({
            statusCode: 401,
            statusMessage: 'Bad Request',
            data: {
              success: false,
              message: '上传文件解析失败',
              code: 401,
              timestamp: new Date().toISOString()
            } as ErrorResponse
          })
        );
      }

      // 检查文件数量
      const avatarFiles = files.avatar;
      if (!avatarFiles || avatarFiles.length === 0) {
        return reject(
          createError({
            statusCode: 400,
            statusMessage: 'Bad Request',
            data: {
              success: false,
              message: '上传文件为空',
              code: 400,
              timestamp: new Date().toISOString()
            } as ErrorResponse
          })
        );
      }
      if (avatarFiles.length > 1) {
        // 超过一个文件，删除所有临时文件
        for (const f of avatarFiles) {
          if (f.filepath) await fs.promises.unlink(f.filepath);
        }
        return reject(
          createError({
            statusCode: 400,
            statusMessage: 'Bad Request',
            data: {
              success: false,
              message: '只能上传一个头像文件',
              code: 400,
              timestamp: new Date().toISOString()
            } as ErrorResponse
          })
        );
      }

      const file = avatarFiles[0];

      // 在这里调用工具函数进行校验
      const check: { valid: boolean; message?: string } =
        await checkAvatarFile(file);
      if (!check.valid) {
        // 不合规，删除临时文件
        if (file.filepath) await fs.promises.unlink(file.filepath);
        return reject(
          createError({
            statusCode: 402,
            statusMessage: 'Bad Request',
            data: {
              success: false,
              message: '上传文件不符合要求: ' + check.message,
              code: 402,
              timestamp: new Date().toISOString()
            } as ErrorResponse
          })
        );
      }

      // 获取原始扩展名
      const ext = path.extname(file.originalFilename || file.filepath);
      // 生成唯一文件名
      const uniqueName = `${user.userId}_${Date.now()}_${Math.floor(Math.random() * 10000)}${ext}`;
      // 新文件完整路径
      const newFilePath = path.join(
        `./public/avatars/${user.userId}`,
        uniqueName
      );

      try {
        // 重命名文件，防止重复
        await fs.promises.rename(file.filepath, newFilePath);
      } catch (e) {
        return reject(
          createError({
            statusCode: 400,
            statusMessage: 'Bad Request',
            data: {
              success: false,
              message: '头像文件重命名失败',
              code: 400,
              timestamp: new Date().toISOString()
            } as ErrorResponse
          })
        );
      }

      // 构建头像访问路径
      const avatarPath = `/avatars/${user.userId}/${uniqueName}`;

      // TODO: 这里可以补充数据库更新逻辑

      // 返回成功响应
      resolve({
        code: 200,
        success: true,
        message: '头像上传成功',
        data: {
          url: avatarPath
        },
        timestamp: new Date().toISOString()
      } as SuccessUploadResponse);
    });
  });
});
