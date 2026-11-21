# 严格刷新响应与 Nuxt Web 静态审查

2026-11-01。Flutter 自动刷新取消所有旧token/session/expiry补齐；响应正文必须完整、非空、严格字符串且 session 与原会话一致。可读 Cookie 必须与正文相同。非法响应不会保存凭据或重放受保护请求。

将 TokenPair 从 token_store.dart 移至纯数据文件 core/auth/token_pair.dart，原入口重新导出以保持现有引用；登录成功、自动刷新与显式刷新 API 共用校验。日期严格检查有效年月日、时分秒、时区，拒绝 Dart 自动规范化的2月30日等值；支持闰日、偏移时区及最多9位小数秒；refresh到期必须晚于access。不依赖设备当前时钟决定服务端授权，不验证JWT签名。

新增12类HTTP刷新反例：缺session/令牌/到期字段、不同session、空或数值token、无效日期、日历溢出、无时区、到期顺序错误、Cookie冲突。旧实现11类失败、1类已有拒绝；修复后全部拒绝且不重放。新增合法闰日/偏移与越界日期回归。Flutter四文件共94项通过；analyze无问题；contracts/parity检查通过。AUTH-LOGIN revision9、刷新revision4，三后端与两客户端目标版本及共享副本同步。仍accepted=0、ready=false。

## Nuxt Web 已观察的下一步问题

- app/stores/user.ts: refreshAccessToken 在同一个store内有 refreshPromise，能合并在途刷新，但未绑定会话身份。刷新成功直接 setCurrentSession，失败直接 clearAuthState，finally无身份地清空promise标记。
- app/composables/useApi.ts: 401后调用store刷新，固定等待100ms，再用原mergedOptions重试；没有保存原会话版本，也未在返回受保护成功响应前核对身份。
- 浏览器先处理HttpOnly Set-Cookie再将响应交给JS；仅在Pinia忽略旧响应不足以保证Cookie不被旧刷新覆盖。下一步设计每个Nuxt app/SSR请求独立的认证变更协调器，协调登录/2FA/刷新/退出的网络顺序和状态发布，再接入请求身份与有界重试；不能使用跨SSR用户共享的全局promise。

上述是源码事实与设计方向，尚未写Nuxt回归/修复或执行浏览器验收，不声称已证明具体线上竞态。真实浏览器、跨页签/进程、实际安全存储、邮件/Oracle/Redis/三后端六组合与完整业务/AI仍待完成。没有启动Docker、修改数据库或重编译未改的Rust/Go。
