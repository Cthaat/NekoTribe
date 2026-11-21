import { createError, defineEventHandler, isError, setResponseHeader } from 'h3';
import { v2UpdateAvatar } from '~/server/services/v2/user-avatar';
import { v2Auth, v2WithConnection } from '~/server/utils/v2';

const invalidUploadMessages = new Set([
  '请使用 multipart/form-data 上传头像',
  '上传文件为空',
  '头像仅支持 jpg、png、gif 图片'
]);

export default defineEventHandler(async event => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  try {
    v2Auth(event);
    const { data } = await v2WithConnection(event, connection =>
      v2UpdateAvatar(event, connection, 'avatar')
    );
    return {
      code: 200,
      success: true,
      message: '头像上传成功',
      data: { url: data.avatar_url },
      timestamp: new Date().toISOString()
    };
  } catch (error) {
    const source = isError(error) ? error : null;
    const status = source?.statusCode;
    const statusCode = status === 400 || status === 401 ? status : 500;
    let message = '头像上传失败';
    if (statusCode === 401) message = '未认证或 token 无效';
    if (statusCode === 400 && source && invalidUploadMessages.has(source.message)) {
      message = source.message;
    }
    throw createError({
      statusCode,
      statusMessage: statusCode === 500 ? 'Internal Server Error' : statusCode === 401 ? 'Unauthorized' : 'Bad Request',
      data: { code: statusCode, success: false, message, timestamp: new Date().toISOString() } satisfies ErrorResponse
    });
  }
});
