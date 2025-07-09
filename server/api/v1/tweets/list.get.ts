import oracledb from 'oracledb';

export default defineEventHandler(async event => {
  const body: TweetListPayload = await readBody<TweetListPayload>(event);
  const user: Auth = event.context.auth as Auth;

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
  } finally {
    await connection.close();
  }
});
