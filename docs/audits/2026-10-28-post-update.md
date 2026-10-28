# 三端帖子部分更新与事务检查点

Nuxt、Rust native 和 Go 已接入同一套 PATCH/PUT 帖子部分更新规则。省略字段保留原值，明确传入空关系清空，空对象不改变 updated_at；客户端不能修改作者、帖子类型或引用。PUT 保留为 PATCH 的兼容别名，两种入口不分叉实现。Nuxt Web 与 Flutter 当前编辑客户端均发送 PATCH；本轮核对源码，未声称实际客户端联调通过。

实现提交为 Rust `91b22f3`、Go `d27ee4e`，Flutter 契约提交为 `bfdc2ce`。

Nuxt 原先逐操作提交，本轮改为同一连接 `SELECT ... FOR UPDATE`，检查作者/删除状态及有效内容后，原子更新标量、媒体、标签和提及。所有 DML 使用 autoCommit=false，附件附加逐项验证所有者和状态，任一步失败回滚此前修改。Rust/Go 使用相同锁定与提交边界，复用各自创建流程的数值/标签转换和关系 SQL；Rust 事务执行接口接受借用 SQL 字符串，动态更新列只来自固定白名单，不包含用户提供的标识符。

成功仅提交一次，空操作也显式结束事务释放锁。提交失败可能已经持久化，回滚错误返回安全内部错误，不能推断一定撤回或自动重试。最终帖子读取及映射位于提交之后，不增加浏览量，不发送创建/提及通知。最终映射或连接关闭错误不回滚已提交修改。正文上限、非法 JSON 和 Content-Type 的既有框架差异仍按公共请求说明记录。

公共要求位于 `specifications/requirements/post-update.md`，53 条共同请求向量位于 `specifications/scenarios/post-update-request.json`，Rust/Go/Flutter 均持有固定副本。Nuxt 通过真实路由和解析器的测试观察点核对私有 payload；Rust/Go 复用各自已实现的 JSON 数字转换器，分别消费同一向量。请求向量与事务替身、HTTP/JWT 测试分别作为开发证据，未作为真实 Oracle 证明。

## 验证

- Nuxt：新增 61 项请求/事务/错误检查通过，涵盖所有写入阶段回滚、媒体失效、无操作、清空、并发零行、提交未知结果及提交后错误。原有 10 项客户端/部分更新检查保留，替身补齐 commit/rollback 和作者绑定。全量回归 736 项通过、2 项跳过；`typecheck --dotenv .env.example` 通过。
- Rust：请求解析、编辑事务和两个 HTTP 入口先失败再通过；复用事务接口后的创建仓储 13 项回归通过。编辑事务替身检查已保存状态不出现部分修改；全量离线回归 234 项通过、2 项真实 Oracle/Redis 连通测试忽略。
- Go：共享解析、HTTP 错误与事务检查先失败再通过；事务驱动替身要求查询及写入都在同一事务中，检查失败后保存状态不改变；全量 `go test ./...` 与 `go vet ./...` 通过。
- 66 项契约/需求检查器回归通过。OpenAPI revision 为 `2026-10-28-post-update`，四份副本一致。PATCH/PUT 两个任务归为 `POST-UPDATE`，`supersedes` 保留原任务 ID，两个 HTTP 接口和 operationId 均保留。共同清单为 154 项、162 个操作、49 份场景文件、94 份公共文件，`accepted:0`、`ready:false`。

日志位于管理目录 `.codex-logs/2026-10-28-post-update-nuxt-full.log`、`post-update-nuxt-types.log`、`post-update-rust-full.log`、`post-update-contract-tests.log`（后三者同样带 `2026-10-28-` 前缀）。Go 检查结果保留在本轮工具执行记录。

本轮未启动 Docker，未访问日常数据库。真实 Oracle 行锁/死锁/超时、CLOB 摘要与绑定、触发器、跨实现并发和缓存失效、两客户端及部署仍需集中验收。当前仍以既有前 4000 字符摘要参与省略内容时的空内容校验，不用摘要覆盖完整 CLOB。下一组继续补齐媒体上传和文件访问权限。
