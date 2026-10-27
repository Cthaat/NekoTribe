# 2026-10-27 原生会话列表检查点

Rust 原生模式与 Go 独立服务新增 `GET /api/v2/auth/sessions`：先验证 access token 并触碰共享会话，再按用户查询未撤销记录，返回 Nuxt 同结构的会话、当前设备标记和分页元数据。查询不经过 Nuxt 代理或 API 响应缓存。功能正文和版本化三端任务见 [共同需求](../../specifications/requirements/auth-session-list.md) 和 `parity.json` 的 `API-get_auth_sessions`。

- Nuxt 实际分页函数、Go 和 Rust 均通过 16 条公共分页样例，包含小数、科学计数、非十进制、重复和错误编码参数；Nuxt 原有 service 使用隔离数据库检查了查询、映射与分页元数据。
- Go 与 Rust 使用隔离仓储检查路由、身份验证、错误与当前会话标记；分别用假数据库驱动或执行器检查查询结构、参数绑定及日期/空值映射。测试并非真实 Oracle 运行。
- Nuxt 全量测试 461 通过、2 跳过；Go 全量测试、vet 与 Windows/Linux amd64 构建通过；Rust WSL Linux 离线全量测试通过，2 项真实依赖测试跳过。原生路由边界测试继续断言 Nuxt 上游零调用。
- `parity check --workspace-root` 核对 28 个共同文件的三端副本；该功能仍为 `in-progress`，总体 `accepted:0`、`ready:false`。

真实 Oracle 的日期/时区、查询并发、驱动行为和跨机器/跨实例一致性仍须集中验收；同时间戳行的顺序遵循现有 Nuxt 查询，未保证稳定。此增量没有验证其他认证或业务接口的完整性，也没有启动 Docker、真实服务或数据库。
