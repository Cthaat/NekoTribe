# 通知 WebSocket 基础共同需求

`GET /_ws` 支持 Nuxt Web 与 Flutter 客户端：按非空查询参数 `token`、Authorization、`access_token` Cookie 的顺序取 access token；签名、有效期及数据库会话均需验证。浏览器提供 Origin 时只允许当前同源或明确配置的来源。非法凭证或来源不得升级。纯远程通知源不可用时返回503；具有独立本地presence能力的混合源可以降级升级，但必须按local-presence.md报告能力和远程订阅状态，不能假称通知健康。认证后收到欢迎 `system_notification`，包括 `message`、非敏感连接 ID 和当前用户 ID；客户端的 JSON `ping` 返回 `pong` 和毫秒时间戳。

TLS 在代理终止时，原生后端以配置中的 HTTPS `BASE_URL` 作为允许的公共 WebSocket 来源。`BASE_URL` 填写完整来源，保留浏览器使用的非默认端口，末尾斜线可省略。Origin 必须精确匹配正规化的来源，带路径、凭据、查询或片段的值不能获得许可。其它来源仍通过既有 CORS 配置显式授权。握手不根据 `Forwarded` 或 `X-Forwarded-*` 推断来源。

用户通知只订阅经过认证的 `ws:user:{user_id}`。群聊通过下文约定的频道命令加入。连接仅转发有合法 JSON 包装、已登记类型的消息，限制帧及事件大小。发往客户端之前和定期心跳时重新验证 access token 与 session，撤销或过期后应断开。断连释放 Redis 订阅、任务和资源；订阅失败、积压和取消不得无限排队或泄漏凭据。跨实例通过 Redis Pub/Sub，发送成功不证明客户端收到；订阅不可用不得假称通知连接正常。

三套后端在握手和后续会话复核中，使用与 V2 HTTP 请求相同的条件更新。仅当会话仍有效且所属账号同时满足 `is_active = 1` 与 `status = 'active'` 时更新最后活跃时间。账号不可用时拒绝新连接，已有连接在下一次复核时断开。

鉴权无法确认（包括会话查询失败）时，握手返回 HTTP 401 和业务码 40101。Origin 拒绝返回 403 和 40301。容量已满或没有可用事件源时返回 503 和 50301。响应为 JSON 对象，包含 code、message、data:null、meta:null，且不得包含凭据或驱动错误。握手完成后的错误使用 WebSocket 帧。并发升级后若登记仍因容量失败，关闭该连接。

本协议覆盖通知、presence、认证、心跳、群频道及私信实时投递。断线期间的聊天记录通过 HTTP 历史接口恢复。反向代理、源校验、真实 Oracle 和 Redis、刷新与撤销、两个客户端和跨实例投递均需在隔离环境验收。


共享presence映射和事件编码按user-settings-presence.md：精确可见标志、hidden时间脱敏、固定字段、合法时钟和降级日志。不改变既有鉴权/业务提交规则。本地分发、跨实例回声去重、降级与重连按local-presence.md及LOCAL-PRESENCE场景执行；共同设置HTTP场景不代替本功能的完整验收。实现进度以parity.json和最新审计为准，不在规范中把局部测试写成已验收。

接收 Redis 事件时，毫秒时间戳为 `0` 至 `9007199254740991` 的 JSON 整数数值。用户频道仅接受已登记的通知和 `direct_message`。私信的外层 `data.conversation_id` 与 `data.direct_message.conversation_id` 必须相等，两处会话 ID 与 `message_id` 都必须是正安全整数。群聊事件使用频道订阅，`data.channel_id` 必须与 Redis 频道一致。`room` 省略或为 `null` 时按频道处理，给出时必须精确匹配该聊天房间。有效的通知保留原始 JSON。频道权限和用户会话复核仍由现有投递路径执行。

本机和 Redis 的 `direct_message` 在送出前还要通过 `direct-realtime-access.json` 中的同一条 Oracle 查询。以连接已认证的用户、外层会话 ID 和消息 ID 绑定参数。只有会话与消息都未删除，且该用户是会话参与者、消息属于该会话时才送出。查询失败、超时或找不到记录时丢弃该帧，保留连接和已提交消息。重连后通过已有 HTTP 历史接口补读消息。

`chat_join_channel` 和 `chat_leave_channel` 使用 `data.channelId` 指定频道，兼容 `channel_id`。客户端发送正安全整数。服务端也兼容由十进制数字和可选前导 `+` 组成的同范围字符串。加入前按当前会话复核频道读取权限，无效 ID 或无访问权限时返回 `error`。每连接最多加入 64 个频道。

频道加入回执只确认连接加入了房间。首次订阅及恢复订阅后，后端另发一条 `system_notification`，`data` 含 `code: "chat_channel_ready"`、`channel_id` 和 `room: "chat:channel:{channel_id}"`。就绪帧由当前连接生成，Redis 消息不能代发。两个客户端只在当前账号、后端及活动频道匹配时重新读取最新一页历史，合并请求期间收到的新增、更新和删除。全局连接恢复仍用于私信、通知以及旧后端兼容。

客户端收到当前连接的有效 `realtime_status` 后才发送 `chat_join_channel`。切换频道时发送 `chat_leave_channel` 并加入当前频道。发送成功只表示本地传输接受了帧。若传输写入抛错，立即清除连接状态并安排重连。重连后按那时的活动频道重新加入，旧连接的频道命令不跨账号、后端或连接重放。

私信恢复后重新读取活动会话的最新一页。Nuxt Web 和 Flutter 将请求期间同一会话收到的消息按 ID 合并，保留最新收到的数据，按时间及 ID 排序。切换账号、后端或会话后，旧历史响应不能写回当前页面。

用户频道也接受 `direct_message_deleted`。该事件只有会话 ID、消息 ID 和可选发布实例标识。发送前按共同查询复核收件身份和已删除状态。客户端从活动会话移除该消息并保留历史合并的删除标记。详细约定见 `direct-message-delete.md`。
