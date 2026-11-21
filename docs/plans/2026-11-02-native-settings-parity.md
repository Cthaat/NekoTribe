# 三后端原生设置一致性实施计划

本计划按writing-plans和test-driven-development流程在当前会话顺序执行，不切分支、不提交已有WIP。最终目标仍为完整等价后端和两个客户端、可切换模型及RAG/上下文/Skills/Agent，不以本局部计划代替全项目验收。

目标：GET/PATCH /api/v2/users/me/settings 共享可执行HTTP错误/隐私场景，设置初始化、修改和快照读取处于同一事务；纠正旧NUMBER小数映射与PATCH privacy文档。

架构：沿用各自现有Oracle适配器和公开错误封装。schema检查只读；父用户行锁之后初始化/修改/读取，成功提交一次。事务内失败回滚；提交失败尝试适配器允许的清理但不承诺结果已撤销。database/sql提交后Tx已结束，ErrTxDone不能误当新的驱动回滚失败。鉴权前设private/no-store，Nuxt GET绕过响应缓存。

1. [x] 在specifications/scenarios/user-settings-native.json登记共同HTTP和NUMBER映射向量，同步三个contracts。Nuxt增加实际H3/auth/route/cache测试，Go扩展SQL驱动和组装路由测试，Rust扩展原生Router及Transaction测试；先记录预期失败。
2. [x] 修改Nuxt server/services/v2/users.ts：PATCH先解析，schema检查一次，锁/merge/update/read同事务，显式autoCommit=false，提交失败亦尝试rollback；缺父用户/设置404。settings.get/patch使用safeAuthEntry固定错误，middleware/auth.ts鉴权前隐私头，api-cache.ts排除设置读取。
3. [x] 修改Go internal/server/user_settings_repository.go和user_settings_route.go：区分sql.ErrNoRows的两个固定404，校验返回user_id，NullFloat64标志严格等于1，保留top原值范围检查；测试真实repository执行路径，不以路由stub代替事务证据。
4. [x] 修改Rust src/users/settings_read.rs、settings_patch.rs及ai/conversation_http.rs：缺用户/设置独立结果；事务错误和提交失败尝试rollback，原始NUMBER先判断后截断，错误也private/no-store；保持其他路由语义。
5. [x] 运行Nuxt新HTTP/旧PATCH/相关鉴权缓存回归和typecheck，Go离线test/vet，Rust离线相关lib及integration。无需修改UI；不宣称真实Oracle、并发、浏览器、跨机器或六组合验收。
6. [x] 更新需求、OpenAPI和parity revision/源码审查哈希及任务；修正privacy仅public/private、model_id trim后至多128个UTF16单元。运行node scripts/contracts.mjs sync/check及parity检查，保留accepted=0/ready=false。
7. [x] 写审计及机器状态，更新docs/handoff/LATEST.md和START-HERE-PROMPT.md的执行顺序；capture-handoff-delta后verify-handoff-latest --check-only，保护初始795份快照和旧zip。

执行入口：Nuxt node --test tests/user-settings-native.test.mjs tests/user-settings-patch.test.mjs；Go使用工作区.tools/go1.27.3/go/bin/go.exe且GOPROXY=off；Rust使用现有WSL离线工具链并关闭增量/debug符号。所有真实依赖和日常数据保持停用，记录每次验证的实际范围。
