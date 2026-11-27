# Skill 启用配置维护

Nuxt、Go 和 Rust 的维护命令修改同一份 Oracle Skill 启用列表。执行前通过显式迁移工具检查或创建 `ai-skills` 表。迁移后列表处于未初始化状态。

在 Nuxt 源码目录安装锁文件对应的开发依赖。连接模式需要指定当前机器或容器内可读取的配置文件，进程环境变量优先于文件。凭据由运行环境注入。

以下命令可在 PowerShell 7 或 Linux shell 中运行。

```text
node scripts/ai-skill-config-maintenance.mjs --plan
node scripts/ai-skill-config-maintenance.mjs --plan --enabled-json '["writing-draft"]'
node scripts/ai-skill-config-maintenance.mjs --status --dotenv /path/to/config.env
node scripts/ai-skill-config-maintenance.mjs --publish --expected 0 --enabled-json '["writing-draft"]' --dotenv /path/to/config.env
```

只有预编译后端的部署机可使用[独立公开知识索引工具包](deployment.md#独立公开知识索引)中的同一命令。包内先运行 `node --env-file=.env.maintenance.example scripts/ai-skill-config-maintenance.mjs --plan`。连接 Oracle 时复制模板为私有 `.env.maintenance`，分别通过 Node 的 `--env-file` 和维护命令的 `--dotenv` 传入该路径。使用允许修改 Skill 配置的业务 schema 账号。

Go 和 Rust 可直接在原生后端所在机器维护配置。连接模式从进程环境读取 `ORACLE_HOST`、`ORACLE_PORT`（默认 1521）、`ORACLE_SERVICE_NAME`、`ORACLE_USER` 和 `ORACLE_PASSWORD`。

```text
go run ./cmd/server skills --plan --enabled-json '["writing-draft"]'
go run ./cmd/server skills --status
go run ./cmd/server skills --publish --expected 0 --enabled-json '["writing-draft"]'

cargo run --bin nekotribe-backend -- skills --plan --enabled-json '["writing-draft"]'
cargo run --bin nekotribe-backend -- skills --status
cargo run --bin nekotribe-backend -- skills --publish --expected 0 --enabled-json '["writing-draft"]'
```

已构建的 Go 和 Rust 镜像分别提供 `nekotribe-go skills` 和 `nekotribe-backend skills`。使用已经注入 Oracle 环境变量的容器运行相同参数。命令使用专用数据库连接，原生 HTTP 服务、Redis 与模型服务在维护过程中无需启动。

由新版 `package-native.mjs --build` 生成的原生发布包可复用启动器读取 `.env.go` 或 `.env.rust`。在包目录运行 `node start-native.mjs skills --plan` 或 `node start-native.mjs skills --status`。发布也沿用上面的 `--publish` 参数。指定其他环境文件时，将 `--env-file PATH` 放在 `skills` 之前。本地源码可使用 `node scripts/start-native.mjs go --env-file .env.go skills --status`，Rust 同理。此入口不校验 HTTP 端口、签名密钥或 Redis 配置。旧包仍可使用本身支持的直接调用方式或独立工具包。

`--plan` 默认离线。`--status` 只读显示当前代数和启用列表，空表显示 `initialized:false`。首次发布指定代数 0。后续先查询当前代数，再把该值传给 `--expected`。版本过期或并发首次发布返回 `SKILL_CONFIG_CONFLICT`。使用 `--enabled-json '[]'` 可将全部技能停用。列表须由互不重复的受控 ID 组成，写入后代数递增。

如果返回 `SKILL_CONFIG_COMMIT_UNCERTAIN` 或连接关闭失败，先重新执行 `--status` 检查实际状态，再决定是否操作；不要直接重试。Nuxt Dockerfile 构建时会打包该工具，镜像内连接操作同样需要显式提供配置文件和容器可达的数据库地址。实际镜像与 Oracle 测试留待最终验收。

三套后端当前受控 Skill 目录（`server/services/ai/skill-selection.ts`）共包含 4 项技能，各 AI 生成与创建接口（`server/services/ai/conversation-store.ts` 等）分别要求对应技能已发布并启用：`knowledge-answer`（知识问答）、`writing-draft`（AI 写作）、`group-brief`（群运营草稿）与 `moderation-advice`（审核建议）。未初始化、禁用或配置不可读取时会拒绝生成；启动程序不会自动迁移或创建启用配置。该守卫的真实 Oracle 和跨实例行为仍须在目标环境验收。
