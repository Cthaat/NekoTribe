import Redis from 'ioredis'

const runtimeConfig = useRuntimeConfig()

class RedisClient {
  private static instance: Redis

  // 获取 Redis 单例
  public static getInstance(): Redis {
    if (!RedisClient.instance) {
      RedisClient.instance = new Redis({
        host: runtimeConfig.redisHost,
        port: Number(runtimeConfig.redisPort),
        password: runtimeConfig.redisPassword,
        db: Number(runtimeConfig.redisDb)
      })
      RedisClient.instance.on('error', (err) => {
        console.error('Redis 连接错误:', err)
      })
      RedisClient.instance.on('connect', () => {
        console.log('Redis 连接成功')
      })
    }
    return RedisClient.instance
  }
}

export default RedisClient