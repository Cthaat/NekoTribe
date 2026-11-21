# Nuxt API 请求身份与一次重试

目标：继续已有 C2a，普通 API 结果及认证恢复只属于发起请求的 app/会话意图版本。保持现有 Cookie 传输及错误翻译，不引入依赖，不启动 Docker/真实服务。完整三后端、两客户端及 Agent 路线仍独立推进。

选择沿用按 app 索引的 `authQueueFor` 版本；不另设模块全局身份，也不把所有业务请求排成串行队列。每次 apiFetch 捕获 app/版本，首次及重试响应发布前、处理错误前、动态加载 store 后和刷新前后核对。过期结果以安全 AbortError 拒绝，不返回旧响应体，不为新账号刷新/清理。没有 app 时允许普通传输，但不借用以后出现的 app 自动刷新。

401 且不是认证入口/刷新/退出路径时，使用捕获 app 上下文取得 store，复用其同版本刷新任务，成功后只重试一次；移除固定 100ms 等待。强制每次底层 fetch 的 retry=0，避免库或调用方隐藏重试扩大请求数；调用方 AbortSignal 中止后不发起重试。重试仍401才在同版本清理；403/500/网络失败不新增清理/重放。刷新失败由已受版本保护的 store 负责状态处理，不能在普通 transport 再清理较新身份。

实施顺序：

1. `tests/web-api-identity.test.mjs`：打包实际 transport 与队列，隔离网络/路由/store；测试旧成功、旧401/403、刷新/重试期间换身份、当前一次重试及失败策略、取消、app隔离、认证入口和无app边界。先观察失败。
2. `app/composables/useApi.ts`：最小接线，不改公共 API 泛型或各业务端点。用真实 ofetch 加隔离 fetch 验证底层禁用自动重试。
3. 运行新回归、已有认证及 Accept 接线测试、Nuxt typecheck、contracts/parity workspace check。共享需求变更同步三份副本及依赖功能 revisions/targetRevision，不更新业务 accepted 证据。
4. 更新当前接手入口、检查点和源码哈希；原交接快照/zip 不改。审查发现全局401插件与旧useApiFetch存在独立恢复路径，下一步C2c先统一此处，再进入C3真浏览器Cookie/超时/多页签与实际SSR HTTP验证及严格响应解码。

2026-11-02 检查点：本计划的apiFetch接线、21项transport回归、5项实际store/service/API组合回归完成；相关8文件84项测试、typecheck与contracts/parity通过。整体Web有界恢复仍待C2c。见 [审计](../audits/2026-11-02-web-api-identity.md)。

不把 JS 隔离回归当 HttpOnly Cookie 或真实 SSR 证明，不自动重放结果未知的认证操作，不清理日常数据。
