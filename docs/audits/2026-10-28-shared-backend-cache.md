# 2026-10-28 共享后端缓存保护

Rust 和 Go 的原生资料更新直接写共享 Oracle，尚不执行 Nuxt Redis tag 失效；Nuxt 的响应缓存与查询缓存均可能返回这些写入之前的数据。新增进程启动时读取的 `NEKO_CACHE_MODE`，默认及未知值均为共享安全模式，两层结果缓存不读不写；Redis 本身及实时消息等其他用途不受影响。应用保留显式的 `single-backend` 选项，仅适用于全部写入经过 Nuxt 失效路径的部署。新进程生成独立缓存标识，不复用以前的缓存条目，旧条目由既有 TTL 过期。

`tests/shared-backend-cache.test.mjs` 使用隔离 Redis 和数据库替身核对默认与未知配置绕过、外部写入后重新查询、单后端缓存命中、重启标识和初始化后配置固定。Nuxt 全量 504 通过、2 跳过；实际服务、Oracle、Redis、跨机器、多实例与负载未运行。三份 Compose 静态 YAML 确认传递配置，不启动 Docker。公共规范和待运行跨后端场景分别为 `specifications/requirements/cache-shared-backends.md` 和 `specifications/scenarios/cache-shared-backends.json`。

代价是共享模式增加 Oracle 负载；隔离测试不证明所有业务逻辑已经同步，不覆盖其他服务的缓存或在途事务快照。完整统一失效仍需覆盖提交/故障恢复和每个业务变更，实施并实际验收之前不能认为跨后端缓存机制完成。单后端模式启用时不能同时允许 Rust/Go 或其他服务写入，模式变化须重启所有 Nuxt 实例。
