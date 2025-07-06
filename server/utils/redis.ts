// server/utils/redis.ts
// ========================================
// Redis 工具库 - WebSocket 消息传递支持
// ========================================
// 本文件提供了 Redis 的完整功能，支持：
// 1. Redis 连接管理（客户端、发布者、订阅者）
// 2. 发布/订阅（Pub/Sub）消息传递
// 3. Redis 连接字符串和配置参数的自动适配
// 4. Redis 不可用时的优雅降级处理
// 5. 多服务器实例间的实时消息同步

// 导入 ioredis 库 - 这是一个功能强大的 Redis 客户端库
import Redis from 'ioredis'

// =====================================
// 全局变量定义
// =====================================

const runtimeConfig = useRuntimeConfig()

// Redis 客户端实例 - 用于一般的 Redis 操作（读写数据）
let redisClient: Redis | null = null

// Redis 订阅者实例 - 专门用于订阅 Redis 频道
// 注意：Redis 的订阅连接不能用于其他操作，所以需要单独的实例
let redisSubscriber: Redis | null = null

// Redis 发布者实例 - 专门用于发布消息到 Redis 频道
let redisPublisher: Redis | null = null

// Redis 可用性标志 - 当 Redis 连接失败时设为 false，启用降级模式
let redisAvailable = true

/**
 * 检查 Redis 是否可用
 * @returns boolean - true 表示 Redis 可用，false 表示需要降级处理
 * 
 * 这个函数被其他模块调用，用于决定是否使用 Redis 功能
 * 当 Redis 不可用时，系统会自动降级为单机模式
 */
export function isRedisAvailable(): boolean {
  return redisAvailable
}

/**
 * 创建 Redis 连接配置
 * @returns 返回 Redis 连接字符串或配置对象
 * 
 * 支持两种配置方式：
 * 1. 使用 REDIS_URL 环境变量（如：redis://192.168.2.166:6379）
 * 2. 使用单独的环境变量（REDIS_HOST、REDIS_PORT 等）
 */
function createRedisConfig() {
  // 优先使用 REDIS_URL 连接字符串
  const redisUrl = runtimeConfig.redisUrl

  if (redisUrl) {
    // 如果设置了 REDIS_URL，直接返回连接字符串
    // 格式示例：redis://username:password@hostname:port/database
    return redisUrl
  } else {
    // 如果没有 REDIS_URL，使用单独的配置参数
    return {
      host: runtimeConfig.redisHost,      // Redis 服务器地址
      port: parseInt(runtimeConfig.redisPort),      // Redis 端口号
      password: runtimeConfig.redisPassword,                  // Redis 密码（可选）
      db: parseInt(runtimeConfig.redisDb),             // 数据库编号（默认为 0）
    }
  }
}

/**
 * 获取 Redis 客户端实例（用于一般操作）
 * @returns Redis 实例或 null（当 Redis 不可用时）
 * 
 * 这个函数采用懒加载模式，只在第一次调用时创建连接
 * 如果 Redis 连接失败，会自动设置降级模式
 */
export function getRedisClient(): Redis | null {
  // 如果 Redis 已被标记为不可用，直接返回 null
  if (!redisAvailable) return null
  
  // 如果客户端实例不存在，创建新的连接
  if (!redisClient) {
    try {
      // 获取 Redis 连接配置
      const config = createRedisConfig()
      
      // 根据配置类型创建 Redis 实例
      if (typeof config === 'string') {
        // 使用 Redis URL 连接字符串创建实例
        // 示例：redis://192.168.2.166:6379
        redisClient = new Redis(config)
      } else {
        // 使用配置对象创建实例
        redisClient = new Redis({
        })
      }

      // 设置 Redis 客户端的事件监听器
      // 这些监听器帮助我们跟踪连接状态和处理错误
      
      // 错误事件：当 Redis 连接出现问题时触发
      redisClient.on('error', (error) => {
        console.error('Redis 客户端错误:', error.message)
        // 设置 Redis 为不可用状态，启用降级模式
        redisAvailable = false
      })

      // 连接事件：当成功连接到 Redis 服务器时触发
      redisClient.on('connect', () => {
        console.log('Redis 客户端连接成功')
        // 恢复 Redis 可用状态
        redisAvailable = true
      })

      // 关闭事件：当 Redis 连接关闭时触发
      redisClient.on('close', () => {
        console.log('Redis 客户端连接关闭')
      })
    } catch (error) {
      // 如果创建 Redis 客户端时发生异常，记录错误并启用降级模式
      console.error('创建 Redis 客户端失败:', error)
      redisAvailable = false
      return null
    }
  }

  return redisClient
}

/**
 * 获取 Redis 订阅者实例（专门用于订阅频道）
 * @returns Redis 订阅者实例或 null
 * 
 * Redis 的发布/订阅模式要求订阅连接专用，不能用于其他 Redis 操作
 * 所以需要创建专门的订阅者实例
 */
export function getRedisSubscriber(): Redis | null {
  // 如果 Redis 不可用，返回 null
  if (!redisAvailable) return null
  
  // 如果订阅者实例不存在，创建新的连接
  if (!redisSubscriber) {
    try {
      // 获取 Redis 连接配置
      const config = createRedisConfig()
      
      // 根据配置类型创建订阅者实例
      if (typeof config === 'string') {
        // 使用 Redis URL 连接字符串
        redisSubscriber = new Redis(config)
      } else {
        // 使用配置对象
        redisSubscriber = new Redis({
          host: runtimeConfig.redisHost,
          port: parseInt(runtimeConfig.redisPort),
          password: runtimeConfig.redisPassword,
          db: parseInt(runtimeConfig.redisDb),
        })
      }

      // 设置订阅者的事件监听器
      redisSubscriber.on('error', (error) => {
        console.error('Redis 订阅者错误:', error.message)
        redisAvailable = false
      })

      // 订阅者连接成功事件
      redisSubscriber.on('connect', () => {
        console.log('Redis 订阅者连接成功')
      })

      // 订阅者连接关闭事件
      redisSubscriber.on('close', () => {
        console.log('Redis 订阅者连接关闭')
      })
    } catch (error) {
      // 创建订阅者失败时的错误处理
      console.error('创建 Redis 订阅者失败:', error)
      redisAvailable = false
      return null
    }
  }

  return redisSubscriber
}

/**
 * 获取 Redis 发布者实例（专门用于发布消息）
 * @returns Redis 发布者实例或 null
 * 
 * 虽然普通的 Redis 客户端也可以发布消息，但为了保持架构清晰
 * 我们创建专门的发布者实例来处理消息发布
 */
export function getRedisPublisher(): Redis | null {
  // 如果 Redis 不可用，返回 null
  if (!redisAvailable) return null
  
  // 如果发布者实例不存在，创建新的连接
  if (!redisPublisher) {
    try {
      // 获取 Redis 连接配置
      const config = createRedisConfig()
      
      // 根据配置类型创建发布者实例
      if (typeof config === 'string') {
        // 使用 Redis URL 连接字符串
        redisPublisher = new Redis(config)
      } else {
        // 使用配置对象
        redisPublisher = new Redis({
          host: runtimeConfig.redisHost,
          port: parseInt(runtimeConfig.redisPort),
          password: runtimeConfig.redisPassword,
          db: parseInt(runtimeConfig.redisDb),
        })
      }

      // 设置发布者的事件监听器
      redisPublisher.on('error', (error) => {
        console.error('Redis 发布者错误:', error.message)
        redisAvailable = false
      })

      // 发布者连接成功事件
      redisPublisher.on('connect', () => {
        console.log('Redis 发布者连接成功')
        redisAvailable = true
      })

      // 发布者连接关闭事件
      redisPublisher.on('close', () => {
        console.log('Redis 发布者连接关闭')
      })
    } catch (error) {
      // 创建发布者失败时的错误处理
      console.error('创建 Redis 发布者失败:', error)
      redisAvailable = false
      return null
    }
  }

  return redisPublisher
}

// =====================================
// Redis 频道常量定义
// =====================================

/**
 * WebSocket 相关的 Redis 频道常量
 * 
 * 这些常量定义了系统中使用的所有 Redis 频道名称
 * 使用常量可以避免拼写错误，便于维护
 */
export const REDIS_CHANNELS = {
  BROADCAST: 'ws:broadcast',        // 全局广播频道 - 向所有连接的用户发送消息
  USER_MESSAGE: 'ws:user:',         // 用户私信频道前缀 (完整格式: ws:user:{userId})
  ROOM_MESSAGE: 'ws:room:',         // 房间消息频道前缀 (完整格式: ws:room:{roomId})
  SYSTEM_NOTIFICATION: 'ws:system', // 系统通知频道 - 系统级别的通知消息
} as const

// =====================================
// 类型定义
// =====================================

/**
 * WebSocket 消息接口定义
 * 
 * 这个接口定义了系统中所有 WebSocket 消息的标准格式
 * 所有通过 WebSocket 传输的消息都应该遵循这个格式
 */
export interface WSMessage {
  type: 'broadcast' | 'user_message' | 'room_message' | 'system_notification' // 消息类型
  from?: string      // 发送者标识（可选）
  to?: string        // 接收者标识（可选，用于私信）
  room?: string      // 房间标识（可选，用于房间消息）
  data: any          // 消息数据，可以是任何类型
  timestamp: number  // 时间戳，用于消息排序和过期处理
}

// =====================================
// 消息发布/订阅功能
// =====================================

/**
 * 发布消息到指定的 Redis 频道
 * @param channel 频道名称
 * @param message 要发布的消息对象
 * 
 * 这个函数将消息发布到 Redis 频道，其他服务器实例可以订阅该频道来接收消息
 * 支持降级处理：当 Redis 不可用时，只记录日志不影响程序运行
 */
export async function publishMessage(channel: string, message: WSMessage) {
  // 如果 Redis 不可用，记录日志并直接返回（降级处理）
  if (!redisAvailable) {
    console.log(`Redis 不可用，跳过发布消息到频道 ${channel}:`, message)
    return
  }
  
  // 获取 Redis 发布者实例
  const publisher = getRedisPublisher()
  if (!publisher) {
    console.log(`Redis 发布者不可用，跳过发布消息到频道 ${channel}`)
    return
  }
  
  try {
    // 将消息对象转换为 JSON 字符串并发布到指定频道
    await publisher.publish(channel, JSON.stringify(message))
    console.log(`消息已发布到频道 ${channel}:`, message)
  } catch (error) {
    // 发布失败时记录错误，但不影响程序继续运行
    console.error(`发布消息到频道 ${channel} 失败:`, error)
  }
}

/**
 * 订阅指定的 Redis 频道
 * @param channel 要订阅的频道名称
 * @param callback 收到消息时的回调函数
 * 
 * 当有消息发布到指定频道时，callback 函数会被调用
 * 支持降级处理：当 Redis 不可用时，只记录日志
 */
export async function subscribeToChannel(channel: string, callback: (message: WSMessage) => void) {
  // 如果 Redis 不可用，记录日志并直接返回
  if (!redisAvailable) {
    console.log(`Redis 不可用，跳过订阅频道 ${channel}`)
    return
  }
  
  // 获取 Redis 订阅者实例
  const subscriber = getRedisSubscriber()
  if (!subscriber) {
    console.log(`Redis 订阅者不可用，跳过订阅频道 ${channel}`)
    return
  }
  
  // 订阅指定频道
  // subscribe 方法是异步的，第二个参数是回调函数
  subscriber.subscribe(channel, (error, count) => {
    if (error) {
      console.error(`订阅频道 ${channel} 失败:`, error)
    } else {
      console.log(`成功订阅频道 ${channel}，当前订阅数量: ${count}`)
    }
  })

  // 监听消息事件
  // 当有消息发布到我们订阅的频道时，这个事件会被触发
  subscriber.on('message', (receivedChannel, message) => {
    // 确保消息来自我们订阅的频道（一个订阅者可能订阅多个频道）
    if (receivedChannel === channel) {
      try {
        // 将 JSON 字符串解析为消息对象
        const parsedMessage: WSMessage = JSON.parse(message)
        // 调用回调函数处理收到的消息
        callback(parsedMessage)
      } catch (error) {
        // 解析失败时记录错误
        console.error(`解析频道 ${channel} 消息失败:`, error)
      }
    }
  })
}
