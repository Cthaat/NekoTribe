// server/utils/wsSession.ts
// ======================================
// WebSocket 会话管理器
// ======================================
// 本文件管理所有 WebSocket 连接的会话状态，包括：
// 1. 会话的创建和销毁
// 2. 用户加入/离开房间的管理
// 3. 会话活动时间的跟踪
// 4. 房间成员的查询功能
// 
// 注意：本版本已移除用户认证功能，专注于会话和房间管理

// 导入 crossws 库的 Peer 类型
import type { Peer } from 'crossws'

// =====================================
// 类型定义
// =====================================

/**
 * WebSocket 会话信息接口
 * 
 * 每个 WebSocket 连接都对应一个会话对象
 * 该对象保存了连接的所有状态信息
 */
export interface WSSession {
  peer: Peer               // WebSocket 连接对象，用于发送消息
  joinedRooms: Set<string> // 用户已加入的房间集合（使用 Set 避免重复）
  lastActivity: number     // 最后活动时间戳，用于清理不活跃的连接
}

// =====================================
// 会话管理器类
// =====================================

/**
 * WebSocket 会话管理器类
 * 
 * 单例模式的会话管理器，负责管理所有活跃的 WebSocket 连接
 * 提供会话的增删改查、房间管理等功能
 */
class WSSessionManager {
  // 私有属性：存储所有会话的 Map
  // key: sessionId（会话ID）, value: WSSession（会话对象）
  private sessions = new Map<string, WSSession>()

  /**
   * 添加新的 WebSocket 会话
   * @param sessionId 唯一的会话标识符
   * @param peer WebSocket 连接对象
   * 
   * 当有新的客户端连接时调用此方法
   */
  addSession(sessionId: string, peer: Peer): void {
    // 创建新的会话对象
    const session: WSSession = {
      peer,                        // 保存 WebSocket 连接对象
      joinedRooms: new Set(),      // 初始化空的房间集合
      lastActivity: Date.now()     // 记录当前时间为最后活动时间
    }

    // 将会话添加到会话管理器中
    this.sessions.set(sessionId, session)
    console.log(`会话 ${sessionId} 已添加`)
  }

  /**
   * 移除指定的 WebSocket 会话
   * @param sessionId 要移除的会话ID
   * 
   * 当客户端断开连接时调用此方法
   * 会自动清理相关资源
   */
  removeSession(sessionId: string): void {
    // 获取要删除的会话
    const session = this.sessions.get(sessionId)
    if (!session) return  // 如果会话不存在，直接返回

    // 从会话管理器中删除该会话
    this.sessions.delete(sessionId)
    console.log(`会话 ${sessionId} 已移除`)
  }

  /**
   * 根据会话ID获取会话对象
   * @param sessionId 会话ID
   * @returns 会话对象或 undefined（如果不存在）
   */
  getSession(sessionId: string): WSSession | undefined {
    return this.sessions.get(sessionId)
  }

  /**
   * 将指定会话加入房间
   * @param sessionId 会话ID
   * @param roomId 房间ID
   * @returns boolean - true 表示成功，false 表示失败（会话不存在）
   * 
   * 房间是一个逻辑概念，用于将用户分组
   * 同一房间的用户可以互相发送消息
   */
  joinRoom(sessionId: string, roomId: string): boolean {
    // 获取指定的会话
    const session = this.sessions.get(sessionId)
    if (!session) return false  // 如果会话不存在，返回失败

    // 将房间ID添加到用户的已加入房间集合中
    // Set.add() 方法会自动去重，所以重复加入同一房间不会有问题
    session.joinedRooms.add(roomId)
    // 记录日志
    console.log(`会话 ${sessionId} 加入房间: ${roomId}`)
    return true  // 返回成功
  }

  /**
   * 将指定会话从房间中移除
   * @param sessionId 会话ID
   * @param roomId 房间ID
   * @returns boolean - true 表示成功，false 表示失败（会话不存在）
   */
  leaveRoom(sessionId: string, roomId: string): boolean {
    // 获取指定的会话
    const session = this.sessions.get(sessionId)
    if (!session) return false  // 如果会话不存在，返回失败

    // 从用户的已加入房间集合中移除指定房间
    // Set.delete() 方法会删除指定元素，如果元素不存在也不会报错
    session.joinedRooms.delete(roomId)
    
    // 记录日志
    console.log(`会话 ${sessionId} 离开房间: ${roomId}`)
    return true  // 返回成功
  }

  /**
   * 获取指定房间内的所有会话
   * @param roomId 房间ID
   * @returns WSSession[] - 房间内所有会话的数组
   * 
   * 这个方法遍历所有会话，找出加入了指定房间的会话
   * 用于向房间内所有用户发送消息
   */
  getRoomSessions(roomId: string): WSSession[] {
    const sessions: WSSession[] = []
    
    // 遍历所有会话
    for (const session of this.sessions.values()) {
      // 检查会话是否加入了指定房间
      if (session.joinedRooms.has(roomId)) {
        sessions.push(session)  // 添加到结果数组中
      }
    }

    return sessions  // 返回房间内所有会话的数组
  }

  /**
   * 更新指定会话的最后活动时间
   * @param sessionId 会话ID
   * 
   * 每当收到客户端消息时，都应该调用此方法更新活动时间
   * 这用于实现会话超时清理功能
   */
  updateActivity(sessionId: string): void {
    const session = this.sessions.get(sessionId)
    if (session) {
      // 更新为当前时间戳
      session.lastActivity = Date.now()
    }
  }

  /**
   * 获取所有活跃的会话
   * @returns WSSession[] - 所有会话的数组
   * 
   * 用于广播消息，向所有连接的用户发送消息
   */
  getAllSessions(): WSSession[] {
    // 将 Map 的 values 转换为数组并返回
    return Array.from(this.sessions.values())
  }

  /**
   * 清理超时的会话连接
   * @param timeoutMs 超时时间（毫秒），默认30分钟
   * 
   * 定期调用此方法可以清理长时间不活跃的连接
   * 避免内存泄漏和资源浪费
   */
  cleanupInactiveSessions(timeoutMs: number = 30 * 60 * 1000): void {
    const now = Date.now()  // 当前时间戳
    const expiredSessions: string[] = []  // 存储过期会话ID的数组

    // 遍历所有会话，找出超时的会话
    for (const [sessionId, session] of this.sessions) {
      // 如果最后活动时间距离现在超过了超时时间，则认为会话过期
      if (now - session.lastActivity > timeoutMs) {
        expiredSessions.push(sessionId)
      }
    }

    // 移除所有过期的会话
    for (const sessionId of expiredSessions) {
      this.removeSession(sessionId)
    }

    // 如果清理了会话，记录日志
    if (expiredSessions.length > 0) {
      console.log(`清理了 ${expiredSessions.length} 个超时会话`)
    }
  }
}

// =====================================
// 导出会话管理器实例
// =====================================

/**
 * 导出会话管理器的单例实例
 * 
 * 使用单例模式确保整个应用只有一个会话管理器实例
 * 这样可以在不同模块间共享会话状态
 */
export const sessionManager = new WSSessionManager()

/**
 * 定期清理超时会话的定时器
 * 
 * 每5分钟检查一次，自动清理30分钟内无活动的会话
 * 这有助于释放内存和清理僵尸连接
 */
setInterval(() => {
  sessionManager.cleanupInactiveSessions()
}, 5 * 60 * 1000)  // 5分钟 = 5 * 60 * 1000 毫秒
