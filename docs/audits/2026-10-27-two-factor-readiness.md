# 2026-10-27 双因素结构检查开发记录

Rust native 和 Go 独立登录及挑战流程新增只读数据库结构检查：在一次检查内使用同一连接检查 `USER` 与 `CURRENT_SCHEMA`、可选迁移账本、所有已记录迁移 checksum，以及双因素所需四张表、两条序列和三个索引。表列类型/精度/默认值/可空性、已启用且验证的主键/外键/唯一及 CHECK 约束、索引列顺序和序列规则均按 Nuxt 共同行为检查。不合格或查询失败安全返回 503，不生成会话或消费挑战。

Nuxt 允许迁移账本不存在；若存在，即便记录属于其他功能，未知步骤或 checksum 不符仍须拒绝。检查在各触发点重新运行，不将成功结果长期缓存。Nuxt 在挑战创建前和挑战完成后读取 secret 前会再次检查；原生后端也覆盖了这些顺序检查。原生检查所用连接与其后业务使用的连接并不保证相同，检查与后续操作之间的部署变化仍可能发生。

共同 catalog `specifications/requirements/two-factor-schema-catalog.json` 从 Nuxt 的 schema 定义提取9个步骤、账本结构及全部31项迁移 checksum；`scenarios/two-factor-readiness.json` 用30组公开合成字典状态覆盖正向、无账本、不同 schema、列/约束/索引/序列异常、跨功能 checksum 漂移等。Nuxt、Rust、Go 各自读取本工程副本并执行共同样例。检查源码变更后，可运行 `yarn schema-catalog:check`；如确需更新，在评审后运行 `node scripts/two-factor-schema-catalog.mjs --write` 并同步其他后端副本、场景和对应功能版本。测试与 parity gate 会检查源文件哈希、目录引用与副本，不能只重钉 Nuxt 基线来掩盖目录过期。

`AUTH-LOGIN` 需求版本升级，目录作为共享依赖登记。未来若某端标记 accepted，其验收凭据还必须包含依赖路径及内容 checksum；更换目录并重钉共享副本后，旧凭据不能继续通过。现有登录仍在 `in-progress`，没有把结构隔离测试记作完整登录验收。

Nuxt 全套 418 通过、2 跳过，typecheck 通过；Go 30 个共同场景及全套 test/vet、Windows/Linux amd64 CGO0 构建通过。Rust 在 WSL 离线全套 95 通过、2 个真实 Oracle/Redis 连接测试忽略，更新后的30个共同场景专项通过且离线构建通过；这不代表原生 Windows 链接验证。OpenAPI 与共享工作区检查保持通过，但整体 `accepted:0`、`ready:false`。检查测试使用合成字典与模拟 driver，尚未连接真实 Oracle：`USER_TAB_COLUMNS.DATA_DEFAULT`、NUMBER 类型、驱动关闭、事务和跨连接时区等仍需实测。对人造 JSON 浮点默认值的字符串化，Rust 与 JavaScript 仍可能不同；生产 Oracle 字典的 LONG 返回类型必须以真实驱动验证。

本轮未启动 Docker、真实应用、数据库或模型，未改动日常业务数据。登录的邮件、实时消息、自定义媒体地址及项目其他业务与 AI 功能仍需完成。
