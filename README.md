# NekoTribe

[![最新 Release](https://img.shields.io/github/v/release/Cthaat/NekoTribe?label=Release)](https://github.com/Cthaat/NekoTribe/releases/latest)
[![Nuxt CI](https://github.com/Cthaat/NekoTribe/actions/workflows/ci-nuxt.yml/badge.svg?branch=master)](https://github.com/Cthaat/NekoTribe/actions/workflows/ci-nuxt.yml)
[![Docker 镜像](https://img.shields.io/badge/GHCR-nuxt-2496ED?logo=docker&logoColor=white)](https://github.com/Cthaat/NekoTribe/pkgs/container/nekotribe-nuxt)
[![Nuxt 4](https://img.shields.io/badge/Nuxt-4-00DC82?logo=nuxt&logoColor=white)](https://nuxt.com/)

NekoTribe 是可自托管的社区平台，提供社交动态、群组、实时聊天、内容审核和 AI 助手。

| 分支 | 组件 | 适用场景 | Release 主包 |
| --- | --- | --- | --- |
| [`master`](https://github.com/Cthaat/NekoTribe/tree/master)（当前分支） | Nuxt 4 全栈 | 一次部署社区 Web、API 和实时服务，或单独作为 Web 界面 | `NekoTribe-<version>-nuxt.zip` |
| [`codex/go`](https://github.com/Cthaat/NekoTribe/tree/codex/go) | Go 原生后端 | 复用已有 Oracle / Redis，以纯 Go 二进制或容器提供 API | `NekoTribe-<version>-go.zip` |
| [`Rust`](https://github.com/Cthaat/NekoTribe/tree/Rust) | Rust 原生后端 | 复用已有 Oracle / Redis，以 Rust 二进制或容器提供 API | `NekoTribe-<version>-rust.zip` |
| [`Flutter`](https://github.com/Cthaat/NekoTribe/tree/Flutter) | 跨端客户端 | 安装 Windows、Android 应用或部署独立 Web，连接任一后端 | `NekoTribe-<version>-flutter.zip` |

## ⚡ 快速开始

### A. Docker 部署（推荐）

准备 Docker Engine 或 Docker Desktop（Linux 容器模式）和 Docker Compose。完整栈启动 **4 个常驻容器 + 1 个一次性初始化容器**。下表是 Compose 服务名，生成的容器名带项目名前缀，例如 `nekotribe-app-1`。默认宿主机端口绑定在 `127.0.0.1`。

| 服务名 | 镜像 | 用途 | 默认端口（宿主机 → 容器） | 常驻 |
| --- | --- | --- | --- | --- |
| `app` | `ghcr.io/cthaat/nekotribe-nuxt:master` | Nuxt Web、API 和 WebSocket | `30001 → 3000` | 是 |
| `nginx` | `nginx:1.27-alpine` | 统一 HTTP、WebSocket 和媒体入口 | `30002 → 80` | 是 |
| `oracle19c` | `container-registry.oracle.com/database/enterprise:19.3.0.0`（由 `ORACLE_IMAGE` 覆盖） | Oracle 数据库 | `5501 → 1521`，EM Express `5500 → 5500` | 是 |
| `redis` | `redis:7-alpine` | 共享缓存和实时事件 | `6379 → 6379` | 是 |
| `db-init` | 同 `oracle19c` | 检查开发基线标记，显式授权后可初始化空库 | 无 | 否 |

```sh
git clone --branch master --single-branch https://github.com/Cthaat/NekoTribe.git nekotribe
cd nekotribe
cp .env.example .env
```

Windows PowerShell 可用 `Copy-Item .env.example .env`。已有 `.env` 时直接编辑。

| 需要填写的配置 | 填法 |
| --- | --- |
| `ACCESS_SECRET`、`REFRESH_SECRET` | 两个不同的随机长字符串 |
| `ORACLE_IMAGE`、`ORACLE_PWD` | 可用且已授权的 Oracle 19c 镜像，以及该容器的 SYS/SYSTEM 密码 |
| `ORACLE_SERVICE_NAME`、`ORACLE_USER`、`ORACLE_PASSWORD` | 内置开发基线固定 `ORCLPDB1`、`neko_app`，密码与实际 schema 一致。使用内置 SQL 初始化时，`.env` 中的密码应与 SQL 为该账号设置的密码一致 |
| `REDIS_PASSWORD` | 内置 Redis 的访问密码 |
| `COOKIE_SECURE` | 本机 HTTP 用 `false`，正式 HTTPS 用 `true` |

`.env.example` 中的 `ORACLE_IMAGE` 使用 `registry.cn-hangzhou.aliyuncs.com/zhuyijun/oracle:19c`。使用 Oracle 官方 19c Enterprise 时，在 Oracle Container Registry 接受相应条款并取得镜像访问权限，执行 `docker login container-registry.oracle.com`，再把 `ORACLE_IMAGE` 改为上表的官方镜像。使用 Oracle Free 23 或已有 Oracle，请走下方的外部依赖方案。

仅在**确认目标为独立空开发库**后执行下面的 `db-init` 命令。已有的 Oracle 库按部署手册检查和迁移 schema。

```sh
docker compose --env-file .env up -d --wait redis oracle19c
docker compose --env-file .env run --rm -e DB_INIT_ALLOW_EMPTY=true db-init
```

由管理员在 `ORCLPDB1` 内授予应用账号 `EXECUTE ON SYS.DBMS_LOCK` 后运行迁移并启动。使用官方 19c 镜像时，可执行 `docker compose --env-file .env exec oracle19c sqlplus / as sysdba`，在 SQL*Plus 执行 `ALTER SESSION SET CONTAINER = ORCLPDB1;` 和 `GRANT EXECUTE ON SYS.DBMS_LOCK TO NEKO_APP;`，然后输入 `EXIT`。

```sh
docker compose --env-file .env run --rm --no-deps --entrypoint node app scripts/migrate-db.mjs --apply
docker compose --env-file .env up -d
docker compose --env-file .env ps -a
curl --fail http://127.0.0.1:30002/api/ready
```

浏览器打开 **http://127.0.0.1:30002**，也可直连 Nuxt 的 `http://127.0.0.1:30001`。Oracle 与 Redis 就绪时 `/api/ready` 返回 HTTP 200。Windows PowerShell 中可使用 `curl.exe`。

**Oracle Free 23 或外部已有 Oracle / Redis。** 可独立运行 Oracle Free 23（例如 `gvenzl/oracle-free:23-slim`，PDB 为 `FREEPDB1`）或连接已经存在的 Oracle。为新库先由管理员建立空的应用 schema，再按纯结构基线初始化并执行增量迁移。内置 `db-init` 适用固定的 19c 开发基线。复制 `.env.example` 为 `.env.external`，添加 `ENV_FILE=./.env.external` 和 `NUXT_IMAGE=ghcr.io/cthaat/nekotribe-nuxt:master`，填写容器可达的 `ORACLE_HOST`、`ORACLE_PORT`、`ORACLE_SERVICE_NAME`、`ORACLE_USER`、`ORACLE_PASSWORD` 及 `REDIS_URL` 或 `REDIS_HOST`、`REDIS_PORT`、`REDIS_PASSWORD`。宿主机依赖可使用 `host.docker.internal`，前提是数据库和 Redis 在该地址上可达。[纯结构基线及权限](docs/deployment.md#新-oracle-库只创建应用结构) · [Oracle Free 镜像用法](https://github.com/gvenzl/oci-oracle-free#readme)

此模式只启动 **1 个常驻 app 容器**，入口为 `http://127.0.0.1:30001`。

```sh
docker compose --env-file .env.external -f docker-compose.external.yml pull app
docker compose --env-file .env.external -f docker-compose.external.yml up -d --no-build
curl --fail http://127.0.0.1:30001/api/ready
```

**按需接入 AI。** 默认栈包含社区核心组件。以下服务独立部署，具体接线见知识索引部署手册。

| 可选服务 | 镜像或来源 | 默认或示例端口 | 运行方式 |
| --- | --- | --- | --- |
| `knowledge-index` | `Dockerfile.knowledge-index` 的 `retrieval` 构建目标 | `127.0.0.1:3818 → 3818` | 常驻检索 |
| `knowledge-index-updater` | 同一 Dockerfile 的 `updater` 构建目标 | 无 | 显式启用 `index-update` profile，可常驻更新 |
| Qdrant | 外部向量数据库 | 示例 `6333` | 按需常驻 |
| Ollama | 外部模型服务，可选择 OpenAI 兼容服务 | 示例 `11434` | 按需常驻 |

### B. 运行 Release 预编译包

[最新正式版](https://github.com/Cthaat/NekoTribe/releases/latest) 和 [滚动预发布](https://github.com/Cthaat/NekoTribe/releases/tag/rolling-latest) 各提供四个主包。`<version>` 为版本号（如 `v2.0.0`），滚动版使用 `latest`。可用同页的 `SHA256SUMS.txt` 核对下载文件。

1. 下载 `NekoTribe-<version>-nuxt.zip`，解压后进入对应的 `windows-x64/` 或 `linux-x64/`。运行需要 x64 Node.js 22（至少 22.12.0）。
2. 把 `.env.example` 复制为 `.env`，填写宿主机可达的 Oracle、Redis 和签名配置。首次部署或升级先执行 `node scripts/package-nuxt.mjs --prepare .` 并按下文完成数据库初始化或迁移。
3. Windows 双击 `start.cmd`，Linux 执行 `sh start.sh`。打开 `http://127.0.0.1:3000`，或执行 `curl --fail http://127.0.0.1:3000/api/ready`。

### C. 本地源码运行

准备 Node.js 22（至少 22.12.0）、Yarn Classic 1.22.22，以及可用的 Oracle 和 Redis。从 `master` 分支根目录执行以下命令。先把 `.env.example` 复制为 `.env` 并填入依赖地址、schema 凭据及签名密钥。

```sh
yarn install --frozen-lockfile
node scripts/migrate-db.mjs --plan
node scripts/migrate-db.mjs --apply --dotenv .env
node scripts/migrate-db.mjs --check --dotenv .env
yarn dev
```

空 schema 先安装基线。准备 SQL*Plus 并在目标私有配置显式设置 `DB_INIT_ALLOW_EMPTY=true`，然后运行 `node scripts/init-db.mjs --schema-only --dotenv .env`，再执行上述迁移。默认开发地址为 `http://127.0.0.1:3000`。[新 Oracle 库部署](docs/deployment.md#新-oracle-库只创建应用结构) · [迁移权限](docs/architecture/schema-migrations.md)

## 核心功能

- 发布和发现动态，评论、点赞、关注用户，上传图片和附件。
- 创建和管理群组，使用频道聊天、私信和实时通知。
- 处理举报、审核内容与账号，管理申诉和发布策略。
- 按需启用 AI 写作、群知识问答、群运营和审核助手。

## 常用配置与连接

| 入口 | 默认地址 |
| --- | --- |
| Nuxt 本地或预编译包 | `http://127.0.0.1:3000` |
| Nuxt 容器 / Nginx | `http://127.0.0.1:30001` / `http://127.0.0.1:30002` |
| Go / Rust | `http://127.0.0.1:30006` / `http://127.0.0.1:30003` |
| 默认 WebSocket 与公开媒体 | `/_ws` / `/storage/` |

- **切换后端**：Nuxt、Go、Rust 可以共用 Oracle schema、Redis 实例及逻辑库。对应的 JWT 密钥和有效期、媒体位置、审核账号及 AI 配额保持一致。统一入口也可用可选的 `gateway` 服务，默认宿主端口 `30005`。[共用部署与切换](docs/deployment.md#同一个公共入口切换-nuxtgorust)
- **连接客户端**：Nuxt Web 的 `NUXT_PUBLIC_API_BASE` 填浏览器可达的 API 基址，实时和公开媒体默认跟随 API。独立部署时用 `NUXT_PUBLIC_WS_URL`、`NUXT_PUBLIC_STORAGE_BASE` 指定其他入口。服务端渲染可单独配置 `NUXT_API_SERVER_BASE`。Flutter 可直接填写选定后端的 API 地址。[地址约定](doc/runtime-addresses.md)
- **邮件与审核**：`SMTP_HOST`、`SMTP_PORT`、`SMTP_USER` 和 `SMTP_PASS` 用于邮箱验证码。用 `MODERATION_ADMIN_ACCOUNTS` 指定有权使用审核后台的账号。
- **AI 模型**：使用 `AI_MODEL_CONFIG_FILE` 或 `AI_MODEL_CONFIG_JSON` 配置模型和用途绑定，凭据由配置引用的环境变量提供。语义检索通过 `AI_KNOWLEDGE_INDEX_URL` 和 `AI_INDEX_SERVICE_TOKEN` 对接。[模型配置](docs/ai-writing-development.md) · [知识索引部署](docs/deployment.md#独立公开知识索引)
- **媒体存储**：`STORAGE_TYPE=local` 时使用 `STORAGE_ROOT_DIR` 与 `STORAGE_PATH`。`STORAGE_TYPE=s3` 时填写模板的 `STORAGE_S3_*`。共用后端时使用同一媒体目录或桶，统一公开路径及 CDN 地址。

## 架构与目录

<details>
<summary>Nuxt 4、Vue 3、Nitro、Oracle、Redis</summary>

| 路径 | 内容 |
| --- | --- |
| `app/` | Web 页面和客户端逻辑 |
| `server/` | Nitro API、实时连接、数据访问和存储 |
| `data/`、`scripts/` | Oracle 基线、迁移、部署和打包工具 |
| `doc/`、`specifications/` | OpenAPI、共享运行约定和验收台账 |
| `docs/` | 架构文档与部署手册 |

</details>

## 参与开发

在 Nuxt 根目录运行测试和契约检查。四个工作树位于同一父目录时，加 `--workspace-root ..` 核对所有副本。

```sh
yarn test
node scripts/contracts.mjs check --workspace-root ..
node scripts/parity.mjs check --workspace-root ..
```

单独克隆时，两条检查命令可省略工作区参数。参阅 [部署手册](docs/deployment.md)、[启动与初始化](docs/startup-safety.md)、[共享 API 架构](docs/architecture/shared-api.md) 和 [OpenAPI](doc/v2.openapi.json)。
