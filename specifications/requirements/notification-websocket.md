# 通知 WebSocket 基础共同需求

`GET /_ws` 支持 Nuxt Web 与 Flutter 客户端：按非空查询参数 `token`、Authorization、`access_token` Cookie 的顺序取 access token；签名、有效期及数据库会话均需验证。浏览器提供 Origin 时只允许当前同源或明确配置的来源。非法凭证、来源或不可用通知订阅不得建立可收通知的连接。认证后收到 `system_notification`，包括 `message`、非敏感连接 ID 和当前用户 ID；客户端的 JSON `ping` 返回 `pong` 和毫秒时间戳。

连接只能订阅经过认证的 `ws:user:{user_id}`，不接受客户端指定其他用户或频道；仅转发有合法 JSON 包装、已登记通知类型的消息，限制帧及事件大小。发往客户端之前和定期心跳时重新验证 access token 与 session，撤销或过期后应断开。断连释放 Redis 订阅、任务和资源；订阅失败、积压和取消不得无限排队或泄漏凭据。跨实例通过 Redis Pub/Sub，发送成功不证明客户端收到；订阅不可用不得假称通知连接正常。

此阶段只实现通知事件、认证和心跳；群频道、私信、在线状态、断线恢复、所有客户端与真实跨实例测试另需实现和验收，不将它称作完整 WebSocket 协议。反向代理、源校验、真实 Oracle/Redis、刷新/撤销和双客户端等需要隔离真实环境测试。
