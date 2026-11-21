# 地址、实时连接与文件约定

这是现有实现的配置约定，与 `v2.openapi.json` 一起维护。Go 独立运行。Rust 提供原生运行模式及兼容代理模式。业务验收进度以对应验收报告为准。

## 地址配置

API 基址使用客户端能访问的服务根地址，例如 `https://neko.example.com`，不要再追加 `/api/v2`。各调用自己携带完整接口路径。

| 客户端 | API | WebSocket | 文件 |
| --- | --- | --- | --- |
| Nuxt Web | `NUXT_PUBLIC_API_BASE`。空值表示同源 | `NUXT_PUBLIC_WS_URL` 为完整地址，如 `wss://neko.example.com/_ws`。空值从 API 或页面地址推导 | `NUXT_PUBLIC_STORAGE_BASE` 是可选的 HTTP(S) 基址。空值跟随 API |
| Flutter | `API_BASE_URL` 或设置页 `apiBaseUrl` | `WS_BASE_URL` 或 `wsBaseUrl` 为根地址，如 `wss://neko.example.com`，客户端自动追加 `/_ws` | `STORAGE_BASE_URL` 或 `storageBaseUrl` 为根地址 |

Flutter 设置页保存的配置优先于编译时 `--dart-define`，之后才使用资源文件默认值。重建后仍连接旧服务时，检查已保存的设置。Nuxt 修改运行时变量后重启服务。

Nuxt Web 连接共用入口时只需设置 `NUXT_PUBLIC_API_BASE`。留空的实时地址从 API 保留端口及路径前缀，转换为 WS 或 WSS，并追加 `/_ws`。本机浏览器可显式选择 `ws://localhost:3000/_ws`。异机浏览器会跳过仅本机可达的实时地址。

Nuxt 的服务端渲染可以用私有变量 `NUXT_API_SERVER_BASE` 指向同一后端的内网入口，例如与 Go 共享容器网络时使用 `http://go:8080`。基址必须是绝对 HTTP(S) URL，可以带反代路径前缀。这个地址只供 Nuxt 服务端请求使用，并沿用 SSR 鉴权头转发。Nuxt Compose 在未定义该变量时使用 `API_BACKEND_UPSTREAM`，因此可与同源网关共用一份环境文件。最终值为空时使用公开 API 基址。浏览器的 API、WebSocket 和媒体地址仍由公开配置决定。

SSR 请求收到 401 时直接返回该结果，保留浏览器的现有会话。只有浏览器发出的请求会自动尝试刷新和重试，以便浏览器能接收轮换后的 HTTP-only Cookie。

独立媒体入口可设 `NUXT_PUBLIC_STORAGE_BASE=https://cdn.example.com`，Flutter 使用 `STORAGE_BASE_URL` 或设置页的 `storageBaseUrl`。两个客户端把 API 返回的相对公开媒体路径拼接到该基址之后，保留非默认端口、反代路径和公开路径前缀。后端返回的完整 HTTP(S) 地址保留原有路径与签名查询参数。上传和私密媒体读取仍走 API 服务。

Flutter 连接共用入口时只需设置 `API_BASE_URL`。未分别指定时，文件地址沿用 API 基址，WebSocket 地址按协议推导为 WS 或 WSS，并保留端口和反代路径前缀。设置页修改 API 地址时，原来跟随 API 的字段自动更新，独立填写的字段继续使用各自地址。「实时连接和文件使用同一地址」可让两项重新跟随 API。保存前校验三类地址的协议，并禁止凭据、查询参数与片段。

Flutter 读取资源文件的默认值、自定义预设和本机已保存设置时，都从有效的 API 基址补齐空缺的 WebSocket 和媒体地址。已独立配置的地址仍使用原值。

Flutter 在保存自定义地址或应用预设前统一校验三类地址。可只填写 API 基址，保存后立即使用补齐的实时和媒体地址，重启仍使用同一组地址。已保存的配置若有无法解析的地址，启动时使用部署默认值，直至用户保存新配置。

Flutter 先保存端点设置，再更新运行时地址。切换使旧 HTTP 请求和 WebSocket 实例失效，旧请求随后返回的 401 无法刷新或清除当前会话。设置页重置会恢复本次构建的默认地址。切换保留已保存的会话，供使用同一 Oracle 会话和签名密钥的后端继续验证。已经发送的业务写入可能在旧服务端完成，切换不回滚服务端事务。

保存或重置失败时，Flutter 保留当前运行时连接。重新加载设置时先从平台重新读取持久化值，避免使用失败操作留在内存缓存里的地址。

异机访问 Flutter Web 的登录页面时，部署站点应提供 HTTPS，并为 API、实时和文件配置对应的 HTTPS 或 WSS 地址。浏览器缺少加密会话存储所需能力时，Flutter 拦截登录凭据提交并显示部署提示。本机开发仍可使用浏览器认可的 localhost 地址。

Flutter Web 的端点设置会先检查协议。HTTPS 页面下，填写远端 HTTP API、HTTP 媒体或 WS 实时地址时，提示改用 HTTPS 或 WSS，并保留当前已保存配置。浏览器认可的回环地址以及原生 Flutter 的本地设置仍按原方式使用。

Flutter 登录页可以直接打开端点设置。此页面只编辑本机端点并提供无凭据探测，未登录即可使用。切换后端后返回登录页会清掉此前输入的密码。

保存前可在 Flutter 设置页同时检查 API 基址下的 `/api/ready` 和媒体基址下的 `HEAD /storage/default-avatar.png`。分别显示 API 依赖就绪和媒体访问结果。检查保留各自路径前缀，不发送登录凭据或更改当前端点。Flutter Web 跨来源检查沿用后端或媒体代理配置的 CORS 来源。编辑 API 或媒体地址后，前一次结果不再显示。旧代理缺少检查路由时仍可手动保存地址。

Flutter 仅在 `/api/ready` 返回 503 且正文为 `{"status":"unavailable"}` 时显示后端未就绪。代理返回的 HTML 错误页或其他不兼容正文会提示核对 API 基址和代理前缀。

监听地址与对外地址分开：`HOST=0.0.0.0` 用于监听网卡，不能作为客户端目的地址。远端客户端不能使用服务器的 `localhost`，容器服务名也不能直接交给外部浏览器。端口、域名、HTTP/HTTPS 必须组成完整且可达的地址。

从客户端所在机器可运行 Nuxt 工作树中的 `node scripts/check-deployment-endpoints.mjs --api BASE` 做只读连接检查。可指定 `--media BASE`、`--realtime BASE` 及 `--origin ORIGIN`。命令检查 API 就绪、默认头像 HEAD、无凭据的实时握手，以及指定浏览器来源的跨域规则。三个服务基址均保留反向代理路径前缀。真实登录、实时订阅与发帖等仍由整体验收覆盖。

失败项的 `reason` 用于定位配置。`backend-not-ready` 表示 API 已返回就绪接口定义的 503，需检查后端依赖。`route-not-found`、`redirect` 或 `invalid-*-response` 时，检查基址、代理前缀和上游服务。返回 `api-cors-rejected` 或 `media-cors-rejected` 时，核对浏览器来源及对应服务的跨域规则。返回 `connection-failed` 或 `request-timeout` 时，检查主机、端口、网络和 HTTPS 配置。

Go 原生入口为 `go run ./cmd/server` 或构建后的程序，`GO_BACKEND_PORT` 优先 `PORT`，默认 30006。公共网关默认 30005。Rust 的源码、二进制和默认 Compose 入口都启动原生后端。本机端口取 `RUST_BACKEND_PORT` 或 `PORT`，默认 30003。Docker 发布默认宿主机 30003，容器固定监听 8080。旧 Nuxt 代理可显式使用 `RUST_BACKEND_MODE=compat` 或 `compose.compat.yaml`。两个原生后端通过显式进程环境配置，启动预检只读检查所需 Oracle 结构。统一启动器会把所选端口传给子进程。具体配置见各工程 `env.example`。

预编译发布包中，将 `env.example` 复制为同目录的 `.env.go` 或 `.env.rust`。配置所需依赖后，先运行 `node start-native.mjs --check`，再运行 `node start-native.mjs`。启动器按 `native-package.json` 选择同目录的程序，检查当前 Node.js 的操作系统和架构。可用 `--env-file PATH` 从其他路径读取配置，进程环境优先。用 `node package-native.mjs --verify .` 核对交付文件的哈希。

当前源码及 `package-native.mjs --build` 生成的 Go、Rust 包可用 `--check-config` 执行后端离线配置检查。它使用真实启动参数校验 Oracle 和 Redis 配置与令牌签名设置，检查后退出，依赖能否连通须另外验证。

## HTTP 鉴权与浏览器

Nuxt 接受现有 access Cookie 或 Bearer token；Flutter 使用登录响应中的 token。刷新会轮换 token，退出后旧会话不可继续使用。测试和客户端不能把刷新前的 token 缓存为永久凭据。

共享账号/会话时，三后端的 `ACCESS_SECRET` 必须互相一致，`REFRESH_SECRET` 也必须互相一致；access与refresh各自用独立密钥，不是给不同后端分别生成不兼容的签名密钥。原生撤销先验JWT再核对Oracle user/session/jti/到期/撤销状态。会话列表绕过响应缓存；撤销后新请求不能凭旧缓存继续授权。session路径id为opaque string，保留现有Nuxt原始百分号编码的路径片段语义，不强制转换为数字。

Go 和 Rust 的原生启动、离线配置检查支持在 Oracle 主机、端口、服务名、用户、密码、连接池上下限以及签名密钥和 Cookie 安全开关前加 `NUXT_`。有前缀值时优先使用该值。必填值显式为空时会报告缺失。原生 Skills 维护命令以相同规则解析 Oracle 连接地址和凭据。

三套后端启动时校验 `ACCESS_EXPIRES_IN` 和 `REFRESH_EXPIRES_IN`，也接受对应的 `NUXT_` 前缀，前缀值优先。缺省分别使用 900 和 2592000 秒。显式空值、非正整数、超过 2147483647 秒或刷新有效期不长于访问有效期均会拒绝启动。可保留首尾 ASCII 空白、前导加号和零。Nuxt 也保留 Nitro 运行时对对应 `NITRO_` 变量的优先级。

三套后端都支持 `REDIS_URL` 或 `NUXT_REDIS_URL`。使用 `rediss://` 启用 TLS，并校验实际连接主机的证书。需要拆分配置时，主机、端口、库号和密码变量可覆盖 URL 中对应字段。前缀变量优先，显式空值跳过旧变量并保留 URL 中的对应设置或默认值。默认端口为 6379，默认库号为 0。

`REDIS_PASSWORD` 和 `NUXT_REDIS_PASSWORD` 填写原始密码，包括密码中的 `%` 字符。将密码写入 `REDIS_URL` 时，按 URL 用户信息的规则进行百分号编码。

API 请求默认发送 `Accept: application/json`。成功沿用 v2 `{code,message,data,meta}`；现有 Nitro 的 JSON 错误体有框架外壳，业务错误封套位于其 `data`，未处理异常可省略该字段。显式请求 HTML 的调用方可能收到 HTML 错误页，不能把所有错误都解析为顶层 v2 成功封套。

跨来源访问必须在 Nuxt 上配置 `CORS_ALLOWED_ORIGINS` 的精确来源（包含协议、域名与端口），不能把允许携带凭据的来源设为 `*`。CORS 放行不等于浏览器会允许跨站 Cookie；Nuxt Web 推荐通过同一个公共来源反向代理 API、页面、文件和 WebSocket。HTTPS 入口配置 `COOKIE_SECURE=true`，不要在 HTTPS 页面引用 HTTP API 或 WS 明文连接。

Flutter 默认发送 `x-request-id`、`x-client-platform`、`x-device-fingerprint` 和 `x-device-info`，它们与 Authorization、Content-Type、Accept 一起属于明确的 CORS 请求头白名单。预检必须覆盖实际客户端请求头；只验证不带这些头的 OPTIONS 不能证明 Flutter 已打通。未允许的来源、方法和请求头仍拒绝。

## 实时连接

Nuxt `/_ws` 从查询参数 `token`、Authorization 或 access Cookie 验证登录会话。Flutter 当前把 token 放入握手查询参数；代理及访问日志不要记录该查询内容。未认证连接收到错误后关闭。

消息使用 JSON，包含 `type` 和可选 `data`。客户端 `ping` 得到 `pong`；聊天频道订阅使用 `chat_join_channel` / `chat_leave_channel`，权限仍由服务端验证。连接建立、心跳成功不代表聊天、通知和断线恢复的完整业务矩阵已验收。

Rust 和 Go 原生模式各自处理 `/_ws` 和公开文件路由。公共网关的 `API_BACKEND_UPSTREAM` 默认使用 `UI_NUXT_UPSTREAM`。`WS_BACKEND_UPSTREAM` 和 `MEDIA_BACKEND_UPSTREAM` 默认跟随 API。Rust 兼容模式须显式将 WebSocket 上游指向 Nuxt。网关转发 Upgrade 和 Connection，并保留公共 Host 中的端口。公开 `/storage/` GET 和 HEAD 走媒体上游，转发时去掉 Cookie 和 Authorization。媒体上传走 API 上游。

## 文件与数据

Nuxt 的 `STORAGE_PATH`（优先）或 `STORAGE_ROOT_DIR` 指定磁盘目录；相对路径按启动项目目录解析。`STORAGE_PUBLIC_BASE` 是公开 URL 前缀，默认 `/storage`；`BASE_URL` 和可选 `STORAGE_CDN_BASE_URL` 必须是客户端可达的公共地址，不能写入容器内部主机名。

若公开前缀设为 `/files` 等自定义路径，在 CDN 或反向代理配置该前缀的文件分发。回源使用后端的本地文件读取路由时，将 `/files/<key>` 映射到 `/storage/<key>`，并保留默认头像探测用的 `/storage/default-avatar.png`。直接由后端分发时沿用 `/storage`。

日常开发共用原数据库、Redis 与上传文件。整理后的本机 Nuxt 私有配置指向 `../storage` 和原 Oracle 数据目录，其他机器应使用自己的明确路径。后端不得因为换目录而自动初始化或清空数据。

测试必须使用独立数据库/schema、Redis 实例或明确隔离资源、独立上传目录及测试凭据。端口不同本身不构成数据隔离。数据库初始化由 Nuxt 现有受保护入口统一管理，Rust/Go 不在启动时执行各自的 schema 修改。

已有 schema 的功能升级统一使用显式 `scripts/migrate-db.mjs`：默认离线计划，`--check` 只读，`--apply` 才修改，并用 `--dotenv` 明确选择环境。业务请求只读检查必要结构，缺失时返回通用 503；完整开发基线不可重跑来升级旧库。当前连接模型要求 schema owner，不能把本轮实现描述成已支持任意跨 owner 的低权限账号。

当前依据：Nuxt `app/utils/apiBase.ts`、`server/routes/_ws.ts`、`server/storage/config.ts`、`server/middleware/00-cors.ts`；Flutter `lib/core/config/app_config.dart`、`lib/features/realtime/data/realtime_service.dart`；Rust `src/app/routes.rs`。运行组合的通过、失败与未测项以对应验收报告为准。
