# Nuxt 认证响应校验与两客户端共同样例

2026-11-02，接续 [统一恢复](2026-11-02-web-auth-recovery-unification.md)，按 [实施计划](../plans/2026-11-02-web-auth-response.md) 完成静态实现。

## 变化

新纯模块 `app/services/auth-response.ts` 从unknown检查对象、布尔挑战开关、非空字符串、安全正整数身份、完整token字段、带时区的真实日历/时间/偏移及到期顺序。登录必须有布尔开关；挑战完成可省略，存在则只能false。时间允许1至9位小数，按微秒精度截断比较，与Flutter DateTime一致，避免JS Date默认规范化非法日期或仅按毫秒比较。保留原始合法文本，不依赖当前客户端时间拒绝过去日期。

实际auth service的登录、挑战完成、刷新接入校验；成功资料沿用users mapper，映射异常转换为固定安全错误，不携带响应体/凭据。**没有把所有用户资料字段、缺省兼容或HTTP envelope解析统一完成**；共同样例的合法用户使用完整self profile。会话VM仍只有sessionId和到期信息，没有新增可读token偏好。Pinia刷新如原本有sessionId则要求不变；缺字段/换sessionId不会发布或重放，只按原版本失败清理。没有本地sessionId时不伪造旧值作比较。

`specifications/scenarios/auth-client-response-vectors.json` 登记AUTH-CLIENT-RESPONSES，共46项。各case深拷贝base后按path逐项变更或remove，只有合成身份/凭据；Nuxt实际service和Flutter实际parser/TokenPair消费同文件。拷贝到Rust/Go/Flutter并登记SHA-256。Rust/Go只同步客户端契约，不能据此宣称后端运行行为完成。

## 验证

- 新Nuxt49项（46共同样例+3组畸形根/类型）首次8通过、41失败；另2项实际store/service/API组合回归复现非法刷新仍发布/重试，修复后通过。最初测试打包边界漏隔离其他用户API，先修正测试边界才记录上述产品失败，不将打包问题当缺陷。
- 最终Nuxt11文件150项通过、0失败/跳过，含实际Pinia/Vue/store/service/v2 API/transport/队列串联。`node node_modules/nuxt/bin/nuxt.mjs typecheck` exit0。
- Flutter新共同样例与auth_result/api_client/auth_screens共4文件101项通过，analyze --no-pub无问题；新Dart文件已format。Flutter运行源码未改，确实消费46项共同向量，不只是比较文件哈希。SDK单元/Widget测试不是浏览器或Windows桌面版验收。
- contracts/parity workspace check exit0；155 features、171 operations、59 scenarios、125 sharedFiles、131 sourceAudits；required=6/unreviewed=149、accepted=0/ready=false。登录revision14、刷新revision9、退出revision7；三后端/两客户端targetRevision及共同需求SHA同步，相关已跟踪文件whitespace检查通过。

日志：`.codex-logs/web-auth-response-red.log`、`web-auth-response-state-red.log`、`web-auth-response-green.log`、`flutter-auth-response-green.log`、`web-auth-response-parity-2026-11-02.json`。

## SDK权限排障

初次受限Flutter调用未进入Dart，无输出但cmd CPU持续增长。实际 `C:\flutter\bin\internal\shared.bat` 在写 `bin\cache\flutter.bat.lock` 失败时会静默循环；打开该路径的读写句柄实测Access denied。核对本次cmd进程ID/启动时间后仅终止该进程，原session30754最终exit1，再用允许既有SDK缓存写入的测试执行方式完成验证。没有删除锁、并行重启同一测试、升级SDK或安装依赖。进程ID属于历史证据，不可盲目重放终止命令。

## 接续

认证核心静态接线已有证据，接下来恢复完整业务对齐：先从OTP、注册、找回密码等账号模块核对当前三后端/双客户端源码、需求和测试，审查其clientScope，发现实际缺口就实现，不能只补登记。再推进用户资料、帖子/评论、群组/实时/管理与完整AI知识/上下文/Skills/Agent、群运营/审核及旧情感模块退役。

C3真实useFetch组件/缓存跨账号、HttpOnly Cookie、超时/取消、多页签、实际SSR转发、六组合和Windows/Linux多机器部署属于后续集中验收。当前没有运行Docker、真实Oracle/Redis/模型或日常迁移，没有重编译Rust/Go、提交/推送，也没有重建大型Rust target。完整最终目标继续保持未完成。
