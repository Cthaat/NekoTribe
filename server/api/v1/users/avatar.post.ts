import formidable from 'formidable';
import fs from 'fs';
import path from 'path';

// 定义一个处理用户头像上传的事件处理器
export default defineEventHandler(async event => {
  // 从事件上下文中获取用户身份验证信息
  const user: Auth = event.context.auth as Auth;

  // 创建一个 formidable 实例用于解析文件上传
  const form = formidable({
    multiples: false,
    uploadDir: `./public/avatars/${user.userId}`,
    keepExtensions: true
  });

  // 确保上传目录存在，如果不存在则创建
  await fs.promises.mkdir(`./public/avatars/${user.userId}`, {
    recursive: true
  });

  // 返回一个 Promise 以处理文件上传的异步操作
  return new Promise((resolve, reject) => {
    form.parse(event.req, async (err, fields, files) => {
      // 如果解析过程中发生错误，拒绝 Promise
      if (err) return reject(err);
      // 获取上传的头像文件
      const file = files.avatar?.[0];
      // 如果没有上传文件，解决 Promise 并返回错误信息
      if (!file) return resolve({ code: 400, message: '未上传文件' });
      // 获取文件名
      const filename = path.basename(file.filepath);
      // 构建头像文件的 URL 路径
      const avatarPath = `/avatars/${filename}`;

      // 更新数据库

      // 解决 Promise 并返回成功信息及头像文件的 URL 路径
      resolve({ code: 200, url: avatarPath });
    });
  });
});
