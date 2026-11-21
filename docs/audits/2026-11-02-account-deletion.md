# 原生注销与安全页检查点

`DELETE /api/v2/users/me`已补为Nuxt/Rust/Go三套独立后端代码，Rust原代理与Go缺失入口均由原生路由替代。沿用现有软注销业务，并将旧Nuxt四条自动提交改为单连接事务：帖子/评论软删、撤销已有session、账号匿名化禁用一起提交。最终用户UPDATE绑定旧密码哈希及active状态，零行回滚409；密码随机失效值使用密码学随机源及bcrypt成本10。

注销不执行物理删除或完整个人数据擦除；上传文件、私信、审计等保留。提交/连接报错可能发生于实际提交后，不能承诺失败没有副作用。提交后presence仅最佳努力，不把通知失败当注销失败。具体输入、错误顺序、字段、事务及未解决竞态见 [共同需求](../../specifications/requirements/auth-account-deletion.md)。

两客户端新增注销重复提交/旧会话/卸载保护，当前失败不清理有效会话；成功要求deleted=true和正安全整数user_id。Flutter按原版本条件清理TokenStore并完成全局收尾，receipt有效才导航，不追加网络退出；Nuxt核对组件原会话再清理。2FA初始状态/setup/confirm/disable与密钥复制增加归属/重复提交保护，旧回包不发布密钥/恢复码；Nuxt卸载清空相关引用。凭据401不自动刷新/重放或清理有效会话，普通GET/PATCH资料的原策略保留。

## 验证

- 共同22项HTTP场景由三个实际装配路由消费，覆盖确认、密码、未登录/已撤销会话、四步失败、状态变化、提交报错与模拟提交后报错。修改前Nuxt无法通过事务约束、Go404、Rust405；对应日志为 `.codex-logs/deletion-*-red.log`。
- Go另有真实database/sql事务适配器的隔离driver测试，检查逐步失败/0行/多行回滚及参数绑定；Rust对OracleTx下方生产事务流程验证执行失败/提交失败/0行回滚，实际Oracle驱动与锁未运行。
- Nuxt相关18文件544项全部通过，失败/取消/跳过0；typecheck通过。安全页及HTTP凭据恢复修改前相关42项中12项失败，修复后42项通过，这些已包含在544内。最终OpenAPI payload18项复查通过，与主回归重叠不另加总。
- Flutter相关11文件467项通过，analyze无问题。修改前安全页/凭据401相关83项中10失败，修复后的迟到setup/注销、不发网络退出、原版本持久化清理等回归通过；范围不等于所有平台/存储验收。
- Go离线全量test/vet退出0；Rust6个相关集成测试文件13个声明测试和1个事务单测通过（共14，不把其内部22项场景重复计数）。Rust另95个lib单测未在此命令执行，未跑完整Rust回归。
- contracts/parity检查通过：171操作、schemaGaps=0、4485 schemas；155 features、65 scenarios、137 sharedFiles、131 sourceAudits；客户端required=15/unreviewed=140。accepted=0、ready=false，整体仍未验收。

注销feature revision2，要求reviewed但实现/客户端in-progress。2FA管理三feature客户端范围已明确，两端均登记in-progress/targetRevision2，后端需求仍unreviewed，Rust/Go管理接口未补齐，不以客户端守卫冒充原生实现。登录15、OTP创建/校验/注册8、重置9、改邮箱4、刷新10、退出7保持。OpenAPI revision `2026-11-02-account-deletion`，SHA-256 `3f202c3656a61342d1d170285af6b681f7456512db26bacb9ba71f679137a9e8`。

## 下一步和剩余风险

优先完成Rust/Go的2FA setup/confirm/disable与共同服务端场景，补完整凭据响应envelope/字段解码和跨会话已显示秘密失效。注销Set-Cookie与认证队列/并发登录仍须处理并做真实浏览器检查；现有JS归属守卫不能证明浏览器Cookie安全。AUTH-905包括在途登录/挑战于注销提交后才创建session，以及现有WebSocket即时撤销；本事务不宣称解决这些竞态。

之后继续资料编辑输入、限流/尝试次数、140项待审客户端范围、全部业务同步、知识索引/上下文/Skills/Agent/群运营/审核、旧情感分析退役与多机部署。未执行真实注销、Docker/Oracle/Redis/模型/SMTP、日常迁移、提交/推送或切分支。C盘当前仍约99.5 GiB可用，受控Cargo构建禁用增量/dev/test debug，本次无清理操作。
