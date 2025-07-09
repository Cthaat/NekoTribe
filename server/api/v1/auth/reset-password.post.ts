export default defineEventHandler(async event => {
  const body = await readBody<ResetPasswordPayload>(event);

  const getOracleConnection = event.context.getOracleConnection;

  const connection = await getOracleConnection();

  if (!body || !body.resettoken) {
    throw createError({
      statusCode: 400,
      message: '请求体不能为空或缺少重置令牌',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '请求体不能为空或缺少重置令牌',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }
});
