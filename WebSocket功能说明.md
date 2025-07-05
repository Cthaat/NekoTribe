# NekoTribe WebSocket 功能说明

## 概述

本项目集成了基于 Redis Pub/Sub 的 WebSocket 功能，支持实时消息通信和房间管理。已移除用户认证功能，简化使用流程。

## 功能特性

### ✅ 已实现功能

1. **WebSocket 连接管理**
   - 自动分配会话 ID
   - 连接状态监控
   - 自动清理超时会话

2. **Redis Pub/Sub 集成**
   - 全局广播消息
   - 房间消息分发
   - 系统通知

3. **房间功能**
   - 加入/离开房间
   - 房间内消息发送
   - 房间用户进出通知

4. **消息类型**
   - 心跳检测 (ping/pong)
   - 文本消息
   - 房间消息
   - 广播消息
   - 系统通知

## 技术架构

### 后端组件

- **WebSocket 处理器**: `server/routes/_ws.ts`
- **Redis 客户端**: `server/utils/redis.ts`
- **会话管理器**: `server/utils/wsSession.ts`

### 前端组件

- **测试页面**: `pages/ws/index.vue`

## 环境配置

### 1. 环境变量

复制 `.env.example` 到 `.env` 并配置：

```bash
# Redis 配置
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=
REDIS_DB=0

# WebSocket 配置
WS_HEARTBEAT_INTERVAL=30000
WS_SESSION_TIMEOUT=1800000
```

### 2. 安装依赖

```bash
yarn install
```

### 3. 启动 Redis

确保 Redis 服务器正在运行：

```bash
# Windows (如果安装了 Redis)
redis-server

# 或使用 Docker
docker run -p 6379:6379 redis:alpine
```

### 4. 启动开发服务器

```bash
yarn dev
```

## API 使用

### WebSocket 连接

连接到 WebSocket 端点：

```javascript
const ws = new WebSocket('ws://localhost:3000/_ws')
```

### 消息格式

所有消息都使用 JSON 格式：

```javascript
{
  "type": "message_type",
  "data": { /* 消息数据 */ },
  "timestamp": 1640995200000
}
```

### 支持的消息类型

#### 1. 心跳检测

```javascript
// 发送
{ "type": "ping", "data": {}, "timestamp": Date.now() }

// 接收
{ "type": "pong", "data": { "timestamp": 1640995200000 }, "timestamp": 1640995200000 }
```

#### 2. 加入房间

```javascript
{
  "type": "join_room",
  "data": { "roomId": "room123" },
  "timestamp": Date.now()
}
```

#### 3. 离开房间

```javascript
{
  "type": "leave_room",
  "data": { "roomId": "room123" },
  "timestamp": Date.now()
}
```

#### 4. 房间消息

```javascript
{
  "type": "room_message",
  "data": { 
    "roomId": "room123",
    "message": "Hello, room!"
  },
  "timestamp": Date.now()
}
```

#### 5. 广播消息

```javascript
{
  "type": "broadcast",
  "data": { 
    "message": "Hello, everyone!"
  },
  "timestamp": Date.now()
}
```

## 测试功能

访问 `http://localhost:3000/ws` 可以使用内置的测试页面，功能包括：

1. **连接管理**
   - 连接/断开 WebSocket
   - 查看连接状态

2. **消息发送**
   - 发送普通文本消息
   - 发送心跳检测
   - 发送广播消息

3. **房间功能**
   - 加入/离开房间
   - 发送房间消息

4. **消息历史**
   - 查看所有收发消息
   - 格式化显示 JSON 数据

## Redis 频道说明

系统使用以下 Redis 频道：

- `ws:broadcast` - 全局广播消息
- `ws:room:{roomId}` - 房间消息
- `ws:system` - 系统通知

## 扩展功能

### 添加新消息类型

1. 在 `server/routes/_ws.ts` 的 `message` 处理函数中添加新的 case
2. 实现对应的处理函数
3. 在前端测试页面添加相应的 UI

### 集成数据库

可以在处理函数中添加数据库操作：

```javascript
// 例如：保存房间消息到数据库
async function handleRoomMessage(sessionId, data) {
  // ... 现有逻辑 ...
  
  // 保存到数据库
  await saveMessageToDatabase({
    sessionId,
    roomId: data.roomId,
    message: data.message,
    timestamp: Date.now()
  })
}
```

## 故障排除

### 常见问题

1. **Redis 连接失败**
   - 检查 Redis 服务是否启动
   - 验证环境变量配置

2. **WebSocket 连接失败**
   - 检查端口是否被占用
   - 查看浏览器控制台错误信息

3. **消息不能跨浏览器窗口传递**
   - 检查 Redis 是否正常工作
   - 查看服务器日志

### 调试技巧

1. 打开浏览器开发者工具查看 WebSocket 连接状态
2. 查看服务器控制台输出的日志信息
3. 使用 Redis CLI 监控频道活动：`redis-cli monitor`

## 性能考虑

1. **会话清理**：系统每 5 分钟自动清理超时会话
2. **消息历史**：前端只保留最新 50 条消息
3. **Redis 连接**：使用连接池管理 Redis 连接

## 后续改进

- [ ] 添加消息持久化
- [ ] 实现私信功能
- [ ] 添加文件传输支持
- [ ] 集成用户在线状态
- [ ] 添加消息加密
