# NekoTribe Rust 兼容后端

本分支是独立 Rust 工程。当前业务接口仍通过 HTTP 转发给 Nuxt；已实现 Rust 健康检查、响应工具、中间件以及 Oracle/Redis 基础设施，尚未完成原生业务迁移。

## 构建与验证

在本工程根目录运行：

```text
cargo fmt --all -- --check
cargo check --locked -j 2
cargo test --locked -j 2
cargo build --locked -j 2
```

Windows 需要 Rust MSVC 工具链及 Visual C++ 链接器。本次机器缺少 `link.exe`，原生 Windows check/test 未能通过；格式检查通过，独立克隆的 Linux check/test/build 已通过。Linux 默认测试为 20 项通过、2 项真实 Oracle/Redis 连通测试忽略；忽略项不等于已验证。

真实 Oracle 连通还需要进程可加载的 Oracle Instant Client。只在显式配置的隔离测试服务上运行 `cargo test --locked -j 2 --test connectivity_test -- --ignored`。这两项测试只读取本工程根 `.env`，不会向父目录寻找配置。

## 配置与启动

参考 `env.example`，把所选变量注入启动进程；应用本身不自动加载 `.env`。PowerShell 示例：

```powershell
$env:HOST = '127.0.0.1'
$env:RUST_BACKEND_PORT = '30003'
$env:LEGACY_BACKEND_BASE_URL = 'http://127.0.0.1:30001'
cargo run --locked -j 2
```

Nuxt 上游不可用时，代理业务接口无法正常工作。Docker 内监听 8080，需按实际网络设置 `DOCKER_LEGACY_BACKEND_BASE_URL`；`docker build -t nekotribe-rust:local .` 仅构建本工程，不创建或初始化 Oracle、Redis、Nuxt。继承自旧混合分支的 Nuxt Compose 与发布工作流已经移除。

本目录 `compose.yaml` 只定义 Rust 容器，构建上下文为本目录，不挂载或读取兄弟源码。未来需要实际部署时，可复制 `env.example` 为自行保管的配置文件，例如 `.env.deploy`，检查变量后执行：

```text
docker compose --env-file .env.deploy config --quiet
docker compose --env-file .env.deploy up -d --build
```

`RUST_PUBLISH_HOST` / `RUST_PUBLISH_PORT` 控制宿主机发布地址，默认 `127.0.0.1:30003`；容器固定监听 `0.0.0.0:8080`。`DOCKER_LEGACY_BACKEND_BASE_URL` 必须指向容器可访问的既有 Nuxt，默认通过 `host.docker.internal:30001` 访问宿主机；Nuxt 监听地址和防火墙也必须允许来自容器的连接。若使用已有 Docker 网络，请按实际网络配置服务地址及网络接入。Compose 的 `--env-file` 用于变量替换，仅 `environment` 列出的变量传入容器；当前代理启动不连接 Oracle/Redis，所以该文件没有数据库凭证传递或依赖服务定义，也不自动创建 schema。Nuxt 仍需自行配置其已有数据库、Redis 与上传存储。

历史 `.verification/docker-build.log` 已记录完整镜像构建结束（`Successfully built 42350cdba5fe`）；这是修改前的历史证据。本轮只做静态开发与格式检查，新增 Compose 和代理头过滤测试尚未执行，不能据此声称本轮镜像或联调已通过。

## HTTP、文件与实时通信边界

- 规范内 v2 路由的 OPTIONS 请求转发给 Nuxt，由 Nuxt 精确来源 CORS 策略处理；Rust 不自行放开来源。规范外路径仍返回 404。
- 代理过滤标准逐跳头及 `Connection` 指定的头；上游 CORS 响应头与多条 `Set-Cookie` 保留。当前请求和响应仍整包缓冲，且 HTTP 客户端仍使用默认重定向策略；流式传输和重定向链上的 Cookie/CORS 行为尚未完成真实联调。
- 既有 SentimentFlow 非 OPTIONS 前缀例外暂时保留；该可选集成预检未覆盖，不表示已经联调。
- `/storage/**`、`/uploads/**` 的读取依赖 Nuxt 上游。Rust 自身不持有上传目录。
- 当前 Rust 没有 `/_ws` 路由。客户端必须单独配置 Nuxt 的公共 WebSocket 地址，或使用将 WebSocket 路由到 Nuxt 的统一入口；只改成 Rust 端口不能获得 WebSocket 支持。

## 规范与历史

编译期只读取 [contracts/v2.openapi.json](contracts/v2.openapi.json)，来源见 [manifest](contracts/manifest.json)。Nuxt `doc/` 是权威源；本工程持有固定版本副本，不需要兄弟目录源码即可构建运行。规范覆盖核对及同步由 T11–T13 单独推进。

目录拆分前的 `backend-rust/`、继承的 Nuxt 文件及历史迁移报告仍保存在提交 `ab45d491818ad6a3db3866adf2a2e136be80a49e` 的 Git 历史中。旧验收报告不代表本轮验证结果，后续原生业务迁移尚待实施。
