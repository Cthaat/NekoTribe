# Nuxt Web C2a：会话版本、状态与退出调用方

日期：2026-11-02。继续已有 C1 网络队列，在静态开发范围内接入 C2a；不是认证、三后端或项目完整验收。

## 变化与依据

- 每个 Nuxt app 的认证协调器持有意图版本。v2 登录、挑战完成和退出在排队前同步递增；刷新不改变身份版本。不同 app 使用独立队列/版本。
- Pinia 为同版本共享刷新任务；旧刷新成功不能发布状态，旧失败不能清理新身份，旧任务结束不能取消新任务的忙碌状态。清理/重置使旧版本失效。Promise 清理放在 `.finally` 回调内，避免初始化中的自引用；首次类型检查报 TS2454，修正后通过。
- 登录页在成功、挑战、失败提示和跳转前检查版本；保留既有单次提交守卫。四个退出入口统一调用 `logoutCurrentSession`：导航、忘记密码、修改密码和修改邮箱。凭据修改等待期间身份改变时不能再启动退出；旧退出不能重置新会话；延迟跳转再次检查身份。
- 当前退出无论网络成功或失败均清理仍属于本次操作的本地状态；结果区分 `ok:true` 与 `ok:false,error:unknown`，拒绝值为 null/undefined/false 也不能当成功。此行为不证明服务端撤销已经完成。
- 默认偏好在初始化、兼容回退和重置处深拷贝。真实 Pinia/Vue 隔离测试曾复现模块默认对象被重用后第二个 store 读到第一个 store 的合成 sessionId；修复后隔离通过。不是实际 SSR HTTP/Cookie 验收。

## 验证及边界

`tests/web-auth-state.test.mjs` 运行实际 Pinia/Vue 与实际 store/队列，隔离 Nuxt Cookie 和网络；`tests/web-auth-logout-callers.test.mjs` 提取四个实际 SFC 回调，隔离网络、store 和路由；登录页测试也提取实际回调。API 协调测试使用真实四个 API 包装和网络替身，验证等待顺序、上下文、输入副本、失败恢复和同步版本失效。测试替身不能证明真实 Cookie、浏览器或数据库行为。

新增的三个假值退出失败和四个调用方错误分支测试修复前 7 项失败，修复后通过。此前状态/页面竞态回归及默认对象隔离的复现过程见公开会话记录；没有为了重新制造失败而覆盖原有未提交代码。

检查：五个相关测试文件共 50 项通过、0 失败；Nuxt typecheck exit 0；contracts workspace check exit 0（171 operations、0 schema gaps）；parity workspace check exit 0（155 features、58 scenarios、124 shared files、131 source audits）。相关已跟踪文件 diff whitespace 检查通过，Windows CRLF 按 `cr-at-eol` 处理。登录 revision 11、刷新 revision 6、退出 revision 4；共同登录需求及 SHA-256 同步 Rust/Go/Flutter，三后端和两客户端 targetRevision 对齐。required=6、unreviewed=149；accepted=0、ready=false。

未运行 Docker、Oracle/Redis/模型、日常数据库迁移、真实浏览器、Flutter 重测、Rust/Go 重编译、提交或推送。Rust/Go/Flutter 本步只同步共同需求，运行源码不变；未重新生成约 95 GiB 的 Rust target。检查 C 盘仍约 100.5 GiB 可用，不再删除文件。

## 接续动作

C2b：审查并修复 `app/composables/useApi.ts` 的原请求身份：旧成功/401不得交付新身份、不得为新身份刷新/清理，刷新后至多一次按原身份重试；避免认证入口/刷新递归与原请求自动重放扩大。为实际 transport 加异步回归，然后继续 C3 浏览器 Cookie、超时/取消、多页签和 SSR HTTP 验证。

Nuxt 响应严格解码、其他客户端范围审查、完整原生业务、AI 知识/上下文/Skills/Agent、群运营/审核和六组合/多机器部署路线均仍需继续。此检查点不缩减原目标，也不将元数据检查视为业务验收。
