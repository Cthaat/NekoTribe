# 新注册资料与新邮箱检查点

将Nuxt现有Zod/v3邮箱与注册名字最少2位规则落实到三后端和Flutter，新增资料使用JS trim后的值并保留大小写。注册在字段/条款/密码检查后、查OTP与写库前校验email/username/display_name；改邮箱仍先鉴权；register/change_email邮件发码在原参数/SMS501检查后、生成/插入/投递前校验。三个固定安全400消息不附带用户资料或内部异常。

Nuxt找回/安全页补发码前校验；Flutter注册/找回/安全页同步邮箱规则，注册资料无效时不先验证OTP，安全页邮箱监听及提交统一JS trim。后端只收紧新资料：password_reset API/发码、既有OTP验证和登录保留旧账号规则，不迁移数据库或重写已有账号。Nuxt共享纯校验器直接使用已安装Zod，Go/Rust使用等价模式，未新增依赖。更多语义见 [共同需求](../../specifications/requirements/auth-account-input.md)。

## 证据

- 共同55项注册输入，由三个实际装配HTTP注册路由消费；25邮箱/15名字为复用分组，不能相加成95个不同输入。覆盖JS trim、BOM/NEL/零宽、emoji UTF-16长度、大小写、ASCII/Unicode邮箱边界与数字/布尔标量。Nuxt三份实际SFC schema93项与Flutter纯校验35项验证相同字符串政策。
- 修改前Nuxt两个HTTP回归失败，Go/Rust均复现非法新邮箱被注册；Flutter两个页面文件159项中53失败、106通过。日志 `.codex-logs/account-*-red.log` 保留；Go无完整仓储的非法路由返回500也属于应在仓储前400拒绝的失败证据。
- Nuxt相关17文件529项通过，失败/取消/跳过均0（`.codex-logs/account-node-green.log`）。共享helper导入改为实际相对路径后typecheck退出0；最终HTTP/contract复查还包含旧非标准账号的password_reset发码兼容断言，详情见最新验证清单，重叠用例不累计。
- Flutter相关11文件456项通过，analyze无问题（`.codex-logs/account-flutter-green.log`、`account-flutter-analyze.log`）。Flutter SDK单行EditableText会先删除LF：Widget向量单独记录过滤后结果，纯校验器/原始HTTP仍拒绝内嵌换行，未放宽邮箱规则。SDK来源 `packages/flutter/lib/src/widgets/editable_text.dart` 与 `services/text_formatter.dart`。
- Go离线 `go test ./...`、`go vet ./...` 退出0；Rust离线5个集成测试文件共12项通过，含新邮箱非法输入的OTP/鉴权改邮箱路由及旧短密码登录。Rust使用既有WSL工具链，禁用增量和dev/test debug；未跑完整Rust回归。
- workspace contracts/parity检查通过：171操作、schemaGaps=0、4476 schemas；155 features、64 scenarios、134 sharedFiles、131 sourceAudits。客户端required=11/unreviewed=144；accepted=0、ready=false，不是完成验收。

版本：OTP创建/校验/注册各8、重置9、改邮箱4；登录15、刷新10、退出7保持。OpenAPI revision `2026-11-02-account-input`，SHA-256 `122ae4377c929ae6943baf394c100de19a30353c3fb52e87d20cfbf0580159d5`。新共同场景只有注册一个owner，相关功能以sharedDependencies复用。全部任务保持in-progress。

## 未完成工作

下一步审查安全页2FA/删除账号完整客户端生命周期、资料编辑输入、AUTH-901/905及并发撤销；继续其余144项客户端范围与完整业务同步。知识索引、持久化上下文、完整版本化Skills/有界Agent、群运营/审核、旧情感分析退役和Windows/Linux多机器部署仍在总目标内。

本次没有启动Docker/真实Oracle/Redis/模型/SMTP，没有执行日常迁移、提交/推送/切换分支或删除数据。Oracle约束/锁、SMTP真实投递、浏览器Cookie/cache/SSR、设备存储、六种客户端/原生后端组合及多机部署仍待C3集中验收。C盘复查仍约99.7 GiB可用，本次无清理操作，保留受控编译产物。
