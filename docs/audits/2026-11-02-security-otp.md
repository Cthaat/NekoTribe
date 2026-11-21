# 安全页OTP检查点

本轮接续C盘复查后的开发，保持静态/隔离测试范围，不启动Docker或真实依赖、不迁移日常数据。原有全部未提交工作保留，未提交/推送代码。

## 已实现

- Nuxt SecurityPageEmail发码使用表单的新邮箱，修复了向旧邮箱发码、提交时后端却校验new_email的真实不一致。密码安全表单仍向当前账号邮箱发码。
- 两个Nuxt表单均记录OTP账号、请求代次和认证版本。同步watch邮箱变化使标识/代码/在途请求失效，改回原邮箱不会恢复；发码/提交入口防重，发码失败释放重试。请求回包、提交与定时器直接核对认证版本；AuthRequestQueue的版本不是Vue响应式值，不能只依赖watch。卸载清理冷却定时器，旧结果不发新提示、不退出/导航。
- Flutter SecurityScreen监听trim后的邮箱变化，清除标识/代码；发码及改邮箱捕获AuthRepository实例、会话版本、账号与代次。旧发码完成不能替换新标识或解除新请求的_busy。会话变化/销毁后不发布旧结果；仍通过当前清理完成凭据退出。共享_busy的2FA入口同步防止重复回调，未改2FA服务端规则。
- 成功的当前操作保留原行为；修改失败不额外退出，不自动重放。提交调用在await前构造捕获的邮箱、verificationId、代码、密码等payload。

## 验证证据

先运行实际SFC回调回归，原代码13项失败，明确暴露旧邮箱收件人、重复发送、ABA/会话/卸载保护缺失。Flutter最初新增6项失败、原有4项通过。修复后追加成功/错误与资源检查，最终：

- Node 234项通过、0失败/取消/跳过：security-otp、public-account-flows、web-auth-response、web-api-identity、web-api-session-integration、web-global-auth-recovery、web-use-api-fetch、api-accept-wiring、web-auth-state、web-auth-logout-callers、auth-login-client、web-auth-coordination、contract-payloads。
- Flutter相关4文件35项通过：security_screen（13项）、auth_screens、session_clear_state、realtime_session_ownership。SDK缓存写权限运行，无真实API或邮件。
- Nuxt typecheck exit 0；Flutter analyze无问题；Nuxt/Flutter本轮已修改跟踪文件diff --check通过（Windows CRLF提示不影响结果）。
- contracts workspace check：171 operations、schemaGaps=0。parity workspace check：155 features、60 scenarios、131 sourceAudits、128 sharedFiles，required=11/unreviewed=144，accepted=0、ready=false。

Node使用Vue实际ref/watch与实际SFC函数代码，替换网络/导航/计时器；不是浏览器完整挂载或VeeValidate DOM验收。Flutter使用真实Widget/ProviderScope和隔离仓储；不证明真实安全存储、邮件、Oracle或WebSocket。

## 共享规范与未完成工作

`auth-public-client-lifecycle.md`第7条记录安全页规则并同步Rust/Go/Flutter；其依赖功能的OTP创建/验证/注册revision均6、密码重置revision7。登录14/刷新9/退出7不变。新增`auth-email-change.md`并同步三份，改邮箱功能revision2，登记两个客户端required/in-progress。

**下一步是三后端原生改邮箱及原子OTP消费**：Rust和Go源码检索目前只有OTP用途支持，没有原生邮箱修改服务；Nuxt v2ChangeEmail在调用v2VerifyOtpCode后独立更新，尚未在同一事务一次消费OTP。共同需求明确new_email绑定、鉴权、错误与唯一性、OTP条件消费/邮箱更新原子性、安全响应和未知提交结果；下一步补共同场景并测试事务失败/重放/并发、实际HTTP路由后实施。不得把本轮UI修复误当后端已同步。

仍需：统一输入规则、邮箱修改完整响应解码、安全页2FA/删除账号生命周期、AUTH-901/905及并发撤销、浏览器Cookie/cache/SSR与真实存储/邮件/Oracle、六种客户端组合与多机器部署、其他144项客户端范围、全部业务与完整Skills/Agent/群运营/审核、旧模块退役。C3集中验收未执行；完整目标没有缩小。
