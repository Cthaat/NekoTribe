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

## HTTP、文件与实时通信边界

- 规范内 v2 路由的 OPTIONS 请求转发给 Nuxt，由 Nuxt 精确来源 CORS 策略处理；Rust 不自行放开来源。规范外路径仍返回 404。
- 既有 SentimentFlow 非 OPTIONS 前缀例外暂时保留；该可选集成预检未覆盖，不表示已经联调。
- `/storage/**`、`/uploads/**` 的读取依赖 Nuxt 上游。Rust 自身不持有上传目录。
- 当前 Rust 没有 `/_ws` 路由。客户端必须单独配置 Nuxt 的公共 WebSocket 地址，或使用将 WebSocket 路由到 Nuxt 的统一入口；只改成 Rust 端口不能获得 WebSocket 支持。

## 规范与历史

编译期只读取 [contracts/v2.openapi.json](contracts/v2.openapi.json)，来源见 [manifest](contracts/manifest.json)。Nuxt `doc/` 是权威源；本工程持有固定版本副本，不需要兄弟目录源码即可构建运行。规范覆盖核对及同步由 T11–T13 单独推进。

目录拆分前的 `backend-rust/`、继承的 Nuxt 文件及历史迁移报告仍保存在提交 `ab45d491818ad6a3db3866adf2a2e136be80a49e` 的 Git 历史中。旧验收报告不代表本轮验证结果，后续原生业务迁移尚待实施。