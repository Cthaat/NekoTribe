# 2026-10-27 原生运行入口与会话撤销检查点

本轮接通实际 HTTP → JWT → Oracle 会话条件更新 → 撤销两条链路的源码，补独立 Go 进程入口和 Rust native 模式。三端使用同一需求与29个共同HTTP/JWT隔离用例；这是原生业务增量，不是完整认证、完整后端、真实数据库或AI产品验收。

## 运行与接口范围

- Nuxt：沿用完整主项目和现有两条DELETE，补资源关闭/错误/Cookie边界、会话列表缓存绕过和日志路径脱敏。
- Rust：`RUST_BACKEND_MODE=compat` 缺省保留现有兼容代理；`native` 只注册会话撤销与进程health，不注册其他业务、文件、WS代理。`prepare_router` 先只读预检会话列，再由main绑定端口。源代码在 `src/auth/sessions.rs`、`session_repository.rs`、`app/routes.rs`、`config/env.rs`、`db/pool.rs`。
- Go：`cmd/server` 是实际独立服务，源码在 `internal/server`；显式环境，HOST默认127.0.0.1、GO_BACKEND_PORT优先PORT，默认30006。固定Oracle官方纯Go驱动v26.4.0，最低Go1.26.9；本机SDK1.27.3。监听前只读会话结构预检，不初始化/迁移数据。
- 两条业务接口为 `DELETE /api/v2/auth/sessions/{id}` 和 `/others`。access/refresh各类key必须分别与其他后端一致，Oracle数据目标也需一致；新进程不会自动寻找Nuxt私有配置。当前Go/Rust native没有登录、刷新、会话列表等其他业务，完整前端尚不能仅靠切到它们就全部工作。

每次撤销都先使用实际JWT库验access，再匹配Oracle user/session/access_jti、到期与未撤销状态并touch，恰好一行才进入业务。只能撤销本人的会话；others保留当前，包含已到期未撤销记录；本人当前会话撤销成功才发送两Cookie删除。原生未实现路由明确失败，不调用Nuxt。

## 共同需求与同步

权威需求为 `specifications/requirements/auth-session-revocation.md`，公开样例为 `scenarios/auth-session-revocation.json`；独立Rust/Go只依赖自己的contracts副本。样例包含他人/未知/重复/到期、当前会话再次请求失效、Cookie/header优先级、带引号/重复名称/多Cookie字段、原始编码id与安全故障。

两条操作合为单一 `AUTH-SESSION-REVOCATION` 功能，旧 `API-delete_auth_sessions_id` / `API-delete_auth_sessions_others` 保存在supersedes、不复用；不是删除API或减少验收范围。现在165个登记项仍覆盖162个规范操作与4个AI方向。会话列表的独立迁移和其他认证功能继续保留任务。

OpenAPI修正session path id的错误integer声明为opaque string，实际路由保留既有原始百分号编码语义；审计修订为 `2026-10-27-native-session-revocation`。四工程LF规范SHA-256为 `b9788a77efc871e830ad3f73538c2df3a830a9c59c4893196da681eb8c8b4c37`。同步先保存Nuxt来源，再固定该来源提交；manifest的differsFromCommittedSource按实际差异填写，不冒称新内容属于旧提交。runtime-addresses也同步了有限native入口。

共同检查为165 features、162 operations、7场景文件、14公共文件、281个server来源、130个其他入口仍待审查；accepted:0、ready:false，release按预期拒绝未完成业务。没有将隔离测试手填为真实业务accepted证据。

## 本轮验证

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| 共同HTTP/JWT | 三端同29样例通过，真实H3/Axum/Go路由和JWT，Oracle边界为隔离状态 | Nuxt `20261027-session-revocation-green.log`；Go `session-shared-29-final.log`；Rust `session-repeated-cookie-green.log` / 全套日志 |
| Nuxt边界 | 37个测试函数通过，含29共同用例和资源关闭/Cookie/缓存/日志/规范回归 | Nuxt `.codex-logs/20261027-session-revocation-green.log` |
| Node全套 | 343通过、2跳过、0失败（总345） | `.codex-logs/20261027-native-session-node-tests.log` |
| Nuxt类型 | 完整sample-env typecheck通过，43.77s | `.codex-logs/20261027-native-session-typecheck.log` |
| Go | 全套test/vet通过；SDK模块校验通过；Windows/Linux amd64 CGO0编译通过 | Go `.codex-logs/session-final-test.log`、vet日志、`20261027-session-build-windows.log` / `-linux.log` |
| Rust | WSL全套48通过、2个Oracle/Redis真实连接测试忽略；实际Linux二进制构建、Windows格式检查通过 | Rust `.codex-logs/session-native-all-green.log`、`session-final-build.log` |
| 配置/生产仓储 | 参数绑定、独立commit、错误和close、预检顺序、优雅排空、配置脱敏、CORS及Nuxt计数上游零访问 | Go/Rust各 `session-*.log` 和对应测试源码 |
| 契约/登记 | 四工程check通过，release因未完成项正确退出1 | Nuxt `.codex-logs/20261027-session-contract-check.json`、`20261027-session-parity.json`、`20261027-session-release.log` |

只临时运行loopback测试服务器，结束后关闭。没有启动Docker、实际应用、真实数据库或模型，没有读写原日常业务数据。Go的Linux结果是交叉构建；Rust在WSL运行，不是原生Windows链接/运行证明。Flutter只有公共契约副本变更；已有撤销接口参数本来就是String，没有为未完成后端添加空产品入口。

## 审查与红绿修复

- Nuxt鉴权connection.close原可覆盖成功/401；现在安全401并在关闭成功后发布auth。撤销SQL及通用连接获取/关闭错误收口安全500。
- 自身撤销已提交、service close失败时，原实现仍发删除Cookie；现在恢复业务前的Set-Cookie，不发送本次新增/删除，并验证保留更早middleware Cookie。HTTP500不代表写入回滚。
- 会话列表显式绕过响应缓存。源码审计纠正旧AUTH-906：真实Oracle连接包装还会失效API auth/account tag，不能只看2FA路由neutral就认定必然陈旧。
- Nuxt会话资源path与rawUrl日志脱敏，真实请求URI不变；旧帖子测试原来给H3空res对象，本次改为真实ServerResponse以覆盖通用连接函数，保留全部原断言。第一次全套回归的8个失败均由该测试夹具缺getHeader导致，修复后全套通过。
- Go修复普通请求错误检查预检专用头、空query/port origin、显式空NUXT配置优先级；Rust修复带引号Cookie、首个空重复值及多Cookie字段选择，均保留先失败后通过记录。

规范审查和质量审查均已分别通过。生产Oracle SQL执行器已编写、编译并验证调用契约，但没有据fake store/driver证明Oracle驱动的真实网络、DDL/数据类型或数据库并发行为。

## 仍需完成

真实Oracle19c/Free、跨后端共享会话与双前端、跨机器部署均未执行；还须核对各驱动session timezone对TIMESTAMP到期条件的影响，不能只凭相同SQL就宣布运行语义一致。Go的sql.Conn.Close是归还池句柄；物理driver close通过关闭DB的测试验证，不能说每次请求实际断开Oracle。Rust显式关闭每次操作连接；已开始的spawn_blocking Oracle工作不会因异步等待超时/断开而强行取消，许可随操作完成/close释放，写入仍可能提交。不能承诺严格数据库取消或回滚。

完整登录/刷新/OTP/2FA、会话列表（含日期/分页/排序语义）、其他用户/内容/群组/实时/文件、旧情感分析退役和三组AI产品继续按总体计划实现。旧源码恢复ZIP仍为历史快照，没有将它当成本轮新提交交付包。
