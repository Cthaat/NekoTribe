# 2026-10-28 媒体结构只读检查与帖子详情基线

帖子详情当前 Nuxt 读取可见性、作者、媒体、标签与提及后才提交浏览量；共同要求见 `specifications/requirements/post-detail.md`。`scenarios/post-detail.json` 是未来验收清单，Rust/Go 帖子详情路由尚未实现，不把准备工作称作完整帖子功能。

Nuxt 现有媒体结构检查与迁移定义生成 `media-schema-catalog.json`，包含 `N_MEDIA_ASSETS.DESCRIPTION VARCHAR2(1000)`、owner、迁移账本及所有迁移校验值。Go 复用扩展的只读通用检查器，Rust 复用扩展的快照采集与校验器，两端暴露后续服务可调用的媒体检查，检查时使用一个 Oracle 会话，不执行 DDL、不缓存成功状态。相关 14 个合成场景覆盖 owner、列缺失/类型/长度/null/default、账本缺失/结构/校验和漂移；Nuxt、Rust、Go 分别通过隔离测试。Rust 核对采集器仅查询相关结构；Go 验证重复读取和错误脱敏。

本轮 Nuxt 全套 522 通过、2 跳过；Go 全套 test/vet 通过；Rust 媒体和既有双因素检查专项通过。未启动 Docker、应用、Oracle、Redis 或模型；真实 Oracle 驱动返回值、迁移账本、实际 schema、帖子权限函数和跨后端 UI 均待最终验收。
