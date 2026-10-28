# 三端帖子软删除检查点

Nuxt、Rust native 和 Go 已按同一需求接入 `DELETE /api/v2/posts/{id}`。作者可软删除自己的未删除帖子；其他用户为 422，不存在、已删除或并发更新零行为 404。正文和查询参数不能指定作者，不增加浏览量，不物理删除媒体、评论、关系或历史通知，也不新增通知事件。

实现提交：Rust `9df39c4`、Go `38dac0c`，Flutter 契约提交 `13c2b74`。

本轮修正 Nuxt 的两处差异：路径改为与创建/转发一致的 canonical 安全整数；更新同时约束 post_id、author_id、is_deleted，并检查更新行数。Nuxt 入口补 private/no-store 与既有安全错误包装，驱动异常清洗为 500。Rust/Go 仓储复用各自现有连接执行器和提交语义，不通过 Nuxt fallback 完成删除。提交或连接释放错误可能发生在实际软删除之后，不能推断一定回滚。

公共需求为 `specifications/requirements/post-delete.md`，17 条输入位于 `specifications/scenarios/post-delete.json`，均复制到 Rust/Go/Flutter。场景覆盖不存在、已删除、非作者、并发零行、安全错误、路径格式和单次解码。Nuxt 执行真实已检入路由及服务，预置认证上下文并使用隔离 Oracle 适配器；Rust/Go 使用实际 HTTP/JWT 路由及替身仓储，另有原生仓储 SQL/绑定检查。它们不证明真实数据库或跨后端业务可用。

验证记录：

- Nuxt：新增 17 项先失败再通过；全量 Node 回归 675 项通过、2 项跳过，日志为管理目录 `.codex-logs/2026-10-28-post-delete-nuxt-full.log`；`typecheck --dotenv .env.example` 通过，日志为 `.codex-logs/2026-10-28-post-delete-nuxt-types.log`。
- Rust：缺少路由/仓储时两项定向检查失败；实现后 3 项定向测试通过，包含同一组 17 条向量；全量离线回归 231 项通过、2 项真实 Oracle/Redis 连通测试忽略，日志为 `.codex-logs/2026-10-28-post-delete-rust-full.log`。
- Go：缺少路由/仓储时共享输入及仓储检查失败；实现后全量 `go test ./...` 和 `go vet ./...` 通过，仓储覆盖查询/写入/提交错误和并发零行。
- 公共规范：OpenAPI 补删除接口 422 及 ID 范围，revision 为 `2026-10-28-post-delete`；四份规范同步。契约与登记检查的 66 项回归通过，共同清单为 155 项、162 个操作、48 份场景文件和 92 份公共文件，`accepted:0`、`ready:false`。

本轮不启动 Docker，也不访问日常数据库。真实 Oracle 的行锁、触发器、提交未知结果、跨后端缓存、双客户端和部署验收仍待执行。帖子 PATCH/PUT 仍需独立完成共同规则和事务修订：当前 Nuxt 更新会逐步提交，附件失败可能留下部分正文或关系修改；本删除切片未将它标为完成。
