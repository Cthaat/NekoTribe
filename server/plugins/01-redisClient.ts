import { defineNitroPlugin } from '#imports'
import Redis from 'ioredis'

export default defineNitroPlugin((nitroApp) => {
  const runtimeConfig = useRuntimeConfig()

  // 创建 Redis 实例
  const redis = new Redis({
    host: runtimeConfig.redisHost,
    port: Number(runtimeConfig.redisPort),
    password: runtimeConfig.redisPassword,
    db: Number(runtimeConfig.redisDb),
  })

  redis.on('error', (err) => {
    console.error('Redis 连接错误:', err)
  })
  redis.on('connect', () => {
    console.log('Redis 连接成功')
  })

  // 注入到每个 event.context
  nitroApp.hooks.hook('request', (event) => {
    event.context.redis = redis
  })
})