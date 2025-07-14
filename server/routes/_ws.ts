// server/routes/_ws.ts
// 这是 Nuxt.js 的 WebSocket 路由处理器，用于处理实时通信

// 导入会话管理器，用于管理所有 WebSocket 连接
import { sessionManager } from '../utils/wsSession';
// 导入 Redis 相关工具，用于实现消息的发布/订阅功能
import {
  publishMessage, // 发布消息到 Redis 频道
  subscribeToChannel, // 订阅 Redis 频道
  REDIS_CHANNELS, // Redis 频道名称常量
  type WSMessage // WebSocket 消息类型定义
} from '../utils/redis';

// 扩展 Peer 接口，添加自定义的 sessionId 属性
// Peer 是 crossws 库提供的 WebSocket 连接对象
interface ExtendedPeer extends Peer {
  sessionId?: string; // 可选的会话 ID，用于标识每个连接
}

// 导入 Peer 类型，这是 WebSocket 连接的基础类型
import type { Peer } from 'crossws';

/**
 * 生成唯一的会话ID
 * 格式：ws_时间戳_随机字符串
 * 例如：ws_1640995200000_abc123def
 */
function generateSessionId(): string {
  return `ws_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
}

// 全局标志：跟踪 Redis 订阅是否已经初始化
// 这确保我们不会重复订阅同一个频道
let redisSubscriptionsInitialized = false;

/**
 * 初始化 Redis 订阅功能
 * 这个函数只在第一个 WebSocket 连接建立时执行一次
 * 它会订阅所有需要的 Redis 频道，以便接收来自其他服务器实例的消息
 */
function initializeRedisSubscriptions() {
  // 如果已经初始化过，直接返回，避免重复订阅
  if (redisSubscriptionsInitialized) return;

  // 订阅全局广播频道
  // 当有人发送广播消息时，这个回调函数会被执行
  subscribeToChannel(
    REDIS_CHANNELS.BROADCAST,
    (message: WSMessage) => {
      console.log('收到广播消息:', message);
      // 将收到的广播消息转发给所有连接的客户端
      broadcastToAllSessions(message);
    }
  );

  // 订阅系统通知频道
  // 用于接收系统级别的通知消息
  subscribeToChannel(
    REDIS_CHANNELS.SYSTEM_NOTIFICATION,
    (message: WSMessage) => {
      console.log('收到系统通知:', message);
      // 将系统通知广播给所有连接的客户端
      broadcastToAllSessions(message);
    }
  );

  // 标记订阅已完成，防止重复初始化
  redisSubscriptionsInitialized = true;
  console.log('Redis 订阅已初始化');
}

/**
 * 向所有已连接的 WebSocket 客户端广播消息
 * @param message 要广播的消息对象
 */
function broadcastToAllSessions(message: WSMessage) {
  // 从会话管理器获取所有活跃的会话
  const sessions = sessionManager.getAllSessions();

  // 遍历每个会话，发送消息
  sessions.forEach(session => {
    try {
      // 将消息对象转换为 JSON 字符串并发送
      session.peer.send(JSON.stringify(message));
    } catch (error) {
      // 如果发送失败（比如连接已断开），记录错误但不中断其他发送
      console.error('发送广播消息失败:', error);
    }
  });
}

/**
 * 向指定房间内的所有用户发送消息
 * @param roomId 房间ID
 * @param message 要发送的消息对象
 */
function sendToRoom(roomId: string, message: WSMessage) {
  // 获取指定房间内的所有会话
  const roomSessions =
    sessionManager.getRoomSessions(roomId);

  // 遍历房间内的每个会话，发送消息
  roomSessions.forEach(session => {
    try {
      // 将消息转换为 JSON 并发送给客户端
      session.peer.send(JSON.stringify(message));
    } catch (error) {
      // 记录发送失败的错误
      console.error(
        `向房间 ${roomId} 发送消息失败:`,
        error
      );
    }
  });
}

// 导出默认的 WebSocket 处理器
// defineWebSocketHandler 是 Nuxt.js 提供的函数，用于创建 WebSocket 路由
export default defineWebSocketHandler({
  /**
   * open 事件：当新的客户端连接到 WebSocket 服务器时触发
   * @param peer WebSocket 连接对象，代表一个客户端连接
   */
  open(peer) {
    // 1. 为新连接生成唯一的会话ID
    const sessionId = generateSessionId();

    // 2. 将 peer 对象转换为扩展类型，以便添加自定义属性
    const extendedPeer = peer as ExtendedPeer;
    extendedPeer.sessionId = sessionId;

    // 3. 初始化 Redis 订阅（只在第一次连接时执行）
    // 这样可以接收来自其他服务器实例的消息
    initializeRedisSubscriptions();

    // 4. 将新会话添加到会话管理器中
    // 会话管理器会跟踪所有活跃的连接
    sessionManager.addSession(sessionId, peer);

    // 5. 创建欢迎消息对象
    const welcomeMessage: WSMessage = {
      type: 'system_notification', // 消息类型：系统通知
      data: {
        message: '欢迎连接到 NekoTribe WebSocket 服务器！',
        sessionId // 将会话ID发送给客户端，方便调试
      },
      timestamp: Date.now() // 添加时间戳
    };

    // 6. 将欢迎消息发送给新连接的客户端
    // JSON.stringify 将对象转换为 JSON 字符串
    peer.send(JSON.stringify(welcomeMessage));

    // 7. 在服务器控制台记录连接信息
    console.log(`[ws] 连接已建立 - 会话ID: ${sessionId}`);
  },

  /**
   * message 事件：当客户端发送消息到服务器时触发
   * @param peer 发送消息的客户端连接对象
   * @param message 客户端发送的消息对象
   */
  async message(peer, message) {
    // 1. 从 peer 对象中获取会话ID
    const sessionId = (peer as ExtendedPeer).sessionId;
    if (!sessionId) return; // 如果没有会话ID，直接返回

    // 2. 更新会话的最后活动时间
    // 这用于会话超时管理，定期清理不活跃的连接
    sessionManager.updateActivity(sessionId);

    // 3. 根据会话ID获取会话对象
    const session = sessionManager.getSession(sessionId);
    if (!session) return; // 如果会话不存在，直接返回

    // 4. 记录收到的消息到控制台
    console.log(
      `[ws] 收到消息 - 会话: ${sessionId}`,
      message.text()
    );

    try {
      // 5. 尝试将消息文本解析为 JSON 对象
      const parsedMessage = JSON.parse(message.text());
      const { type, data } = parsedMessage; // 解构获取消息类型和数据

      // 6. 根据消息类型进行不同的处理
      switch (type) {
        case 'join_room':
          // 处理加入房间请求
          await handleJoinRoom(sessionId, data);
          break;

        case 'leave_room':
          // 处理离开房间请求
          await handleLeaveRoom(sessionId, data);
          break;

        case 'room_message':
          // 处理房间内消息
          await handleRoomMessage(sessionId, data);
          break;

        case 'broadcast':
          // 处理广播消息
          await handleBroadcast(sessionId, data);
          break;

        case 'ping':
          // 处理心跳检测
          // 客户端发送 ping，服务器回复 pong
          peer.send(
            JSON.stringify({
              type: 'pong',
              data: { timestamp: Date.now() },
              timestamp: Date.now()
            })
          );
          break;

        default:
          // 默认处理：对于未知的消息类型，简单回显
          const echoMessage: WSMessage = {
            type: 'system_notification',
            data: {
              message: `收到消息: ${message.text()}`,
              originalMessage: message.text() // 包含原始消息内容
            },
            timestamp: Date.now()
          };
          peer.send(JSON.stringify(echoMessage));
      }
    } catch (error) {
      // 7. 如果 JSON 解析失败，说明收到的是普通文本消息
      if (message.text().includes('ping')) {
        // 如果文本包含 "ping"，回复 "pong"
        peer.send(
          JSON.stringify({
            type: 'pong',
            data: { message: 'pong' },
            timestamp: Date.now()
          })
        );
      } else {
        // 对于其他文本消息，简单回显
        const textMessage: WSMessage = {
          type: 'system_notification',
          data: {
            message: `收到文本消息: ${message.text()}`
          },
          timestamp: Date.now()
        };
        peer.send(JSON.stringify(textMessage));
      }
    }
  },

  /**
   * close 事件：当客户端断开连接时触发
   * @param peer 断开连接的客户端对象
   * @param event 关闭事件的详细信息
   */
  close(peer, event) {
    // 1. 获取断开连接的会话ID
    const sessionId = (peer as ExtendedPeer).sessionId;

    if (sessionId) {
      // 2. 记录连接关闭信息
      console.log(
        `[ws] 连接已关闭 - 会话: ${sessionId}`,
        event
      );

      // 3. 从会话管理器中移除该会话
      // 这会清理相关资源，包括从房间中移除用户
      sessionManager.removeSession(sessionId);
    }
  },

  /**
   * error 事件：当 WebSocket 连接发生错误时触发
   * @param peer 发生错误的客户端对象
   * @param error 错误信息
   */
  error(peer, error) {
    // 获取会话ID并记录错误信息
    const sessionId = (peer as ExtendedPeer).sessionId;
    console.log(`[ws] 错误 - 会话: ${sessionId}`, error);
  }
});

/**
 * 处理客户端加入房间的请求
 * @param sessionId 发起请求的会话ID
 * @param data 请求数据，包含要加入的房间ID
 */
async function handleJoinRoom(
  sessionId: string,
  data: any
) {
  // 1. 从请求数据中提取房间ID
  const { roomId } = data;
  if (!roomId) return; // 如果没有提供房间ID，直接返回

  // 2. 调用会话管理器的方法，将用户加入指定房间
  const success = sessionManager.joinRoom(
    sessionId,
    roomId
  );

  // 3. 获取会话对象
  const session = sessionManager.getSession(sessionId);

  // 4. 如果加入成功且会话存在，通知房间内的其他用户
  if (success && session) {
    // 创建用户加入房间的通知消息
    const joinMessage: WSMessage = {
      type: 'room_message',
      data: {
        roomId,
        message: `用户 ${sessionId} 加入了房间`,
        messageType: 'user_joined' // 标记这是用户加入事件
      },
      from: sessionId, // 消息来源
      room: roomId, // 目标房间
      timestamp: Date.now()
    };

    // 5. 将消息发布到 Redis，这样其他服务器实例也能收到通知
    // 这对于分布式部署很重要，确保所有服务器上的用户都能看到加入通知
    await publishMessage(
      `${REDIS_CHANNELS.ROOM_MESSAGE}${roomId}`,
      joinMessage
    );

    // 6. 在本地服务器上向房间内的所有用户发送通知
    sendToRoom(roomId, joinMessage);
  }
}

/**
 * 处理客户端离开房间的请求
 * @param sessionId 发起请求的会话ID
 * @param data 请求数据，包含要离开的房间ID
 */
async function handleLeaveRoom(
  sessionId: string,
  data: any
) {
  // 1. 从请求数据中提取房间ID
  const { roomId } = data;
  if (!roomId) return; // 如果没有提供房间ID，直接返回

  // 2. 获取会话对象（在离开之前获取，确保会话存在）
  const session = sessionManager.getSession(sessionId);

  // 3. 调用会话管理器的方法，将用户从指定房间中移除
  const success = sessionManager.leaveRoom(
    sessionId,
    roomId
  );

  // 4. 如果离开成功且会话存在，通知房间内的其他用户
  if (success && session) {
    // 创建用户离开房间的通知消息
    const leaveMessage: WSMessage = {
      type: 'room_message',
      data: {
        roomId,
        message: `用户 ${sessionId} 离开了房间`,
        messageType: 'user_left' // 标记这是用户离开事件
      },
      from: sessionId, // 消息来源
      room: roomId, // 目标房间
      timestamp: Date.now()
    };

    // 5. 将消息发布到 Redis，通知其他服务器实例
    await publishMessage(
      `${REDIS_CHANNELS.ROOM_MESSAGE}${roomId}`,
      leaveMessage
    );

    // 6. 在本地服务器上向房间内的剩余用户发送通知
    sendToRoom(roomId, leaveMessage);
  }
}

/**
 * 处理房间内的消息发送
 * @param sessionId 发送消息的会话ID
 * @param data 消息数据，包含房间ID和消息内容
 */
async function handleRoomMessage(
  sessionId: string,
  data: any
) {
  // 1. 从请求数据中提取房间ID和消息内容
  const { roomId, message: messageText } = data;
  if (!roomId || !messageText) return; // 必须提供房间ID和消息内容

  // 2. 获取发送者的会话对象
  const session = sessionManager.getSession(sessionId);

  // 3. 验证发送者是否在目标房间中
  if (!session || !session.joinedRooms.has(roomId)) {
    // 如果用户不在房间中，发送错误消息
    session?.peer.send(
      JSON.stringify({
        type: 'error',
        data: { message: '您不在该房间中' },
        timestamp: Date.now()
      })
    );
    return;
  }

  // 4. 创建房间消息对象
  const roomMessage: WSMessage = {
    type: 'room_message',
    data: {
      roomId,
      message: messageText,
      messageType: 'text', // 标记这是文本消息
      sender: sessionId // 发送者的会话ID
    },
    from: sessionId, // 消息来源
    room: roomId, // 目标房间
    timestamp: Date.now()
  };

  // 5. 将消息发布到 Redis，让其他服务器实例也能收到
  await publishMessage(
    `${REDIS_CHANNELS.ROOM_MESSAGE}${roomId}`,
    roomMessage
  );

  // 6. 在本地服务器上向房间内的所有用户发送消息
  sendToRoom(roomId, roomMessage);
}

/**
 * 处理全局广播消息
 * @param sessionId 发送广播的会话ID
 * @param data 广播数据，包含要广播的消息内容
 */
async function handleBroadcast(
  sessionId: string,
  data: any
) {
  // 1. 从请求数据中提取消息内容
  const { message: messageText } = data;
  if (!messageText) return; // 必须提供消息内容

  // 2. 获取发送者的会话对象
  const session = sessionManager.getSession(sessionId);
  if (!session) {
    return; // 如果会话不存在，直接返回
  }

  // 3. 创建广播消息对象
  const broadcastMessage: WSMessage = {
    type: 'broadcast',
    data: {
      message: messageText,
      sender: sessionId // 广播发送者的会话ID
    },
    from: sessionId, // 消息来源
    timestamp: Date.now()
  };

  // 4. 将广播消息发布到 Redis
  // 这确保所有服务器实例上的所有用户都能收到广播
  await publishMessage(
    REDIS_CHANNELS.BROADCAST,
    broadcastMessage
  );

  // 5. 在本地服务器上向所有连接的用户广播消息
  broadcastToAllSessions(broadcastMessage);
}
