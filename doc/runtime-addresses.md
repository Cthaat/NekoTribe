# 地址、实时连接与文件约定

这是现有实现的配置约定，与 `v2.openapi.json` 一起维护。Rust 当前代理 Nuxt 业务接口，Go 尚未实现服务。

## 地址配置

API 基址使用客户端能访问的服务根地址，例如 `https://neko.example.com`，不要再追加 `/api/v2`。各调用自己携带完整接口路径。

| 客户端 | API | WebSocket | 文件 |
| --- | --- | --- | --- |
| Nuxt Web | `NUXT_PUBLIC_API_BASE`；空值表示同源 | `NUXT_PUBLIC_WS_URL` 为完整地址，如 `wss://neko.example.com/_ws`；空值从 API 或页面地址推导 | 相对文件 URL 按 API 基址连接 |
| Flutter | `API_BASE_URL` 或设置页 `apiBaseUrl` | `WS_BASE_URL` 或 `wsBaseUrl` 为根地址，如 `wss://neko.example.com`，客户端自动追加 `/_ws` | `STORAGE_BASE_URL` 或 `storageBaseUrl` 为根地址 |

Flutter 设置页保存的配置优先于编译时 `--dart-define`，之后才使用资源文件默认值。重建后仍连接旧服务时，检查已保存的设置。Nuxt 修改运行时变量后重启服务。

监听地址与对外地址分开：`HOST=0.0.0.0` 用于监听网卡，不能作为客户端目的地址。远端客户端不能使用服务器的 `localhost`，容器服务名也不能直接交给外部浏览器。端口、域名、HTTP/HTTPS 必须组成完整且可达的地址。

## HTTP 鉴权与浏览器

Nuxt 接受现有 access Cookie 或 Bearer token；Flutter 使用登录响应中的 token。刷新会轮换 token，退出后旧会话不可继续使用。测试和客户端不能把刷新前的 token 缓存为永久凭据。

跨来源访问必须在 Nuxt 上配置 `CORS_ALLOWED_ORIGINS` 的精确来源（包含协议、域名与端口），不能把允许携带凭据的来源设为 `*`。CORS 放行不等于浏览器会允许跨站 Cookie；Nuxt Web 推荐通过同一个公共来源反向代理 API、页面、文件和 WebSocket。HTTPS 入口配置 `COOKIE_SECURE=true`，不要在 HTTPS 页面引用 HTTP API 或 WS 明文连接。

## 实时连接

Nuxt `/_ws` 从查询参数 `token`、Authorization 或 access Cookie 验证登录会话。Flutter 当前把 token 放入握手查询参数；代理及访问日志不要记录该查询内容。未认证连接收到错误后关闭。

消息使用 JSON，包含 `type` 和可选 `data`。客户端 `ping` 得到 `pong`；聊天频道订阅使用 `chat_join_channel` / `chat_leave_channel`，权限仍由服务端验证。连接建立、心跳成功不代表聊天、通知和断线恢复的完整业务矩阵已验收。

Rust 当前没有 `/_ws` 路由。直接访问 Rust API 时，WebSocket 必须另配可达的 Nuxt 地址，或由公共反向代理把 `/_ws` 转发到 Nuxt。不能把 Rust 健康检查通过解释为实时连接已兼容。部署网关必须传递 Upgrade/Connection，并设置适合长连接的超时。

## 文件与数据

Nuxt 的 `STORAGE_PATH`（优先）或 `STORAGE_ROOT_DIR` 指定磁盘目录；相对路径按启动项目目录解析。`STORAGE_PUBLIC_BASE` 是公开 URL 前缀，默认 `/storage`；`BASE_URL` 和可选 `STORAGE_CDN_BASE_URL` 必须是客户端可达的公共地址，不能写入容器内部主机名。

日常开发共用原数据库、Redis 与上传文件。整理后的本机 Nuxt 私有配置指向 `../storage` 和原 Oracle 数据目录，其他机器应使用自己的明确路径。后端不得因为换目录而自动初始化或清空数据。

测试必须使用独立数据库/schema、Redis 实例或明确隔离资源、独立上传目录及测试凭据。端口不同本身不构成数据隔离。数据库初始化由 Nuxt 现有受保护入口统一管理，Rust/Go 不在启动时执行各自的 schema 修改。

当前依据：Nuxt `app/utils/apiBase.ts`、`server/routes/_ws.ts`、`server/storage/config.ts`、`server/middleware/00-cors.ts`；Flutter `lib/core/config/app_config.dart`、`lib/features/realtime/data/realtime_service.dart`；Rust `src/app/routes.rs`。运行组合的通过、失败与未测项以对应验收报告为准。
