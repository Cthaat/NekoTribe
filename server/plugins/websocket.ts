// server/plugins/websocket.ts

import { WebSocketServer, WebSocket } from 'ws'
import Redis from 'ioredis'
import type { IncomingMessage } from 'node:http'
import type { Duplex } from 'node:stream'
import url from 'node:url'
import { verifyTokenAndGetUserId } from '../utils/auth'

// 全局连接存储
const userConnections = new Map<string, WebSocket>()
const REDIS_CHANNEL = 'global-notifications'

let wss: WebSocketServer | null = null
let redisPublisher: Redis | null = null
let redisSubscriber: Redis | null = null

export default defineNitroPlugin((nitroApp) => {
  // 只在服务器端执行
  if (!process.server) return

  const config = useRuntimeConfig()
  
  if (!config.redisUrl) {
    console.warn('Redis URL 未配置。WebSocket 推送通知在多实例间将无法工作。')
    return
  }

  // 创建 Redis 客户端
  redisPublisher = new Redis(config.redisUrl)
  redisSubscriber = new Redis(config.redisUrl)

  // 创建 WebSocket 服务器
  wss = new WebSocketServer({ noServer: true })

  // 订阅 Redis 频道
  redisSubscriber.subscribe(REDIS_CHANNEL, (err) => {
    if (err) {
      console.error('订阅 Redis 频道失败:', err)
    } else {
      console.log(`已订阅 Redis 频道: "${REDIS_CHANNEL}"`)
    }
  })

  // 监听 Redis 消息
  redisSubscriber.on('message', (channel, message) => {
    if (channel === REDIS_CHANNEL) {
      try {
        const { userId, payload } = JSON.parse(message) as { userId: string; payload: any }
        
        // 查找用户连接
        const ws = userConnections.get(userId)
        
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify(payload))
          console.log(`向用户 ${userId} 推送消息成功`)
        }
      } catch (e) {
        console.error('处理 Redis 消息时出错:', e)
      }
    }
  })

  // 处理 WebSocket 连接
  wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
    // 认证用户
    const { query } = url.parse(req.url!, true)
    const token = query.token as string
    
    const userId = verifyTokenAndGetUserId(token)
    
    if (!userId) {
      console.log('WebSocket 连接被拒绝: 无效或缺失的 token')
      ws.close(1008, 'Invalid authentication token')
      return
    }

    console.log(`用户 ${userId} 已认证并建立连接`)

    // 存储连接
    userConnections.set(userId, ws)

    // 发送欢迎消息
    ws.send(JSON.stringify({ 
      type: 'WELCOME', 
      message: `你好 ${userId}，连接已建立！` 
    }))

    // 处理连接关闭
    ws.on('close', () => {
      console.log(`用户 ${userId} 断开连接`)
      userConnections.delete(userId)
    })

    // 处理连接错误
    ws.on('error', (error) => {
      console.error(`用户 ${userId} WebSocket 错误:`, error)
      userConnections.delete(userId)
    })
  })

  // 将 Redis Publisher 注入到上下文中
  nitroApp.hooks.hook('request', (event) => {
    event.context.redisPublisher = redisPublisher
  })

  // 处理 HTTP 升级事件 - 这是关键部分
  nitroApp.hooks.hook('request', (event) => {
    const req = event.node.req
    const socket = req.socket
    
    // 只为这个请求添加一次升级监听器
    if (!socket.listenerCount('upgrade')) {
      socket.once('upgrade', (upgradeReq: IncomingMessage, sock: Duplex, head: Buffer) => {
        console.log('收到升级请求:', upgradeReq.url)
        
        if (upgradeReq.url?.startsWith('/_ws')) {
          console.log('处理 WebSocket 升级请求')
          if (wss) {
            wss.handleUpgrade(upgradeReq, sock, head, (ws) => {
              wss!.emit('connection', ws, upgradeReq)
            })
          }
        } else {
          console.log('非 WebSocket 升级请求，销毁连接')
          sock.destroy()
        }
      })
    }
  })

  // 在服务器启动后设置 WebSocket 升级处理
  nitroApp.hooks.hook('close', () => {
    console.log('正在关闭 WebSocket 服务器...')
    if (redisPublisher) redisPublisher.disconnect()
    if (redisSubscriber) redisSubscriber.disconnect()
    if (wss) wss.close()
  })

  console.log('WebSocket 服务器已初始化')
})

// 导出全局访问函数
export function getWebSocketServer() {
  return wss
}

export function getRedisPublisher() {
  return redisPublisher
}
