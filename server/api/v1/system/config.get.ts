import fs from 'fs';
import path from 'path';

export default defineEventHandler(async event => {
  try {
    // 假设配置文件为 config.json，存放在项目根目录下
    const configPath = path.join(
      process.cwd(),
      'config',
      'versions',
      'oracle-server.json'
    );
    const configData = await fs.promises.readFile(configPath, 'utf-8');
    const config = JSON.parse(configData);

    return {
      success: true,
      message: '获取系统配置成功',
      data: config,
      code: 200,
      timestamp: new Date().toISOString()
    };
  } catch (error: any) {
    throw createError({
      statusCode: 500,
      statusMessage: '获取系统配置失败',
      data: error.message
    });
  }
});
