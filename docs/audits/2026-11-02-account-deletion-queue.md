# 注销与认证队列检查点

2026-11-02接续“清理后再继续”。先核对历史清理记录与当前空间：10月31日已净回收92.60 GiB；本轮复查仍约99 GiB可用，Rust target约1.11 GiB，未再次删除文件。WSL/Docker虚拟磁盘、pagefile及所有源码/数据保留，见工作区 `docs/audits/2026-11-02-storage-recheck.md` 和 `.codex-logs/storage-2026-11-02/resume-recheck.json`。

## 改变与原因

原注销接口直接调用传输层，虽有JS迟到结果守卫，其成功响应清理Cookie仍可能晚于较新登录。现在提取原有调度到 `app/api/v2/auth-mutation.ts`，继续共用每app的 `AuthRequestQueue`，让注销与登录/2FA登录完成/刷新/退出串行到响应完成。注销捕获提交参数、app和版本，在执行前与完成后核对；身份变更已排队/在途时拒绝新注销，等待中身份变化时取消发送。普通刷新不改变身份，可完成后注销。异常释放队列；不同app/SSR用户彼此隔离。注销自身不预先递增身份版本，保持安全页当前动作可受控完成。

本轮没有改变三后端HTTP路由或响应字段；账号注销需求revision2→3、两客户端/三后端targetRevision同步，仍in-progress。原生后端代码与Flutter业务代码未改。共同生命周期/注销需求同步四目录，OpenAPI哈希保持 `e7e157ca787961cf05e38cb124db7a5ad6abc8e369475337b1439c866ee1892b`。

## 验证

- 新增队列回归先观察6项失败（`.codex-logs/account-queue-red.log`），实现后加入实际传输/Pinia/服务/API集成检查。总计新增10项：成功/业务失败响应与新登录顺序、等待中取消、身份变更在途、参数与app快照、跨app独立、失败释放。单独7文件125项通过，最终18文件556项通过，fail/cancelled/skipped均0（`account-queue-regression.log`、`account-queue-node-final.log`）。测试桩的Cookie罐观察顺序，不是浏览器Cookie验收。
- Nuxt typecheck exit0（`account-queue-typecheck.log`）。期间两个测试夹具遗漏新模块的 `#app` stub、一个测试误把已过期刷新当成功，已按真实传输取消语义修正，最终完整回归通过。
- contracts check与parity check exit0：171 operations、0 schemaGaps、155 features、68 scenarios、142 sharedFiles、131 sourceAudits；required15/unreviewed140，accepted0/readyfalse。检查通过不表示业务全面验收。
- 本轮未重跑Go/Rust/Flutter运行时测试；上一2FA检查点结果保留为历史。没有启动Docker、真实Oracle/Redis/模型/SMTP，没有操作真实账号、提交、切换分支或修改原始交接快照/压缩包。

## 下一步

继续两客户端凭据成功envelope及2FA secret/URI/enabled/recovery_codes严格解码、身份变化时已显示秘密即时失效。AUTH-905在途登录/挑战在注销提交后才新建session、WebSocket撤销、AUTH-901/资料输入、140项客户端范围及完整业务/AI路线仍未完成。真实浏览器HttpOnly/跨标签页/SSR、Oracle并发、六组合和Windows/Linux多方式多机部署仍待集中验收；不要把同app隔离检查扩展为已解决这些边界。
