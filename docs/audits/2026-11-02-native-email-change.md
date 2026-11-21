# 三后端原生改邮箱检查点

接续安全页OTP修复，目标见[共同需求](../../specifications/requirements/auth-email-change.md)和[计划](../plans/2026-11-02-native-email-change.md)。本轮只运行静态/隔离检查，未启动Docker、真实Oracle/Redis/模型或邮件，未迁移日常库，未提交/推送；保留全部既有未提交工作。

## 本轮实现

- Nuxt v2ChangeEmail不再调用会独立提交verified_at的通用OTP验证函数。校验新邮箱、change_email用途和bcrypt后，在同一连接以autoCommit=false条件消费OTP、更新当前用户、读回邮箱/验证时间并提交；零行/多行、读取、更新、提交异常均不返回成功，尝试回滚。唯一性竞争按409安全返回。
- Nuxt改邮箱路由使用safeAuthEntry，补入固定new_email空字段/重复邮箱错误白名单，避免驱动异常经通用路由日志或响应泄露；既有其他公开错误语义保持。
- Go新增原生PATCH路由、emailChangeStore接口及OracleSessions事务。复用现有鉴权、body标量规则、FindOTP/bcrypt；sql.Tx覆盖消费/更新/读回，失败回滚，Typed Oracle SQLError仅在邮箱更新的ORA-00001时映射409。
- Rust新增users/email_change与事务模块、原生路由及SessionRepository→OracleSessions→SessionExecutor→OraclePool接线。条件消费与更新/读取/提交共用连接，Oracle错误码1映射安全冲突；异步连接关闭错误沿用现有OraclePool安全失败规则。
- 三端返回email_verified_at时，在写入的同一连接按数据库SESSIONTIMEZONE将TIMESTAMP转UTC毫秒ISO字符串，避免应用主机时区造成差异。尚未实测Oracle SQL与驱动/时区行为。
- OpenAPI补齐必填字段与既有标量输入规则、JSON/表单、Cookie/Bearer鉴权、200必需数据字段和400/401/404/409/500的两种实际错误封套。契约revision为2026-11-02-email-change，已同步三个副本及来源清单；旧39项契约审计证据属于历史，此次新增审查独立记在本页。

## 测试与当前证据

新增共同AUTH-EMAIL-CHANGE场景25项，由三端实际HTTP路由测试读取同一文件。覆盖鉴权优先、字段转换/空值、收件人/用途/标识、新邮箱重复、OTP错误/过期、claim/update/read/commit/rollback失败、丢失竞争、缺用户/多行、唯一性竞争。最后一项专门模拟提交已生效后报错：响应500，但marks/writes仍为1。**不能用失败响应推断数据未改变，也不能把此模型当真实数据库并发验收。**

先观察Nuxt缺失事务、Go/Rust缺少原生类型/仓储接口、OpenAPI不接受实际标量输入的失败，再补实现。最终当前源码检查：

- Node 187项通过、0失败/取消/跳过：auth-compatibility、contract-payloads、security-otp、web-auth-response、auth-login-client。auth-compatibility为41项，其中新增共同邮箱场景、表单与重放、提交后close失败；每个共同场景测试内部遍历25条。不是187条真实服务验收。
- Nuxt typecheck exit 0。H3关于长statusMessage的提示为既有测试输出，未作为错误忽略失败。
- Go `go test ./...` 与 `go vet ./...` exit 0；新增共同场景25子用例、表单、实际database/sql驱动边界事务16子用例，覆盖绑定、行数、读取/rows关闭、回滚、提交、连接/Begin及唯一性错误。未运行真实驱动连接。
- Rust相关六个integration test文件38项通过（含新增仓储绑定后session_repository_test为24项），另事务单测1项遍历12种结果，合计39项不同测试。先运行旧版23项仓储回归，再新增1项并重跑24项，两次重叠不重复累加。一次带筛选的命令过滤了HTTP用例，之后已用无筛选命令实际运行，不将0 tests计成HTTP通过。
- contracts工作区检查：171 operations、schemaGaps=0、4475 schemasChecked。parity：155 features、61 scenarios、131 sourceAudits、129 sharedFiles；required=11/unreviewed=144，accepted=0、ready=false。跟踪文件diff --check通过。

Node替换数据库/邮件/cache等边界但运行实际H3鉴权、路由、服务、SQL调用和bcrypt。Go/Rust路由使用隔离仓储，共同场景之外分别测试实际事务控制及SQL参数。Rust事务Fake与并发Fake只证明控制流程；OraclePool的SQL与关闭仍需真实环境确认。

Rust本机无MSVC链接器的既有约束下使用现有WSL离线工具链，CARGO_INCREMENTAL=0、DEV/TEST DEBUG=0，未升级依赖。最后实测target逻辑大小989,066,085字节，C盘可用106,434,322,432字节（约99.1GiB）；没有新增删除。详见`.codex-logs/native-email-disk-2026-11-02.json`，数值仅代表该时点。

## 接续任务

改邮箱revision2保持不变（本轮实现该版本已定义的事务目标），三后端由proxy/not-started或旧实现登记为in-progress并绑定源码/共同场景；没有伪造accepted。共同需求与场景已同步Rust/Go/Flutter。其他认证版本仍为登录14、刷新9、退出7、OTP创建/验证/注册6、密码重置7。

下一步先补两客户端改邮箱完整响应解码与统一输入规则，随后安全页2FA/删除账号生命周期、AUTH-901/905及并发撤销；继续其余144项客户端范围、全部业务、知识索引、完整Skills/Agent/群运营/审核与旧模块退役。最终还必须验证真实Oracle行锁/唯一性/事务/时区/驱动、SMTP创建OTP、Cookie/cache/SSR、真实存储、六种前后端组合以及Windows/Linux多机器部署。完整目标没有缩小，不能因本切片通过标记项目完成。
