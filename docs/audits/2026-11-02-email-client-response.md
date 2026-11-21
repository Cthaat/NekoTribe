# 改邮箱响应与凭据401客户端检查点

本轮接续[三后端原生邮箱实现](2026-11-02-native-email-change.md)，按[计划](../plans/2026-11-02-email-client-response.md)补两客户端响应边界。全部为静态/隔离测试；未启动Docker、真实Oracle/Redis/模型/邮件，未迁移日常库，未提交/推送，保留已有改动。

## 变化与原因

Nuxt原v2ChangeEmail只靠泛型取data，映射后可把缺失/错误字段当成功。现在在实际API边界校验原始成功正文：code数值200、非空message、存在且合法的meta、无冲突error=true、data的邮箱/验证时间；邮箱必须匹配await前捕获的trim后请求。格式错误固定为Invalid email change response。允许合法未知附加字段，不按客户端时钟拒绝较早日期。

将auth-response原有日历/时区/微秒算法原样提取到无业务依赖的strict-timestamp工具；认证调用仍映射到原固定错误。没有改日期算法或令牌存储策略。服务层表单与底层API分别在await前构造/复制payload，迟到响应不改用当前表单值。

Flutter增加可选validateSuccessEnvelope钩子，在Dio会话归属检查之后、宽松通用响应解析之前验证该接口的完整正文；其他接口解析规则不因此全量变化。UsersApi返回强类型V2EmailChangeData，UsersRepository保留Future<void>兼容页面，且只在解码完成后返回。时间校验复用既有parseSessionExpiry，错误固定化；无新会话写入。现有测试recorder补齐真实邮箱响应与meta，避免用空data假成功。

**同时修复实际网络行为缺口**：验证码错误是401，原通用恢复会刷新、重放改邮箱，第二次401甚至清掉仍有效会话。两端现在针对该凭据修改接口不自动刷新/重放/清理；仍发送鉴权并保留会话归属检查。Flutter响应与Dio错误分支都覆盖，绝对URL与查询地址按路径识别。过期鉴权错误交给页面/用户显式处理，此接口也不自动重放来试探结果；普通资源保留既有有界401恢复。

## 验证与范围

- 共同AUTH-EMAIL-CLIENT-RESPONSE正文向量44项，同步Rust/Go/Flutter，由Nuxt实际service→API→v2Request和Flutter实际UsersApi→ApiClient共同读取。包含根类型、code/message/meta/data缺失与类型、邮箱绑定、无效日历/时区、year-zero/闰年及未知附加字段。不能据有限向量声称所有Unicode输入已一致。
- 修复前Node相关73项中42失败/31通过、0取消；Flutter相关78项中42失败/36通过。后续补Dio错误分支、旧会话在新钩子前取消及DTO字段断言。
- Node相关15文件323项通过，0失败/取消/跳过。包含原生H3认证/邮箱兼容性、两端共享响应在Nuxt的解码、公共/安全页、网络归属/恢复及契约回归。
- Flutter相关10文件268项通过；analyze最终无问题。分析曾报新测试一个多行if缺括号，最小补括号后分析exit0；没有依赖升级或业务变化。Nuxt typecheck exit0。
- 最终契约针对性18项通过（包含在323项中的重叠测试，不相加）：未知附加字段合法、已知meta.has_next类型和正文要求与客户端一致。OpenAPI revision=2026-11-02-email-client-response，SHA-256 a1e904384ab39a41858b199d2d163b438ac3c4ddd0baceb1526c1ba77370f36a。contracts工作区check：171 operations、4476 schemasChecked、schemaGaps=0。
- parity工作区check：155 features、62 scenarios、131 sourceAudits、130 sharedFiles，required=11/unreviewed=144，accepted=0、ready=false；本轮跟踪文件diff --check通过。

Node具体命令/完整结果见`.codex-logs/email-client-node-green.log`；Flutter见`email-client-flutter-green.log`。两端使用隔离传输/仓储，不是真实Cookie、浏览器、设备存储或三后端网络验收。Rust/Go本轮只更新共享需求、场景及契约副本，未修改应用源码，因此未重复构建。

## 版本与接续

改邮箱revision3、刷新revision10及各后端/客户端targetRevision同步；登录14、退出7、OTP创建/验证/注册6、密码重置7不变。刷新要求明确凭据修改401例外。没有提高接受状态或声称整体完成。

**下一步核对并统一账号输入规则**，尤其注册/重置/安全页的密码长度、trim后校验、Unicode trim与邮箱格式；以现有三后端和旧账号兼容性为依据，不擅自引入新密码策略。再补安全页2FA/删除账号生命周期、AUTH-901/905与并发撤销。继续其余144项客户端范围、全部业务、知识索引和完整Skills/Agent/群运营/审核、旧模块退役，最后集中做Oracle/SMTP、Cookie/cache/SSR/存储、六组合与Windows/Linux多机器部署验收。完整目标不变。
