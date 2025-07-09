import formidable from 'formidable';
import fs from 'fs';
import path from 'path';

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
            success: false,
            message: '文件上传失败',
            code: 500,
            timestamp: new Date().toISOString()
          } as ErrorResponse)
        );
      }
      // 没有上传文件
      const file = files.avatar?.[0];
      if (!file) {
        return reject(
          createError({
            success: false,
            message: '未上传文件',
            code: 400,
            timestamp: new Date().toISOString()
          } as ErrorResponse)
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
            success: false,
            message: '保存头像文件失败',
            code: 500,
            timestamp: new Date().toISOString()
          } as ErrorResponse)
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
        url: avatarPath,
        timestamp: new Date().toISOString()
      });
    });
  });
});
