# 批量通知状态开发检查点

Nuxt、Rust native 和 Go 对齐 `PUT /api/v2/notifications/read-status`：省略通知 ID 或传空数组更新当前用户全部未删除通知；指定数组按顺序更新当前用户的匹配通知，包括已删除通知。成功后返回受影响数量并向用户频道发布事件。指定模式沿用逐条提交，后续失败时前面的更新可能已生效且不发布成功事件；Redis 故障也不能回滚数据库写入。

旧 Nuxt 将错误类型或无效值过滤为空数组后误判为全部更新。现对 ID 数组设置 1000 项上限，并在任一元素不是安全正整数时返回 400，不执行写入。这是公开输入兼容性收紧；详见 `specifications/requirements/notification-batch-read.md`。Flutter 的 `markRead` 和 `markAllRead` 现在显式发送 `is_read:true`；空选中列表在客户端直接返回，不调用全部更新。

验证：Nuxt 根目录隔离测试 564 通过、2 跳过，之后增加的部分失败专项通过，类型检查通过；Flutter 分析无问题、135 项测试通过；Go 全量 test/vet 及随后增加的事件专项通过；Rust 离线全量测试通过，真实依赖测试仍忽略。测试采用模拟数据库、会话和消息发布，并不证明真实 Oracle 的提交、并发、Redis 投递或客户端跨后端联调。Rust 离线工具链未安装 rustfmt，本轮格式检查仍不可用。四工作区 OpenAPI 副本和共同需求登记已同步，整体状态仍为 `accepted:0`、`ready:false`。本轮未启动 Docker 或访问日常数据库。
