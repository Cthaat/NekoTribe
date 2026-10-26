# Windows / Linux 启动与部署

本说明对应整理后的独立 Nuxt 项目。静态阶段已结束，2026-10-26 按用户授权安装 Docker 并执行集中测试；当前通过和未通过的项目见 [运行验收记录](audits/2026-10-26-runtime-verification.md)。下面命令用于实际启动与部署；不可将本机 Linux 容器结果冒称另一台服务器已验收。

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

全栈 Compose 为 Oracle 19c 的现有 x86-64 部署设计，需要可获取且被允许运行的 Oracle 镜像、足够内存和持久磁盘。新库初始化可能耗时较长；不能用应用 `/api/health` 返回正常代替数据库业务验收。Linux 容器构建与独立 Linux 服务器验收分别记录。

## 本地与混合

使用 Node 22.12 以上的 Node 22、Yarn 1.22 和本项目锁文件。复制 `.env.example` 为 `.env`，填写签名密钥、数据库、Redis 及需要的 SMTP。Windows 用 `Copy-Item .env.example .env`，Linux 用 `cp .env.example .env`；已有配置不要覆盖。

```text
yarn install --frozen-lockfile
yarn dev
```

Windows 也可双击 `dev.cmd`。生产构建执行 `yarn build`，之后 `yarn start` 或双击 `start.cmd`。Linux 入口为 `sh scripts/dev.sh` 和 `sh scripts/start.sh`。应用前台输出日志，Ctrl+C 停止；重复启动遇到端口占用应停止旧进程或更换 `PORT`，入口不扫描或终止其他进程。

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

数据卷自动按 Compose 实例名分隔；已去掉固定 `container_name`，不同实例仍需配置不同宿主端口与上传目录。本机迁移保留的 `.env` 使用 `COMPOSE_PROJECT_NAME=nekotribe`、`ORACLE_DATA_VOLUME=../data/oracle-data`、`STORAGE_ROOT_DIR=../storage`；新机器不要照抄旧数据路径。`SENTIMENTFLOW_MODELS_HOST_DIR` 控制可选模型挂载，迁移机器的旧目录为 `../sentimentflow-models`。

## 外部数据库 / 分机

复制并修改一份私有配置，例如 `.env.external`。设置容器能访问的 `ORACLE_HOST`、`ORACLE_PORT`、服务名、schema 凭据及 `REDIS_URL` 或 `REDIS_HOST/PORT`；宿主机依赖可用 `host.docker.internal`，远程依赖使用真实主机名/IP。应用容器中的 `localhost` 指向它自己。明确填写 `NUXT_*` 时优先于对应旧名，包括显式空值。

```text
node scripts/deploy.mjs plan --mode external --env .env.external --project nekotribe-external
node scripts/deploy.mjs up --mode external --env .env.external --project nekotribe-external
```

此文件仅定义 app，没有数据库、Redis、db-init 或依赖自动替代服务；整库初始化动作在该模式被拒绝。已有外部 schema 如需兼容升级，只能在管理员确认目标、备份和授权后显式执行 `migrate-db --mode external --env .env.external --project nekotribe-external`；普通启动不会执行迁移。文件存储挂载到独立明确的 `STORAGE_ROOT_DIR`；分机后给 `BASE_URL` 或 `STORAGE_CDN_BASE_URL` 设置浏览器可访问地址。发布地址默认 loopback；需要其他机器访问时设置 `APP_BIND_ADDRESS=0.0.0.0`，并安排目标机网络和 TLS 入口。数据库和 Redis 默认仅发布 loopback，分机依赖的网络策略由对应主机管理。

## 同一个公共入口切换 Nuxt / Rust

可选 `docker-compose.gateway.yml` 只运行 Nginx 网关。`UI_NUXT_UPSTREAM` 指向 Nuxt 页面及 WebSocket 服务，`API_BACKEND_UPSTREAM` 指向所选 Nuxt 或 Rust HTTP 服务；值必须是网关能访问的根地址，不追加 `/api/v2`。默认均为 `http://host.docker.internal:3000`；若 Nuxt 在 Docker 的 30001 端口，相应改为 30001。Rust 示例为 `http://host.docker.internal:30003`，其 Nuxt 上游也必须配置且可用。

```text
docker compose --env-file .env -p nekotribe-gateway -f docker-compose.gateway.yml up -d
```

默认公共地址 `http://localhost:30005`，可配置 `GATEWAY_PORT` 和 `GATEWAY_BIND_ADDRESS`。网关不会启动 UI、Rust 或任何数据服务。`/api/`、`/storage/`、`/uploads/` 转给所选 HTTP 后端；`/_ws`、旧 `/upload/` 和页面转给 Nuxt。Nuxt Web 的 `NUXT_PUBLIC_API_BASE`、`NUXT_PUBLIC_WS_URL` 留空即可同源；Flutter API/WS/storage 均指向同一公共入口。修改后端选择后重建 gateway 容器使模板重新生成。

网关自身提供 HTTP；公网 HTTPS 应配置独立 TLS 终结层，并在应用设置 `COOKIE_SECURE=true` 和正确公共 `BASE_URL`。若使用跨来源直连，需要填写 `CORS_ALLOWED_ORIGINS`；地址格式与两前端 WebSocket 配置差异见 [runtime-addresses.md](../doc/runtime-addresses.md)。

Nginx 模板仅替换两个上游环境变量，保留 Nginx 自身变量；WebSocket 显式传递 Upgrade/Connection 并增加超时，依据 [官方模板入口](https://github.com/nginx/docker-nginx/blob/master/entrypoint/20-envsubst-on-templates.sh) 与 [WebSocket 代理文档](https://nginx.org/en/docs/http/websocket.html)。访问日志和 WebSocket 路由错误日志关闭，避免记录查询 token。

## 隔离测试资源

`.env.test.example` 是独立完整测试栈的样例。复制为 `.env.test` 后生成独立测试签名密钥，确认端口和路径，再通过 `--env .env.test --project nekotribe-test` 管理测试实例。其 Oracle/Redis 使用新实例和新命名卷，上传位于 `.test-data/storage`，不使用原 `../data/oracle-data` 或 `../storage`。

先 `up --mode dependencies`，再只针对新空测试库显式 `init-db`，授权后 `migrate-db`，最后 `up --mode source`；每一步都传同一组 `--env .env.test --project nekotribe-test`。宿主机迁移使用 `node scripts/migrate-db.mjs --apply --dotenv .env.test`。不要把测试文件配到日常实例名；不同端口不等于数据隔离。外部测试环境必须额外确认数据库/schema、Redis 资源和上传目录均隔离，helper 不把任意外部资源声明为安全测试目标。

## 最后验收范围

本次静态开发只验证脚本、参数、路由/规范及文件结构。待集中执行：清洁克隆安装和构建、完整 Compose 解析、Nuxt/Rust 镜像与健康/业务检查、重建后数据保留、Flutter 浏览器登录刷新退出/文件/实时流程、公共入口切后端，以及另一台 Windows/Linux 机器部署。历史日志仅证明其记录提交的结果；最新修改未经运行的项目不能标为通过。Windows Flutter 桌面构建按用户选择等待 C++ 工具链，Go 仍为预留。
