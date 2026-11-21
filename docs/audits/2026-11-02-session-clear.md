# 重置/退出的清理完成凭据与资源所有权

2026-11-02，按 [Flutter计划](../../../flutter/docs/2026-11-02-session-clear-plan.md) 实现；接续公开账号流程，不改变HTTP业务协议。

Flutter AuthRepository重置成功后只清理发起时的原版本，失败保留凭据，旧成功不能退出新登录。`requestPasswordReset`改为返回`SessionClearReceipt`；`logout`返回当前receipt或null。清理完成及全局回调后再次核对版本，页面只能用当前receipt导航。既有调用方与测试替身已适配。清理存储异常传播，仍属本次清理版本时尝试全局退出收尾，不将存储异常伪装成成功。

Provider为重置、主动退出、强制401共用版本受控的全局收尾：核对原TokenStore实例、版本及Provider存活，断开前后检查，再清零未读与标记退出。页面移除重复的无条件清理。初始化hydrate的旧读取不能覆盖后来的显式登录/退出或dispose；未读请求也有版本/会话守卫，不能在清零或换身份后恢复旧计数。

RealtimeService断开先分离旧subscription/channel，再关闭捕获资源；新连接不等待旧取消才能取得归属。open读取、消息、发送、ping、重连按代次/TokenStore版本检查。退出后的旧open不能复活，旧连接不能给新身份发送/接收。默认channel工厂仍是原WebSocketChannel.connect，注入点仅供隔离验证，无新依赖。isConnected仍不代表真实握手/业务授权已验收。

Nuxt两安全表单增加重复提交守卫，密码/邮箱修改失败不再从finally启动退出，成功仍沿用原版本退出/延迟跳转。Flutter邮箱/删除成功结果也先检查原版本，不让旧结果提示/清理新会话。安全页OTP生命周期尚未因此完成。

## 验证

首轮仓储/真实Provider测试18通过5失败（原凭据未清理、迟到重置与hydrate等）；隔离实时2项均失败；迟到未读单项复现0被覆盖为9；Nuxt2项复现失败仍退出。修复后通过，并补清理存储失败、清理期间新登录、过期页面receipt及旧消息/发送等边界。测试替身类型问题先修正后才记录业务失败。

- Node12文件211项通过、Nuxt typecheck exit0。
- Flutter12文件主回归229项通过，包含仓储、真实Provider、Widget、API、通知、频道/会话；后加实时定向3项通过，其中2项与主回归重叠，合计230个不同用例，不将两次计数相加。Flutter analyze最终无问题；仅用dart fix修正13处新语句块风格，Dart format及相关tracked文件whitespace检查通过。
- contracts/parity workspace check exit0：155 features、171 operations、60 scenarios、127 sharedFiles、131 sourceAudits，required=10/unreviewed=145，accepted=0/ready=false。OTP创建/校验/注册revision5、重置revision6（共同依赖更新）；三后端/双客户端targetRevision与需求SHA同步。登录14/刷新9/退出7不变，既有语义的实现修复更新了客户端源码/测试绑定。

日志在 `.codex-logs/session-clear-{red,unread-red,nuxt-red,green,node-green,flutter-green}.log`、`realtime-session-{red,green}.log`。真实provider被测，网络/安全存储/Socket均隔离；不是实际设备存储、远端断开确认或真实Nuxt/浏览器验收。外层容忍断开异常，receipt只证明本地流程与版本，不证明服务端或网络关闭。存储多实例/未知提交、Provider/端点切换仍须实际验收。

下一步首先修复已核实的改邮箱发码目标错误：Nuxt `SecurityPageEmail.vue` 将OTP发给当前用户旧邮箱，而实际 `server/services/v2/users.ts` 的v2ChangeEmail用payload.new_email校验OTP（447–452行）；Flutter安全页发送新邮箱，与服务端一致。不要以Nuxt页面现状反向修改服务端契约。然后补安全页OTP的账号/身份版本、重复发码、失败恢复、定时器/销毁和旧响应；继续输入规则、AUTH-901/905、并发登录/重置/实时撤销，再推进其他145项客户端、完整业务/Agent路线。

没有Docker、真实Oracle/Redis/SMTP/模型、日常迁移、Rust/Go重编译或大型target重建、提交/推送。C3缓存/组件/Cookie/SSR、六组合和多机器仍待集中验收。整体未完成，旧交接快照/zip不变。
