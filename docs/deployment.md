# Windows / Linux 启动与部署

本说明对应整理后的独立 Nuxt 项目。静态阶段已结束，2026-10-26 按用户授权安装 Docker 并执行集中测试；当前通过和未通过的项目见 [运行验收记录](audits/2026-10-26-runtime-verification.md)。下面命令用于实际启动与部署；不可将本机 Linux 容器结果冒称另一台服务器已验收。

2026-11-22 vNext 交付四栈源码版本、六套后端平台包、Flutter Web 和两套独立 AI 包。用户已取消本轮服务器部署。源码提交和归档 SHA-256 随包登记，真实迁移与公共入口联调的步骤保留在隔离验收清单。[vNext 交付说明](../../docs/deployment/README.md#vnext-2026-11-22-交付) · [vNext 隔离验收清单](../../docs/deployment/ACCEPTANCE-VNEXT-20261122.md)

## 取得本轮代码

若取得源码恢复套件，先阅读套件 README，再运行 `node restore-workspace.mjs 新目录`（Windows 也可 `restore.cmd 新目录`，Linux `sh restore.sh 新目录`）。它按 manifest 校验哈希与四个分支，并建立正确 worktree 和管理文件；不覆盖已有目标，不自动安装框架或启动数据库。设计与边界见 [恢复入口](architecture/workspace-restore.md)。

四个工程分别位于 `master`、`Rust`、`Flutter`、`codex/go`。本地提交尚未发布，不能把远程旧版本视为本轮交付。已提交后可以在 Nuxt 目录导出给另一台机器：

```text
git bundle create NekoTribe.bundle master Rust Flutter codex/go
git bundle verify NekoTribe.bundle
```

将 bundle 复制到目标机器，再在其父目录执行（Windows 与 Linux 的 Git 命令相同）：

```text
git clone --branch master NekoTribe.bundle NekoTribe/nuxt
git -C NekoTribe/nuxt worktree add --track -b Rust ../rust origin/Rust
git -C NekoTribe/nuxt worktree add --track -b Flutter ../flutter origin/Flutter
git -C NekoTribe/nuxt worktree add --track -b codex/go ../go origin/codex/go
```

若从已发布的新仓库克隆，将 bundle 参数换为仓库地址即可。不要复制 linked worktree 的 `.git` 指针文件当独立仓库；每个分支均可单独克隆构建。bundle 不包含私有配置、数据库和上传文件，这些需按备份及数据迁移流程单独处理。

## 方式选择

| 方式 | 应用运行位置 | 数据依赖 | 入口 |
| --- | --- | --- | --- |
| 本地 | 宿主机 Node | 已存在的 Oracle / Redis | `yarn dev` / `yarn start` |
| 混合 | 宿主机 Node | 本项目 Compose Oracle / Redis | `deploy.mjs ... --mode dependencies`，再本地启动 |
| 源码完整栈 | 本项目 Dockerfile 构建容器 | 本项目 Compose Oracle / Redis | `--mode source` |
| 已发布镜像 | 指定发布镜像 | 本项目 Compose Oracle / Redis | `--mode image`；未发布修复不会自动包含 |
| 外部依赖 | 仅应用容器 | 另一台主机或已有服务 | `--mode external` |

全栈 Compose 为 Oracle 19c 的现有 x86-64 部署设计，需要可获取且被允许运行的 Oracle 镜像、足够内存和持久磁盘。新库初始化可能耗时较长。Linux 容器构建与独立 Linux 服务器验收分别记录。

## 后端就绪检查

Windows 本地、Linux 服务器和容器部署均可向所选后端的地址及端口发送 `GET /api/ready`。Oracle 和 Redis 均在两秒内响应时返回 HTTP 200，依赖不可用或超时返回 503。`GET /api/health` 用于进程存活检查。Nuxt 源码构建、Go 原生和 Rust 原生的 Compose 配置已使用就绪检查。发布镜像模式继续使用 `/api/health`，以兼容发布较早的镜像。Rust 兼容代理部署应检查它配置的原生后端。业务、迁移和可选服务按部署验收流程单独验证。[就绪检查规范](../specifications/requirements/service-readiness.md)

### 从客户端所在机器检查端点

在另一台 Windows 或 Linux 机器上，从 Nuxt 源码目录运行 Node 检查命令。`--api` 使用客户端实际填写的 API 根地址。媒体和实时地址默认跟随 API，也可以分别传入代理前缀或独立基址。

```text
node scripts/check-deployment-endpoints.mjs --api https://neko.example.com
node scripts/check-deployment-endpoints.mjs --api https://api.example.com/service --media https://media.example.com --realtime wss://ws.example.com --origin https://neko.example.com
```

新版交付包内也可直接运行同一命令。Nuxt 使用 `scripts/check-deployment-endpoints.mjs`，Go、Rust 和 Flutter Web 在包根目录使用 `check-deployment-endpoints.mjs`。`--realtime` 可传实时服务基址，也可直接传 Nuxt `NUXT_PUBLIC_WS_URL` 中以 `/_ws` 结尾的完整地址。检查只发送无凭据请求。

输出分别给出 API 就绪、默认头像 `HEAD`、WebSocket 路由和可选的浏览器跨域预检结果。跨源媒体检查同时核对允许来源。实时检查采用无凭据握手，能识别有效升级或应用的 `40101` 登录要求。命令不登录、不写业务数据，任一端点失败返回退出码 `1`，参数错误返回 `2`。登录后实时业务和媒体上传仍按隔离环境执行完整验收。

## 从配置文件启动原生后端

在 Go 或 Rust 源码目录内，从 `env.example` 准备私有的 `.env.go` 或 `.env.rust`。Windows 双击 `start.cmd`，Linux 运行 `sh start.sh`。例如 `start.cmd --check` 或 `sh start.sh --check` 会先做离线配置检查。每个脚本只识别自己所在的源码目录和该目录内的专用环境文件；也可传入 `--env-file PATH` 或在进程环境中提供配置。使用源码入口时目标机器须提供 Node.js 和该框架的构建工具。

在四工作树的父目录运行以下命令。Windows PowerShell 和 Linux 使用同一 Node.js 入口。示例文件名填写部署实际使用的私有环境文件。

```text
node nuxt/scripts/start-native.mjs go --env-file go/.env.go
node nuxt/scripts/start-native.mjs rust --env-file rust/.env.rust
```

可重复传入 `--env-file`。从左到右覆盖同名值，当前进程环境优先。若把配置拆为共享文件和后端专用文件，先传共享文件。文件按 dotenv 读取，不作为脚本执行。源码启动在选中的工作树运行 `go run` 或 `cargo run --locked`，Rust 固定为原生模式。

追加 `--check` 可离线核对必要字段和端口。另有预编译程序时可传 `--binary PATH`，以程序所在目录为工作目录，适用于没有源码的目标服务器。启动脚本不启动依赖，也不执行迁移。已有 Oracle、Redis 和需要的组件由部署配置提供。

## Nuxt 独立 Node 部署包

在与目标主机相同的平台和架构上，从安装了项目依赖的 Nuxt 工作树构建交付目录。打包会使用公开 `.env.example` 和独立的构建环境，复制 Nitro 输出、启动器及地址规范，并记录文件的 SHA-256。目标目录须事先不存在。

```text
node scripts/package-nuxt.mjs --out NEW_DIR
```

打包默认给 Node 构建进程分配 4096 MiB 堆上限。构建报堆内存不足时，在有足够内存的构建机上设 `NEKO_NUXT_BUILD_HEAP_MB=6144` 后重试，输出使用新的空路径。该选项只影响打包构建，运行时配置保持独立。

将刚打包的目录复制到目标机器，运行 `node scripts/package-nuxt.mjs --prepare .` 校验文件并在本机重建 Nitro 依赖链接。该命令可以重复执行，产物目录须可写。只核对清单时可运行 `node scripts/package-nuxt.mjs --verify .`。按实际依赖配置私有 `.env`，随后运行 `node scripts/run-nuxt.mjs start --dotenv .env`。旧环境变量名由同一启动器映射。运行时使用受支持的 Node.js，并提供 Oracle、Redis 及业务所需的存储等依赖。Windows 与 Linux 各自构建包，可保留对应平台的原生依赖。再分发时使用刚打包的目录，目标机器各自在所在路径准备链接。

新版 Nuxt 包填写好 `.env` 后，可在 Windows 双击 `start.cmd`，在 Linux 执行 `sh start.sh`。两种入口先校验交付文件、准备 Nitro 依赖链接，再以前台模式启动。可传入 `--dotenv PATH` 选择私有配置。

新版包内含纯结构 Oracle 基线 `data/nekotribe-schema-only.sql` 和共享迁移命令。从包根目录运行 `node scripts/migrate-db.mjs --plan` 可离线查看步骤。准备 Nitro 链接后，可用 `--check --dotenv PATH` 检查指定环境，或使用 `--apply --dotenv PATH` 显式执行增量迁移。Go、Rust 连接同一个 Oracle schema 时共用该迁移结果。从部署包执行迁移无需启动 Nuxt 服务。

## 复制预编译后端到另一台机器

在 Windows 或 Linux 上，从四工作树的父目录运行 `--build`，即可使用 PATH 中的 Go 或 Cargo 编译当前源码并打包。Go 使用锁定的模块依赖，Rust 使用 `Cargo.lock`，并从 Cargo 输出识别实际产物路径。输出目录须事先不存在，父目录须已存在。

单独取得 Go 或 Rust 工作树时，可从对应根目录将下列命令中的 `nuxt/scripts/` 改为 `scripts/`。两个工作树都包含独立启动和打包所需的脚本。修改工具后，通过 `node scripts/contracts.mjs sync --workspace-root ..` 从 Nuxt 根目录同步，再用同一入口的 `check` 检查。

```text
node nuxt/scripts/package-native.mjs go --build --out native-go-release
node nuxt/scripts/package-native.mjs rust --build --out native-rust-release
```

在 Windows 原生构建 Rust 时，使用已配置 MSVC 工具链的终端。Linux 发布包需要与目标机兼容的系统库。Rust 目标机还需要对应平台的 Oracle Instant Client。打包命令从程序头识别 Windows PE 或 Linux ELF 的 x64 和 arm64。

也可以从 Linux 或 WSL 交叉构建 Windows x64 包。将 [LLVM-MinGW 的 UCRT 工具链](https://github.com/mstorsjo/llvm-mingw/releases)的 `bin` 目录加入 `PATH`，并在 Rust 工作树运行以下命令。`+crt-static` 将 LLVM 的异常展开运行库静态链接到程序中。

```sh
rustup target add x86_64-pc-windows-gnullvm
env CARGO_BUILD_TARGET=x86_64-pc-windows-gnullvm \
  CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_LINKER=x86_64-w64-mingw32-clang \
  CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_RUSTFLAGS='-C target-feature=+crt-static' \
  CC_x86_64_pc_windows_gnullvm=x86_64-w64-mingw32-clang \
  AR_x86_64_pc_windows_gnullvm=llvm-ar \
  node scripts/package-native.mjs rust --build --out native-rust-windows-x64
```

已有编译产物时，可用 `node nuxt/scripts/package-native.mjs rust --binary PATH --out native-rust-release` 直接打包，Go 使用相同参数。

将交付目录复制到目标机器。在交付目录运行 `node package-native.mjs --verify .` 可核对 SHA-256、平台标记和必要文件。将 `env.example` 复制为私有的 `.env.go` 或 `.env.rust`，按该机器的 Oracle、Redis、媒体和模型服务填写。启动器会按包清单选择同目录二进制和配置，无需源码。它会核对包与本机 Node.js 的操作系统和架构。

```text
node start-native.mjs --check
node start-native.mjs --check-config
node start-native.mjs
```

两种后端使用相同启动命令。可追加 `--env-file PATH` 选择自定义配置，也可从其他目录调用包内启动器的绝对路径。只有手动选择其他程序时才需要完整的 `<go|rust> --binary PATH` 参数。

新版 Go 与 Rust 包也提供 Windows `start.cmd` 和 Linux `sh start.sh`，校验包内文件后以前台模式启动。可追加 `--check` 或 `--check-config` 只校验配置。路径相对于交付目录，传入绝对路径也可。旧版交付包继续使用原有 Node 命令。

`--check` 由启动器检查必填项和监听端口。`--check-config` 适用于当前源码及使用 `--build` 生成的交付包，由后端用正常的启动配置解析器校验 Oracle 参数、Redis 配置和签名设置，随后退出。两个检查都不连接数据库或 Redis，也不监听端口。直接打包的旧二进制继续使用 `--check`。从源码运行完整配置检查时，在 `start-native.mjs` 后先指定 `go` 或 `rust`。

需要一起交付音视频元数据工具时，在打包命令末尾追加 `--ffprobe PATH`。使用允许分发、与后端同一操作系统及架构的可执行文件。交付清单会校验其 SHA-256 和目标平台。启动时优先用显式配置的 `FFPROBE_PATH`，其次用随包提供的工具。普通交付会从目标机的 PATH 查找。若工具依赖动态库，目标机器还要安装这些库。复制后可运行 `ffprobe -version`，随包交付时使用包内工具的绝对路径。

通过 Windows 文件系统中转到 Linux 时，按实际程序名恢复执行权限，例如 `chmod +x ./nekotribe-rust`。Rust 程序可用 `./nekotribe-rust skills --plan` 做离线启动检查。该命令不访问 Oracle 或 Redis。

## Flutter Web 独立静态部署

在 Flutter 工作树生成 Web 静态目录，用 `scripts/package-web.mjs` 将站点及地址配置工具一起打包。复制到目标机后，将包内 `site` 交给 Windows 或 Linux 的静态站点服务。配置填写浏览器可达的后端地址及端口。使用同一个入口代理 API、实时和文件时，只需配置 API 地址。配置与发布步骤见 [Flutter Web 部署](../../flutter/README.md#web-静态部署)。

在有 Node.js 的机器上可以直接预览新版包。Windows 双击 `start.cmd`，Linux 执行 `sh start.sh`，然后打开输出的本机地址。默认端口为 30004。预览读取包内公开地址配置，后端服务仍使用配置指定的地址。Nuxt、Go、Rust 的环境模板均包含默认预览来源。使用旧环境文件或其他预览端口时，把打印的预览来源加入后端 `CORS_ALLOWED_ORIGINS`。

从四工作树的父目录运行 `node flutter/scripts/configure-web.mjs WEB_DIR --api BASE` 可配置已构建的静态目录。使用 `--check` 查看该目录的有效地址，独立文件与实时服务可分别指定。修改仅涉及发布目录的公开配置。

## 多后端共享数据与缓存

默认 `NEKO_CACHE_MODE=shared`：Nuxt 绕过 API 响应缓存和 Oracle 查询结果缓存，避免 Rust、Go 或其他服务修改共享数据库后继续读取旧缓存。Redis 连接、会话和实时消息等其他用途不因此停用。该保护会增加数据库负载，直到三后端可靠的统一失效机制完成。

## AI 模型热切换

让 Nuxt、Go、Rust 的进程通过 `AI_MODEL_CONFIG_FILE` 指向同一格式的配置文件。发布前在同一目录写入新文件，递增 `revision`，再原子替换目标。容器用只读目录挂载，并填写容器内路径。每个实例在后续生成请求中独立切换。旧模型回退也发布为新版本。[格式及生效规则](../specifications/requirements/ai-model-switching.md)

Windows 和 Linux 均可从 Nuxt 工作树用 Node.js 22 检查并发布配置。以下命令假设候选文件的版本为 2，已发布版本为 1。首次发布时将最后一个参数改为 `0`，并确保配置目录已存在。

目标机仅有 Nuxt、Go 或 Rust 预编译包时，可用 `node scripts/package-ai-model-tools.mjs --out ai-model-tools` 生成独立工具目录，再复制到部署机。目录包含模型配置样例和完整维护命令，配合 Node.js 22 可直接执行下述步骤。

```text
node --experimental-strip-types scripts/ai-model-config.mjs check candidate.json
node --experimental-strip-types scripts/ai-model-config.mjs probe candidate.json
node --experimental-strip-types scripts/ai-model-config.mjs publish candidate.json /path/to/neko-ai/model.json 1
```

`probe` 用候选配置访问真实推理端点。请在能访问这些地址且已注入所需密钥的环境执行。它检查问答从合成群帖返回正确引用、写作返回普通文本、群运营按指定检索词调用工具并续写，以及审核助手返回合规 JSON。请求只含固定测试文本和模拟工具结果，不连接 Oracle，也不写入业务数据或激活配置。输出按用途给出结果和稳定错误码。探测失败返回非零退出码。 `check` 和 `publish` 仍可离线执行。

已有生效文件时，用 `node --experimental-strip-types scripts/ai-model-config.mjs diff /path/to/neko-ai/model.json candidate.json` 离线查看四个用途实际选中的配置有哪些字段变化。命令仅输出版本、模型配置 ID 与变化字段名，支持检查配置 ID 相同但底层模型或端点已经变化的情况。确认结果后仍按 `probe` 或 `publish-checked` 验证候选。

调试个别用途时，可运行 `node --experimental-strip-types scripts/ai-model-config.mjs probe candidate.json --roles knowledge,writing`。命令按给定顺序探测所列角色。群运营使用角色名 `agent`，审核使用 `moderation`。正式发布候选仍由 `publish-checked` 探测全部四项。

有推理服务访问权限时，可用一条命令完成探测和发布。四个用途通过后才发布，并使用已探测的配置字节。探测期间当前文件的内容或版本发生变化时，命令会退出并保留当前文件。

```text
node --experimental-strip-types scripts/ai-model-config.mjs publish-checked candidate.json /path/to/neko-ai/model.json 1
```

用 `list` 查看当前版本、用途绑定和可选模型配置 ID。`bind-checked` 可一次提交一个或多个用途，所有变更用途探测通过后在同一个版本中生效。`rollback-last-checked` 恢复最近的归档，`rollback-checked` 恢复指定的较旧配置。两条命令都在四个用途通过探测后才发布。需要离线处理时可使用 `bind`、`rollback-last` 或 `rollback`。每次替换前工具都会保存当前配置到 `model.json.history`。版本参数须与各次操作前的当前版本一致。

```text
node --experimental-strip-types scripts/ai-model-config.mjs list /path/to/neko-ai/model.json
node --experimental-strip-types scripts/ai-model-config.mjs bind-checked /path/to/neko-ai/model.json 2 knowledge local-small writing local-small
node --experimental-strip-types scripts/ai-model-config.mjs rollback-checked previous.json /path/to/neko-ai/model.json 3
node --experimental-strip-types scripts/ai-model-config.mjs rollback-last-checked /path/to/neko-ai/model.json 4
```

发布后，从环境变量 `NEKO_AI_STATUS_TOKEN` 提供各实例都接受的登录访问令牌，逐个确认目标版本。下面以回退后生成的版本 5 为例。远程地址须使用 HTTPS，本机回环可用 HTTP。若有负载均衡，应使用可直接访问每个实例的地址。命令只查询加载版本，真实推理由 `probe` 或业务验收确认。

```text
node --experimental-strip-types scripts/ai-model-config.mjs verify-active 5 http://127.0.0.1:3000 http://127.0.0.1:30006 http://127.0.0.1:30003 --wait-ms 5000
```

`--wait-ms 5000` 为各实例预留最多五秒加载时间，便于在发布后立即执行确认。省略时只检查一轮。若发布进程异常退出并遗留 `model.json.lock`，确认没有在途发布后移除空锁目录，再核对当前版本。

在地址之后加 `--require-ready knowledge,writing,agent,moderation` 可以同时核对选定用途的配置状态。仅切换某些用途时，列出相应角色即可。版本已经匹配但技能关闭或缺少凭据时，结果会列出未就绪用途并以非零状态退出。该选项只读取后端状态。真实推理仍通过 `probe` 或业务验收确认。

对容器设置 `NEKO_AI_MODEL_CONFIG_DIR` 为配置目录绝对路径，目录内使用 `model.json`，并在原 Compose 命令的主文件后追加对应覆盖文件。Windows 绝对路径可用 `C:/NekoConfig/ai`，Linux 可用 `/srv/nekotribe/ai`。保留原来的环境文件和项目名参数。

| 工作树 | 主 Compose 文件 | 追加参数 |
| --- | --- | --- |
| Nuxt | `docker-compose.local.yml`、`docker-compose.external.yml` 或 `docker-compose.yml` | `-f docker-compose.ai-model.yml` |
| Go | `compose.yaml` | `-f compose.ai-model.yaml` |
| Rust | `compose.yaml` 或 `compose.native.yaml` | `-f compose.ai-model.yaml` |

首次启用覆盖时由 Compose 重建应用容器以应用挂载。随后发布同目录内的新 `model.json` 无需重建或重启。容器只能读取挂载目录，密钥继续通过各应用的私有环境配置注入。

三套后端的 V2 业务响应默认发送 `Cache-Control: private, no-store`。部署反向代理时保留此响应头，文件和静态资源沿用各自的缓存配置。

只有确认共享数据库的所有写入都经过 Nuxt 的缓存失效路径时，才可将 `NEKO_CACHE_MODE=single-backend` 用于单后端运行；启动 Rust/Go 原生写入或其他外部写入前，必须将所有 Nuxt 实例改回 `shared` 并重启。配置在进程启动时读取，旧实例不随配置变化自动切换。每次进程启动使用新的缓存标识，不能复用以前进程的响应/查询缓存；会增加 Redis 中临时缓存条目，它们按原有 TTL 过期，不删除运行数据。跨后端缓存失效和 Redis 不可用时的可靠性仍待实现与真实部署验收。

单后端缓存当前采用尽力失效：Redis 在写入时故障、提交与失效之间崩溃等情形可能保留旧条目；即使所有写入经过 Nuxt 也不构成强一致保证。有严格一致性要求时保持 shared，后续需建立可恢复的失效机制并实测。

## 本地与混合

使用 Node 22.12 以上的 Node 22、Yarn 1.22 和本项目锁文件。复制 `.env.example` 为 `.env`，填写签名密钥、数据库、Redis 及需要的 SMTP。Windows 用 `Copy-Item .env.example .env`，Linux 用 `cp .env.example .env`；已有配置不要覆盖。

```text
yarn install --frozen-lockfile
yarn dev
```

Windows 也可双击 `dev.cmd`。生产构建执行 `yarn build`，之后 `yarn start` 或双击 `start.cmd`。Linux 入口为 `sh scripts/dev.sh` 和 `sh scripts/start.sh`。应用前台输出日志，Ctrl+C 停止；重复启动遇到端口占用应停止旧进程或更换 `PORT`，入口不扫描或终止其他进程。

在开发进程中设置 `NUXT_ENABLE_DEBUG_PAGES=1` 可启用 `/test`、`/test-token-refresh` 和 `/ws` 调试页。生产构建始终排除这些页面。

`HOST`、`PORT` 控制本机监听；服务端口默认 3000。混合模式先显式启动依赖，Oracle 就绪并完成必要初始化后再启动 Node：

```text
node scripts/deploy.mjs plan --mode dependencies
node scripts/deploy.mjs up --mode dependencies
node scripts/deploy.mjs status --mode dependencies
```

这些命令本身不会初始化数据库。首次独立空库的初始化步骤见下一节；已有开发数据不要重新导入。结构检查与增量升级统一使用下述显式迁移工具，业务请求不再临时创建结构。宿主机连接使用 `ORACLE_HOST/PORT`、`REDIS_HOST/PORT`；容器服务内部使用 `DOCKER_ORACLE_HOST/PORT` 和 `DOCKER_REDIS_*`。

```text
node scripts/migrate-db.mjs --plan
node scripts/migrate-db.mjs --check --dotenv .env
node scripts/migrate-db.mjs --apply --dotenv .env
```

默认/`--plan` 只显示离线步骤，不读取凭据或加载驱动。`--check` 只查询结构；`--apply` 才增量修改并登记版本。连接必须是目标 schema 所有者，管理员需明确授予迁移所需建表/序列权限及 `EXECUTE ON SYS.DBMS_LOCK`，工具不会自动提权。已有序列不重置、已有设置不覆盖；DDL 隐式提交，失败后停止并按已完成步骤恢复，不能承诺整批事务回滚。完整设计及权限见 [schema-migrations.md](architecture/schema-migrations.md)。

升级 AI 会话标题和群组列时，在同一维护窗口使用含 `ai-conversations-title-char` 与 `ai-conversations-group-id-precision` 的 Nuxt 迁移工具和包含该迁移清单的三套后端。旧后端的迁移清单会将新增记录视为未知版本。完成 `--apply` 后先用 `--check` 核对结构，再启动新版后端。

私密附件上线顺序为先更新 Nuxt、Go、Rust 后端及迁移清单，再用显式迁移工具应用 T19，最后发布 Nuxt Web 和 Flutter 客户端。私密上传使用 `/api/v2/media/private`。网关把专用入口交给当前 API 上游，保留与公开上传相同的 528 MiB 请求上限。连接旧后端时，客户端收到失败后保留草稿。私密下载请求 `/api/v2/media/{id}/content` 由当前 API 上游鉴权，`/storage/` 继续提供公开媒体。共用 S3 时，`private/chat/` 和 `private/post/` 只能由应用凭据读写，并限制公开桶策略和 CDN 路径。升级前的公开附件保留原地址。[附件契约](../specifications/requirements/storage-local-files.md)

## 完整源码容器栈

所有命令均从 Nuxt 根目录执行。`plan` 只读取所选配置并显示计划，不调用 Docker，不打印私密环境变量；其余动作才执行 Docker。支持 `--env <文件>`、`--project <实例名>`，不要同时用另一组实例名管理同一数据。

```text
node scripts/deploy.mjs plan --mode source
node scripts/deploy.mjs up --mode dependencies
node scripts/deploy.mjs logs --mode dependencies
```

等待 Oracle 健康后，仅在确认目标是独立空开发/测试库且接受现有开发基线时执行：

```text
node scripts/deploy.mjs init-db --mode source
node scripts/deploy.mjs migrate-db --mode source
node scripts/deploy.mjs up --mode source
node scripts/deploy.mjs status --mode source
node scripts/deploy.mjs logs --mode source
node scripts/deploy.mjs stop --mode source
```

`init-db` 是单独的显式动作，通过 `run --rm -e DB_INIT_ALLOW_EMPTY=true db-init` 进入现有保护逻辑；普通 `up` 不传此开关。已有 `N_USERS` 会跳过基线，残留/部分初始化会拒绝执行。`migrate-db` 使用一次性 app 容器执行增量迁移，`--no-deps` 不自动启动应用依赖；先确保 Oracle 已就绪且迁移权限已明确授予。它不会执行整份基线。基线固定开发 schema、账号和表空间路径，不是任意生产库的通用迁移器。完整规则见 [startup-safety.md](startup-safety.md)。

未安装 Node 的 Docker 主机也可使用对应命令：

```text
docker compose --env-file .env -p nekotribe -f docker-compose.local.yml up -d redis oracle19c
docker compose --env-file .env -p nekotribe -f docker-compose.local.yml run --rm -e DB_INIT_ALLOW_EMPTY=true db-init
docker compose --env-file .env -p nekotribe -f docker-compose.local.yml run --rm --no-deps --build --entrypoint node app scripts/migrate-db.mjs --apply
docker compose --env-file .env -p nekotribe -f docker-compose.local.yml up -d --build
```

修改私有 env 路径时，直接 Compose 还需设置 `ENV_FILE` 为同一文件，因为 Compose 插值文件与服务 `env_file` 是两个入口；Node helper 会统一二者。发布镜像使用 `--mode image`，本轮本地源码修复应选择 `source`。`stop` 保留容器和卷，不执行 `down -v`。

Nuxt Web 的三种 Compose 入口都读取 `NUXT_PUBLIC_API_BASE`、`NUXT_PUBLIC_WS_URL` 和 `NUXT_PUBLIC_STORAGE_BASE`。共用后端入口时填写客户端可访问的 API 基址即可，实时和媒体地址自动派生。分开部署时分别配置完整的 WS 地址及 HTTP(S) 媒体基址。使用旧变量 `DOCKER_PUBLIC_WS_URL` 的部署，只有 `NUXT_PUBLIC_WS_URL` 为空时才读取旧值。

在本地启动环境或 Compose 的变量文件中可设置 `NUXT_API_SERVER_BASE`，让 Nuxt 服务端渲染直接访问当前后端。例如 Nuxt 和 Go 都在宿主机运行时可用 `http://127.0.0.1:30006`，两个容器共享网络时可用 `http://go:8080`。Nuxt 三种 Compose 入口在未定义此变量时优先读取同一环境文件中的 `API_BACKEND_UPSTREAM`。显式空值可恢复使用公开基址。

数据卷自动按 Compose 实例名分隔；已去掉固定 `container_name`，不同实例仍需配置不同宿主端口与上传目录。本机迁移保留的 `.env` 使用 `COMPOSE_PROJECT_NAME=nekotribe`、`ORACLE_DATA_VOLUME=../data/oracle-data`、`STORAGE_ROOT_DIR=../storage`；新机器不要照抄旧数据路径。`SENTIMENTFLOW_MODELS_HOST_DIR` 控制可选模型挂载，迁移机器的旧目录为 `../sentimentflow-models`。

平台已退役旧情感分析。普通 Compose 启动不会启动 SentimentFlow，即使沿用旧 `.env` 中的 `SENTIMENTFLOW_ENABLED=true` 和 `COMPOSE_PROFILES=true`。独立使用时可运行 `docker compose --profile sentimentflow-legacy up -d sentimentflow sentimentflow-frontend`。源码构建可追加 `-f docker-compose.local.yml` 作为主配置。原有模型挂载保留。新知识问答和写作使用各后端的模型推理配置。

## 新 Oracle 库只创建应用结构

为新环境部署 Oracle 19c 时，先让管理员在目标 PDB 创建空 schema 所有者，分配默认表空间及配额。所有者需要登录权限，以及创建表、序列、过程、触发器、视图和物化视图的直接权限。应用进程连接指定的所有者 schema，共用同一份初始化和迁移结果。

本机 SQL*Plus 在 PATH 中时，可从 Nuxt 源码或新版独立包根目录执行。把目标 owner 的 `ORACLE_USER`、`ORACLE_PASSWORD`、`ORACLE_HOST`、`ORACLE_PORT` 和 `ORACLE_SERVICE_NAME` 写入目标私有配置。确认目标为空后，为初始化显式设置 `DB_INIT_ALLOW_EMPTY=true`。

```text
node scripts/init-db.mjs --schema-only --dotenv .env.external
```

也可在新 SQL*Plus 会话交互运行。下面的 `CONNECT` 会请求密码。从 Nuxt 源码或新版独立包的根目录启动 SQL*Plus，也可将 `@` 后的路径改成基线文件绝对路径。

```text
sqlplus -L /nolog
CONNECT neko_app@//db.example.com:1521/ORCLPDB1
@data/nekotribe-schema-only.sql
```

脚本创建表、序列、索引、触发器、存储程序、普通视图和物化视图。所有者使用自己的默认表空间，初始化前后都有结构检查。该基线供预先建立的空 schema 使用，且不会导入历史账号、帖子、会话或上传记录。DDL 途中失败时，先检查目标 schema 和 `USER_ERRORS`。Oracle 已提交的 DDL 需由管理员处理。现有开发库沿用增量迁移。

随后从 Nuxt 源码或 Nuxt Node 交付包，明确指定目标私有配置文件检查并应用增量迁移。迁移建立当前功能扩展及默认审核设置。连接该 schema 的 Go 和 Rust 共享迁移结果。

```text
node scripts/migrate-db.mjs --plan
node scripts/migrate-db.mjs --check --dotenv .env.external
node scripts/migrate-db.mjs --apply --dotenv .env.external
node scripts/migrate-db.mjs --check --dotenv .env.external
```

### vNext 隔离迁移

本轮 `--plan` 输出 19 组共 64 项步骤，历史基线的 41 个步骤校验和保持一致。计划可在断开 Oracle 时生成。实际执行前，由操作员确认目标为隔离 PDB 内的测试 schema，核对备份、恢复路径、迁移权限和私有环境文件。当前进程环境优先于文件，`NUXT_ORACLE_*` 优先于对应旧名。

在隔离库运行上述 `--check` 获取初始结构。存在待迁移项时命令可能返回非零。操作员检查差异来源并确认目标后执行 `--apply`，再运行 `--check`，保存各步恢复就绪的回执。DDL 可能自动提交。遇到连接、锁、校验和或结构冲突时，按已确认的备份和恢复流程处理。库就绪后再启动连接同一 schema 的三套后端。三后端业务对拍使用三份同源克隆，每份分别迁移。

新环境的审核员使用普通注册流程建立受控账号。账号确认已启用后，在 Nuxt、Go、Rust 的私有配置中填写同一份 `MODERATION_ADMIN_ACCOUNTS`，可用逗号分隔用户名或邮箱。配置变更后重启对应后端。样例名单为空，审核队列和 AI 审核助手均须授权。使用早期部署的预置账号时，也将其显式加入名单。测试开关 `MODERATION_ALLOW_ALL` 在正式部署保持 `false`。

## 外部数据库 / 分机

复制并修改一份私有配置，例如 `.env.external`。设置容器能访问的 `ORACLE_HOST`、`ORACLE_PORT`、服务名、schema 凭据及 `REDIS_URL` 或 `REDIS_HOST/PORT`；宿主机依赖可用 `host.docker.internal`，远程依赖使用真实主机名/IP。应用容器中的 `localhost` 指向它自己。明确填写 `NUXT_*` 时优先于对应旧名，包括显式空值。

```text
node scripts/deploy.mjs plan --mode external --env .env.external --project nekotribe-external
node scripts/deploy.mjs up --mode external --env .env.external --project nekotribe-external
```

此文件仅定义 app，没有数据库、Redis、db-init 或依赖自动替代服务；整库初始化动作在该模式被拒绝。已有外部 schema 如需兼容升级，只能在管理员确认目标、备份和授权后显式执行 `migrate-db --mode external --env .env.external --project nekotribe-external`；普通启动不会执行迁移。文件存储挂载到独立明确的 `STORAGE_ROOT_DIR`；分机后给 `BASE_URL` 或 `STORAGE_CDN_BASE_URL` 设置浏览器可访问地址。发布地址默认 loopback；需要其他机器访问时设置 `APP_BIND_ADDRESS=0.0.0.0`，并安排目标机网络和 TLS 入口。数据库和 Redis 默认仅发布 loopback，分机依赖的网络策略由对应主机管理。

## 独立 Go、Rust 后端容器

在各自工作树复制 `env.example` 为私有配置文件，并填写该环境的 Oracle、Redis、签名密钥及模型设置。两个入口均启动原生后端，Nuxt 可独立部署。

| 工作树 | 私有配置 | 启动命令 | 默认宿主机地址 |
| --- | --- | --- | --- |
| Go | `.env.go` | `docker compose up -d --build` | `http://127.0.0.1:30006` |
| Rust | `.env.rust` | `docker compose up -d --build` | `http://127.0.0.1:30003` |

Rust 的旧 Nuxt 代理仍可通过 `docker compose -f compose.compat.yaml up -d --build` 显式启动。原生进程使用 `RUST_BACKEND_PORT` 优先于 `PORT`，默认 30003。启动器会将选中的端口传给进程，方便 Nuxt Web 与 Flutter 使用同一可预期的入口。

Oracle 和 Redis 使用容器可达的地址。本机依赖使用 `host.docker.internal`，分机依赖使用相应的 DNS 名称。通过 Compose 插值环境设置 `GO_PUBLISH_HOST`、`GO_PUBLISH_PORT`、`RUST_PUBLISH_HOST` 或 `RUST_PUBLISH_PORT`。配置自定义应用环境文件时使用 `GO_APP_ENV_FILE` 或 `RUST_APP_ENV_FILE`。前端 API 和 WebSocket 地址使用从客户端可访问的后端地址。跨来源访问时配置后端的 `CORS_ALLOWED_ORIGINS`。

共用本地媒体时，通过 `NEKO_STORAGE_SOURCE` 挂载同一宿主机目录。跨机时可将三套后端的 `STORAGE_TYPE` 设为 `s3` 并配置同一存储桶及对象命名空间。已有本地媒体先使用迁移工具复制并校验。三套源码镜像都包含 `ffprobe`。若自定义 `FFPROBE_PATH`，该路径必须在容器内可访问。Rust 镜像在构建时检查 Oracle Linux `ffmpeg-free` 包提供的 `ffprobe` 可执行。[迁移工具](../specifications/requirements/media-upload.md) · [Oracle 软件包文件清单](https://yum.oracle.com/repowatch/oraclelinux9.x86_64/ol9_developer_EPEL/c4acc9e71a252f7020a01f743b2884c83cce2f7c8784aa7e15b31c2ca437e8e2?display=filelist)

## 复制容器镜像到另一台机器

目标机器已有 Docker、Oracle 和 Redis 时，可在一台构建机生成应用镜像，再把镜像文件和对应 Compose 配置交给目标机器。使用与目标架构匹配的镜像。签名密钥、数据库地址和账号由目标机器的私有配置提供。媒体对象通过共享存储或另行迁移交付。

| 应用 | Compose 入口 | 私有变量文件 | 镜像变量示例 | 服务 |
| --- | --- | --- | --- | --- |
| Nuxt | `docker-compose.external.yml` | `.env.external` | `NUXT_IMAGE=nekotribe:release-1` | `app` |
| Go | `compose.yaml` | `.env.go` | `GO_APP_IMAGE=nekotribe-go:release-1` | `go` |
| Rust | `compose.yaml` | `.env.rust` | `RUST_APP_IMAGE=nekotribe-rust:release-1` | `rust` |

从对应工作树运行下列命令。以 Nuxt 为例，在 `.env.external` 中设置 `ENV_FILE=./.env.external` 及表中镜像变量。指定 Go、Rust 时替换文件、服务及镜像名。

```text
docker compose --env-file .env.external -f docker-compose.external.yml build app
docker image save --output nekotribe-release-1.tar nekotribe:release-1
```

在目标机器加载镜像，再使用同一标签启动应用。Rust 的默认 Compose 文件引用 `compose.native.yaml`，复制配置时一并带上。

```text
docker image load --input nekotribe-release-1.tar
docker compose --env-file .env.external -f docker-compose.external.yml up -d --no-build --pull never app
```

在线发布可把私有变量文件中的标签换成仓库里的版本标签或摘要，并以 `--no-build --pull always` 启动。Nuxt 的 `docker-compose.yml` 默认拉取官方镜像，也可通过 `NUXT_IMAGE` 选用其他镜像，通过 `NUXT_IMAGE_PULL_POLICY` 指定取用策略。使用带 Oracle、Redis 等依赖的完整栈离线启动时，目标机还需预先准备相应依赖镜像。

## 独立公开知识索引

将 `node scripts/package-knowledge-index.mjs --out knowledge-index-release` 生成的目录复制到 Windows 或 Linux 主机，可以独立运行更新与检索。部署机需有 Node.js 22，并可访问 Oracle、Qdrant 和向量端点。包内 README 提供两份环境文件示例及首次构建、持续更新、检索和状态检查命令。两个进程使用同一个激活配置路径。

同一工具包也包含共享 Skill 启用配置的维护入口。用包内独立的 `.env.maintenance.example` 准备连接配置，维护时只需访问目标 Oracle。[Skill 维护命令](ai-skill-maintenance.md)

### 独立知识索引容器

在 Nuxt 工作树复制 `.env.knowledge-index.example` 为私有 `.env.knowledge-index`，配置 Qdrant、profile 引用的向量端点密钥以及 `AI_INDEX_SERVICE_TOKEN`。将检索容器与一个索引更新进程指向同一 profile 目录。

#### 宿主机更新，容器检索

将 `AI_INDEX_ACTIVE_PROFILE` 设到 `.knowledge-index/active.json`。在能连接 Oracle 的 Windows 或 Linux 环境中运行 `node scripts/knowledge-index/cli.mjs bootstrap .knowledge-index/initial.json` 完成首次构建和激活，再用 `node scripts/knowledge-index/cli.mjs watch` 持续同步。

检索服务可在首次构建期间启动。只要宿主机与检索容器使用同一个激活目录，初次激活会自动生效，健康检查在此之前返回未就绪。

首次构建前可运行 `node scripts/knowledge-index/cli.mjs check-sources`，在独立包中使用 `node --env-file=.env.updater index.mjs check-sources`。它通过 Oracle 只读事务检查普通帖、评论、公开群帖、群评论和规则目录。各表的读取权限见 [知识索引规范](../specifications/requirements/ai-knowledge-index.md)。

新建候选集合时构建器会先执行该检查。看到 `ORACLE_SOURCES_NOT_READY` 时，运行 `check-sources` 查看具体失败来源，再检查目标 schema 的结构、授权或规则目录。

```text
docker compose -f docker-compose.knowledge-index.yml up -d --build
```

#### 容器更新和检索

复制 `.env.knowledge-index-updater.example` 为私有 `.env.knowledge-index-updater`，填入 Oracle 只读帐号、具备集合写权限的 Qdrant 凭据和向量端点密钥。更新容器使用 `index-update` profile，Oracle、Qdrant 和向量端点都要能从该容器连接。主机上的依赖可使用 `host.docker.internal` 和依赖端口，远程依赖使用内网地址。

首次部署时按索引规范创建配置，将文件保存为 `.knowledge-index/initial.json`，确保目录允许容器写入，并给配置选一个新的集合名。先构建并激活，再启动定时更新。已有激活文件和有效集合的部署可以直接运行最后一条命令。

```text
docker compose -f docker-compose.knowledge-index.yml --profile index-update run --rm --build knowledge-index-updater check-sources
docker compose -f docker-compose.knowledge-index.yml --profile index-update run --rm --build knowledge-index-updater bootstrap /app/profiles/initial.json
docker compose -f docker-compose.knowledge-index.yml --profile index-update up -d --build
```

`bootstrap` 可在已有激活配置的目录中重跑。它会核对集合标记和精确点数，返回 `INDEX_INCOMPLETE` 时通过同步或显式发布恢复。首次构建中断且留下未完成集合时，排查配置后在 `initial.json` 中换一个集合名再运行。

已有索引切换向量模型时，为新模型配置新的修订号和集合名，将候选文件放在同一配置目录。源码可用 `node scripts/knowledge-index/cli.mjs switch .knowledge-index/next.json`。独立包可用 `node --env-file=.env.updater index.mjs switch profiles/next.json`。容器更新模式的命令如下。

```text
docker compose -f docker-compose.knowledge-index.yml --profile index-update run --rm --build knowledge-index-updater switch /app/profiles/next.json
```

旧索引在构建期间继续处理请求。若自动同步或其他操作先发布了配置，命令返回 `ACTIVE_PROFILE_CHANGED`。核对当前配置后可重试，已完成的候选需重新通过校验才会激活。

如果需要先检查候选集合，可在源码运行 `node scripts/knowledge-index/cli.mjs verify .knowledge-index/next.json`，或在独立包运行 `node --env-file=.env.retrieval index.mjs verify profiles/next.json`。省略文件参数检查当前激活索引。该命令需要模型和 Qdrant 只读访问，输出已校验的向量点数，激活配置无需改动。

每个激活目录运行一个 `watch` 进程。更新容器无发布端口。检索容器使用只读挂载，读取同步后的 `active.json`。两种部署均支持通过 `AI_INDEX_PROFILE_DIR` 指定共享目录。Oracle 密码和 Qdrant 写权限留在更新进程。更新容器的配置文件可通过 `AI_INDEX_UPDATER_ENV_FILE` 指定。Qdrant 明确报告激活集合不存在时，更新进程会重建并激活索引，也可通过更新容器执行 `sync`。

检索容器通过 `node index/cli.mjs health` 报告激活索引是否就绪。宿主机部署可在与检索进程相同的地址、端口和令牌配置下运行 `node scripts/knowledge-index/cli.mjs health`。本地配置和激活文件有效时，即使 Qdrant 尚未就绪，检索进程也会开始监听。探针核对索引集合的完工标记和精确点数，检查失败返回非零退出码。索引恢复后，探针和查询可在同一进程内恢复。实际查询还会检查向量模型。

查看自动更新进度时，宿主机在更新进程相同的 `AI_INDEX_ACTIVE_PROFILE` 下运行 `node scripts/knowledge-index/cli.mjs watch-status`。容器更新时运行 `docker compose -f docker-compose.knowledge-index.yml --profile index-update exec knowledge-index-updater node scripts/knowledge-index/cli.mjs watch-status`。输出包含最近一次结果、上次成功时间和计划中的下次检查时间。异常退出可能留下旧状态，可将 `updatedAt` 与容器或进程状态一起核对。

设置各业务后端的 `AI_KNOWLEDGE_INDEX_URL` 和相同的 `AI_INDEX_SERVICE_TOKEN`。宿主机后端可以使用默认 `http://127.0.0.1:3818`。同一 Compose 网络使用 `http://knowledge-index:3818`。其他容器或远程主机须配置可访问的内部地址和相应的 `AI_INDEX_PUBLISH_HOST`，并将索引端口限制在业务内网。向量端点及 Qdrant 地址也须从索引容器可达。[索引规范](../specifications/requirements/ai-knowledge-index.md)

#### 群知识索引

在检索和更新进程的环境文件中配置同一个独立的 `AI_INDEX_GROUP_ACTIVE_PROFILE`。容器部署可使用已挂载的 `/app/profiles/group-active.json`。群索引点包含私密群资料，向量端点和 Qdrant 应使用受控的内部服务。

每次重建使用包含 `"scope": "group"` 的配置文件和全新的 `neko_group_knowledge_*` 集合名，并运行 `node scripts/knowledge-index/cli.mjs rebuild-group <profile.json>`。校验通过后，检索进程会读取新的激活配置。群索引按需重建，旧群集合由运维管理。群索引未配置或不可用时，后端使用同一群范围的 Oracle 检索。个人收藏与帖子由业务后端实时查询 Oracle。[范围契约](../specifications/requirements/ai-knowledge-scope.md)

#### 可选图文模型和 SentimentFlow

图片描述使用声明 `vision` 的写作模型。审核模型具备 `vision` 时，审核建议可纳入已授权的公开图片。模型通过现有 OpenAI-compatible 或 Ollama 地址接收图片。图片从该后端配置的本地或 S3 兼容存储读取。[图文 AI 契约](../specifications/requirements/ai-vision.md)

三个后端使用同名的 `AI_SENTIMENTFLOW_ENABLED` 和 `AI_SENTIMENTFLOW_URL`。设置 `AI_SENTIMENTFLOW_ENABLED=1` 后，将 URL 指向可达的内部预测地址，例如 `http://sentimentflow:8000/predict/`。按部署情况提供该服务的 `AI_SENTIMENTFLOW_TOKEN`。独立服务可继续通过原部署入口运行，常规应用启动保持插件关闭。代理不可达、超时或熔断时，群草稿与审核队列自动恢复为基础功能。[只读协同契约](../specifications/requirements/ai-sentiment.md)

#### 个人 AI 服务连接

完成显式 Oracle 迁移后，从部署密钥管理器向三个应用后端提供相同的 `AI_USER_PROVIDER_SECRET_B64`，值为标准 base64 编码的 32 字节加密密钥。备份此值可保留已有连接。管理员可以设置 `AI_USER_PROVIDER_URL` 提供第二个 OpenAI-compatible 写作地址。替换地址或加密密钥后，现有用户可在账户设置重新提交自己的 API 密钥。[个人连接契约](../specifications/requirements/ai-user-provider.md)

#### 同一 Docker 主机上的私有检索网络

独立 Compose 项目可通过同一个专用桥接网络连接检索服务。先在目标机器上创建一次网络，然后在 Nuxt 工作树使用附加文件启动。已有的更新进程可继续使用原部署方式。私有检索容器通过容器网络接受请求，宿主机不发布检索端口。

```text
docker network create nekotribe-knowledge
docker compose -p nekotribe-knowledge -f docker-compose.knowledge-index.yml -f docker-compose.knowledge-index-private.yml up -d --build
```

在业务后端自己的私有环境文件中设置与检索服务相同的 `AI_INDEX_SERVICE_TOKEN`，可选设置 `AI_KNOWLEDGE_INDEX_FALLBACK=lexical`。然后在对应工作树运行需要的命令。以下 Nuxt 示例使用外置 Oracle 和 Redis。也可沿用原项目名和 `docker-compose.yml` 或 `docker-compose.local.yml`，并追加同一个客户端附加文件。

```text
docker compose -f docker-compose.external.yml -f docker-compose.knowledge-client.yml up -d --build
docker compose -f compose.yaml -f compose.knowledge-client.yaml up -d --build
```

第二条命令适用于 Go 或 Rust 工作树。附加文件给后端设置 `http://knowledge-index:3818` 并保留原来的依赖网络。若同一机器上运行隔离测试，为测试环境另建网络，并用 `NEKO_KNOWLEDGE_NETWORK` 为检索和业务 Compose 指定同一个测试网络名。不同 Docker 主机之间仍通过可路由的内网地址连接。

## 同一个公共入口切换 Nuxt、Go、Rust

可选 `docker-compose.gateway.yml` 运行 Nginx 网关。`UI_NUXT_UPSTREAM` 指向 Nuxt 页面服务。切换到 Go 或 Rust 原生后端时设置 `API_BACKEND_UPSTREAM`，实时和公开媒体默认跟随。API 上游省略时使用 Nuxt 页面上游。独立实时服务用 `WS_BACKEND_UPSTREAM`，独立公开媒体服务用 `MEDIA_BACKEND_UPSTREAM`。公开媒体上游应接受网关传递的公共 Host。网关转发 `/storage/` 时去掉 Cookie 和 Authorization。宿主机默认映射端口为 Nuxt 30001、Go 30006、Rust 30003。

部署新的双因素受信设备凭据时，同一共享库的三种后端应在同一维护窗口升级。浏览器使用同一公开站点的 HTTPS API 地址，后端设置 `COOKIE_SECURE=true`。首次使用新版时，旧设备重新完成一次双因素验证即可重新记住设备。

Linux 上若网关通过 `host.docker.internal` 连接其他 Compose 项目，应用端口要绑定网关能访问的宿主机地址。可将相应应用的发布地址设为 Docker 网桥可达的宿主机 IP，并仅允许网关所在网络访问。默认 `127.0.0.1` 适用于从宿主机直连的场景。知识索引供其他容器通过宿主机访问时也采用相同配置方式。

```text
docker compose --env-file .env -p nekotribe-gateway -f docker-compose.gateway.yml up -d
```

默认公共地址为 `http://localhost:30005`，可配置 `GATEWAY_PORT` 和 `GATEWAY_BIND_ADDRESS`。网关分别转发 API 和公开媒体路径、`/_ws`、Nuxt 页面和旧 `/upload/` 路径。Nuxt Web 的 `NUXT_PUBLIC_API_BASE`、`NUXT_PUBLIC_WS_URL`、`NUXT_PUBLIC_STORAGE_BASE` 留空即可同源。Flutter 的 API、WebSocket 和存储地址均指向同一公共入口。

用同一个 `--env-file` 启动 Nuxt Compose 和网关。让 `NUXT_API_SERVER_BASE` 保持未定义，并设置 `API_BACKEND_UPSTREAM` 为两个容器都能访问的地址，例如 `http://host.docker.internal:30006`（Go）或 `http://host.docker.internal:30003`（Rust）。切换后端后使用各自原来的 Compose 命令运行 `up -d`，使 Nuxt app 和 gateway 一并重新创建并读取新地址。Nuxt 进程直接在宿主机运行时，在其启动环境里设置对应的 `NUXT_API_SERVER_BASE`。

`POST /api/v2/media` 由网关流式转发到 API 上游，请求体上限为 528 MiB，为 500 MiB 文件、文本字段和 multipart 封装留出空间。业务文件限制由各后端执行。Go 在鉴权和媒体类型检查通过后，为上传设置 15 分钟读取时限，另留 6 分钟响应宽限。独立 TLS 入口或额外反代也需允许该请求体大小。[Nginx 请求体大小](https://nginx.org/en/docs/http/ngx_http_core_module.html#client_max_body_size) · [Nginx 上传转发](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_request_buffering)

网关自身提供 HTTP。公网 HTTPS 应配置独立 TLS 终结层，并在各后端设置 `COOKIE_SECURE=true` 及相同的公共 `BASE_URL`，例如 `https://neko.example`。`/_ws` 握手用该地址校验 HTTPS 同源请求。若使用跨来源直连，仍须配置 `CORS_ALLOWED_ORIGINS`。[两前端的运行地址](../doc/runtime-addresses.md)

Nginx 模板替换三个上游环境变量并保留 Nginx 自身变量。WebSocket 显式传递 Upgrade/Connection 并增加超时。访问日志和 WebSocket 路由错误日志关闭，避免记录查询 token。[官方模板入口](https://github.com/nginx/docker-nginx/blob/master/entrypoint/20-envsubst-on-templates.sh) [WebSocket 代理文档](https://nginx.org/en/docs/http/websocket.html)

vNext 六组验收在同一隔离 HTTPS 公共入口依次切换根页面及业务上游。页面选择 Nuxt Web 或 Flutter Web，业务上游分别选择 Nuxt、Go、Rust。切换 API 时同步核对 `/api/v2/`、`/_ws` 与 `/storage/` 的指向。Flutter vNext 便携包以 `/` 构建，按组合独立托管其 `site/`。同一站点若需同时托管两端，Flutter 需要单独构建子路径版本并配置对应 SPA 回退。状态及六组记录表见 [隔离验收清单](../../docs/deployment/ACCEPTANCE-VNEXT-20261122.md#公共-https-入口与六组客户端)。

## 一对一语音和视频通话

通话使用现有 `/_ws` 和 Redis。部署多套 API 时，为参与联调的 Nuxt、Go、Rust 实例提供同一个 Redis 及一致的 ICE 配置。浏览器通过 HTTPS 连接应用并取得麦克风和相机权限。

| 后端环境变量 | 用途 |
| --- | --- |
| `WEBRTC_STUN_URLS` | 逗号分隔的 STUN 地址，例如 `stun:stun.example.org:3478` |
| `WEBRTC_TURN_URLS` | 逗号分隔的中继地址，例如 `turns:turn.example.org:5349?transport=tcp` |
| `WEBRTC_TURN_SHARED_SECRET` | 部署密钥管理器提供的 coturn `static-auth-secret`，coturn 开启 `use-auth-secret` |

Nuxt 使用 Compose 时，在主文件后追加 `-f docker-compose.webrtc.yml` 传入这三项。Go 与 Rust 的容器从各自的 `GO_APP_ENV_FILE` 或 `RUST_APP_ENV_FILE` 读取。客户端通过登录后的 `GET /api/v2/calls/ice-servers` 获取 ICE 服务器和临时中继凭据。后端与 coturn 使用同一个中继密钥。没有 TURN 配置时，两端依赖直连和已配置的 STUN。发布前在隔离环境分别验证同网段直连、跨网段 TURN 中继，以及浏览器和 Flutter 设备的媒体权限。[通话契约](../specifications/requirements/webrtc-calls.md) · [coturn 配置](https://github.com/coturn/coturn/blob/master/man/man1/turnserver.1)

客户端直接访问部署配置中的 TURN 域名和端口。按 coturn 配置开放控制连接及中继端口范围，`turns` 使用客户端信任的证书。公共 HTTPS 网关转发 `/_ws` 信令。跨网段验收记录实测的 ICE 候选类型和双向音视频。

## Passkey 与 GitHub 登录

- Passkey 为参与同一入口切换的后端配置相同 `WEBAUTHN_RP_ID` 和 `WEBAUTHN_ORIGINS`。RP ID 填域名，来源为逗号分隔的精确 HTTPS origin，例如 `https://neko-stage.example.com`。开发用 HTTP localhost 需显式加入。先完成新增 Oracle 结构迁移。新挑战与验证走同类后端，完成后再切换上游，以便核验同一 RP 下的凭据互通。[Passkey 契约](../specifications/requirements/passkey-auth.md)
- Flutter Windows Hello 需要 `https://<WEBAUTHN_RP_ID>` 来源和匹配该域或其子域的 HTTPS API 地址。Android 需将已签名应用与 RP 域的 `/.well-known/assetlinks.json` 关联，并将 APK 签名来源加入 `WEBAUTHN_ORIGINS`。[Flutter 平台配置](../../flutter/README.md#passkey)
- GitHub 登录在三后端配置 `GITHUB_OAUTH_CLIENT_ID`、`GITHUB_OAUTH_CLIENT_SECRET` 和 `GITHUB_OAUTH_REDIRECT_URI`。在测试 GitHub OAuth 应用登记完整回调 `https://neko-stage.example.com/api/v2/auth/oauth/github/callback`，环境配置和公共入口须与登记精确匹配。将回调转发到当前 API 后端，再由发起客户端完成授权。账号先在安全页绑定，再使用 GitHub 登录。密钥由后端私有配置注入。[GitHub 登录契约](../specifications/requirements/github-oauth.md)

## 可观测性与入口日志

私有抓取端点使用 `METRICS_TOKEN` 启用。Prometheus 通过 `authorization.credentials_file` 和私有 HTTPS 对各进程的 `GET /metrics` 抓取。公共根入口的 `/metrics` 直接返回 404。记录 `X-Request-Id` 以对应客户端请求、后端日志和 `ai.run` 审计。部署负载均衡或多层反代时，各层对 `/api/v2/links/preview` 与 `/api/v2/auth/oauth/github/callback` 仅记录方法、路径、状态和耗时等脱敏字段。Nginx 访问日志使用 `$uri`；错误和调试日志也须避开原始查询、请求头和正文。保留现有 WebSocket 日志脱敏规则。[Prometheus 与 Grafana 部署](../../docs/observability/README.md) · [观测契约](../specifications/requirements/observability.md)

## 隔离测试资源

`.env.test.example` 是独立完整测试栈的样例。复制为 `.env.test` 后生成独立测试签名密钥，确认端口和路径，再通过 `--env .env.test --project nekotribe-test` 管理测试实例。其 Oracle/Redis 使用新实例和新命名卷，上传位于 `.test-data/storage`，不使用原 `../data/oracle-data` 或 `../storage`。

先 `up --mode dependencies`，再只针对新空测试库显式 `init-db`，授权后 `migrate-db`，最后 `up --mode source`；每一步都传同一组 `--env .env.test --project nekotribe-test`。宿主机迁移使用 `node scripts/migrate-db.mjs --apply --dotenv .env.test`。不要把测试文件配到日常实例名；不同端口不等于数据隔离。外部测试环境必须额外确认数据库/schema、Redis 资源和上传目录均隔离，helper 不把任意外部资源声明为安全测试目标。

### 三后端对拍及压测

从当前 Nuxt 源码根目录执行。先按 [对拍工具说明](../scripts/benchmark/README.md) 复制配置样例，使用同一测试快照、三份 Oracle 克隆及相同的上游模型桩。对拍连接已启动的后端和只读 Oracle 账号。压测用配置指定的已构建程序逐一启动后端，测到 `/api/ready` 就绪后再运行负载。选择模式前确认环境并恢复快照。

```text
node scripts/benchmark/run.mjs parity --config path/to/backend-comparison.json --out .bench/parity
node scripts/benchmark/run.mjs benchmark --config path/to/backend-comparison.json --out .bench/benchmark
```

对拍覆盖会话轮换和发帖、点赞幂等两个共享用例。压测记录七类工作负载的吞吐、P50/P95/P99、错误和样本数，以及启动时长与采样峰值 RSS。保留 JSON 和 Markdown 结果。夹具测试与命令可运行性已有离线记录，真实隔离端点的对拍与压测仍待执行。

## 最后验收范围

待集中验收的范围包括清洁克隆构建、Nuxt/Go/Rust 与知识索引镜像构建及健康检查、业务与共享数据验证、重建后数据保留、Flutter Web 登录刷新退出及文件和实时流程、公共入口切换后端，以及在另一台 Windows 或 Linux 机器上部署。Windows Flutter 桌面构建等待 C++ 工具链。

vNext Windows Flutter 构建预检仍缺 MSVC、Windows SDK 和 Inno Setup。Android Flutter 仍缺 SDK Platform 35、36 与完整的 NDK `28.2.13676358`。验收主矩阵使用 Nuxt Web 与 Flutter Web，原生包及远端实际运行状态另行登记。[vNext 验收清单](../../docs/deployment/ACCEPTANCE-VNEXT-20261122.md)
