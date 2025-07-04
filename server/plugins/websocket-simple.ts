// server/plugins/websocket.ts

import Redis from 'ioredis'

export default defineNitroPlugin((nitroApp) => {
  // 只在服务器端执行
  if (!process.server) return

  const config = useRuntimeConfig()
  
  if (!config.redisUrl) {
    console.warn('Redis URL is not configured. WebSocket push notifications will not work across multiple instances.')
    return
  }

  // 创建 Redis 发布客户端用于 API 路由
  const redisPublisher = new Redis(config.redisUrl)
  
  // 将 Redis Publisher 注入到 Nitro 的事件上下文中，供 API 路由使用
  nitroApp.hooks.hook('request', (event) => {
    event.context.redisPublisher = redisPublisher
  })

  console.log('Redis publisher initialized for API routes.')
})
