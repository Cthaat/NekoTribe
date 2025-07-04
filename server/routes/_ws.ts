// server/routes/_ws.ts

import { WebSocketServer, WebSocket } from 'ws'
import Redis from 'ioredis'
import type { IncomingMessage } from 'node:http'
import type { Duplex } from 'node:stream'
import url from 'node:url'
import { verifyTokenAndGetUserId } from '../utils/auth'

// 这个 Map 只存储本服务器实例上的连接
// Key: userId (string), Value: WebSocket 实例
const userConnections = new Map<string, WebSocket>()

const REDIS_CHANNEL = 'global-notifications'

let wss: WebSocketServer | null = null
let redisPublisher: Redis | null = null
let redisSubscriber: Redis | null = null

function initializeWebSocket() {
  if (wss) return wss

  const config = useRuntimeConfig()
  
  if (!config.redisUrl) {
    console.warn('Redis URL is not configured. WebSocket push notifications will not work across multiple instances.')
    return null
  }

  // 创建两个 Redis 客户端
  redisPublisher = new Redis(config.redisUrl)
  redisSubscriber = new Redis(config.redisUrl)

  wss = new WebSocketServer({ noServer: true })

  // 订阅 Redis 频道
  redisSubscriber.subscribe(REDIS_CHANNEL, (err) => {
    if (err) {
      console.error('Failed to subscribe to Redis channel:', err)
    } else {
      console.log(`Subscribed to Redis channel: "${REDIS_CHANNEL}"`)
    }
  })

  // 监听从 Redis 频道收到的消息
  redisSubscriber.on('message', (channel, message) => {
    if (channel === REDIS_CHANNEL) {
      try {
        const { userId, payload } = JSON.parse(message) as { userId: string; payload: any }
        
        // 在本机的连接池中查找该用户
        const ws = userConnections.get(userId)
        
        // 如果找到了，并且连接是打开的，就发送消息
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify(payload))
          console.log(`Pushed message to user ${userId} on this instance.`)
        }
      } catch (e) {
        console.error('Error processing message from Redis:', e)
      }
    }
  })

  wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
    // 1. 认证用户
    const { query } = url.parse(req.url!, true)
    const token = query.token as string
    
    const userId = verifyTokenAndGetUserId(token)
    
    if (!userId) {
      console.log('WebSocket connection rejected: Invalid or missing token.')
      ws.close(1008, 'Invalid authentication token')
      return
    }

    console.log(`Client authenticated with userId: ${userId}. Connection established.`)

    // 2. 存储连接
    userConnections.set(userId, ws)

    ws.on('close', () => {
      console.log(`Client disconnected: ${userId}.`)
      userConnections.delete(userId)
    })

    ws.on('error', (error) => {
      console.error(`WebSocket error for user ${userId}:`, error)
      userConnections.delete(userId) // 发生错误时也清理连接
    })
    
    // 可选：发送一个欢迎消息
    ws.send(JSON.stringify({ type: 'WELCOME', message: `Hello ${userId}, you are connected!` }))
  })

  console.log('WebSocket server initialized.')
  return wss
}

export default defineEventHandler(async (event) => {
  const wss = initializeWebSocket()
  
  if (!wss) {
    throw createError({
      statusCode: 500,
      statusMessage: 'WebSocket server not available'
    })
  }

  // 检查是否是 WebSocket 升级请求
  const upgrade = getHeader(event, 'upgrade')
  const connection = getHeader(event, 'connection')
  
  if (upgrade === 'websocket' && connection === 'Upgrade') {
    // 这是一个 WebSocket 升级请求
    const req = event.node.req as IncomingMessage
    const socket = event.node.req.socket as Duplex
    const head = Buffer.alloc(0) // 在这个简化版本中，我们使用空 buffer
    
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit('connection', ws, req)
    })
    
    return
  }

  // 如果不是 WebSocket 升级请求，返回错误
  throw createError({
    statusCode: 400,
    statusMessage: 'WebSocket connection required'
  })
})

// 导出 Redis Publisher 以供其他模块使用
export { redisPublisher }
