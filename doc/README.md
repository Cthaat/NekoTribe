# NekoTribe

中文 | [English](../README.md)

NekoTribe 是一个基于 Nuxt 4 的全栈社交应用。项目包含 Vue 前端、Nitro Server API、Oracle 数据模型、Redis 实时消息能力、媒体上传、通知、账号安全流程，以及并行运行的 v1/v2 API。

本仓库已按“新开发者克隆后可快速启动”的目标整理：复制环境变量样例、启动 Docker 依赖并由 Compose 自动初始化 Oracle、运行本地开发服务即可进入联调。

## 快速了解

- Nuxt 4 全栈应用，前端与后端职责边界清晰。
- v1/v2 API 并行演进，降低一次性迁移风险。
- Oracle 19c、Redis 7、WebSocket 实时消息能力。
- 媒体上传链路包含校验与本地存储。
- Docker 友好的本地开发与完整栈运行脚本。

## 快速入口

- API 接口文档: https://3kjlg46jpj.apifox.cn
- 本地开发: [快速开始: 本地开发](#快速开始-本地开发)
- 完整栈: [快速开始: 完整 Docker 栈](#快速开始-完整-docker-栈)
- 配置说明: [环境变量](#环境变量)
- 文档索引: [文档索引](#文档索引)

## 目录

- [项目概览](#项目概览)
- [核心能力](#核心能力)
- [用户侧页面](#用户侧页面)
- [架构说明](#架构说明)
- [API 与数据模型](#api-与数据模型)
- [技术栈](#技术栈)
- [环境要求](#环境要求)
- [快速开始: 本地开发](#快速开始-本地开发)
- [快速开始: 完整 Docker 栈](#快速开始-完整-docker-栈)
- [SentimentFlow 运行方式](#sentimentflow-运行方式)
- [脚本说明](#脚本说明)
- [环境变量](#环境变量)
- [外部服务](#外部服务)
- [文档索引](#文档索引)
- [工程约定](#工程约定)
- [目录结构](#目录结构)
- [开发与验证](#开发与验证)
- [生产部署](#生产部署)
- [常见问题](#常见问题)

## 项目概览

NekoTribe 的目标是构建一个面向社交内容发布、群组互动和账号安全管理的全栈应用。它不是单纯的前端演示项目，而是包含完整服务端 API、数据库模型、认证会话、文件上传、实时通信和容器化运行环境的工程化项目。

项目当前处于 v1 到 v2 并行演进阶段：

- v1 保留旧接口和旧业务路径，用于兼容既有功能。
- v2 按资源化 API、Oracle v2 数据模型和更清晰的服务分层重新实现。
- 前端仍可逐步迁移到 v2 接口，后端保持 v1/v2 并行，避免一次性切换造成不可控风险。
- 运维层面提供 `.env.example`、Docker Compose、Nginx 配置和 Compose 驱动的数据库初始化，降低新环境启动成本。

## 核心能力

| 模块         | 说明                                                                               | 主要位置                                                                                                      |
| ------------ | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| 用户认证     | 注册、登录、刷新令牌、退出登录、验证码、密码重置、会话管理。                       | `server/api/v2/auth`、`server/services/v2/auth.ts`、`app/pages/auth`                                          |
| 用户资料     | 当前用户资料、公开用户资料、头像、邮箱、设置、关注/粉丝、屏蔽、静音、用户统计。    | `server/api/v2/users`、`server/services/v2/users.ts`、`app/pages/user`、`app/pages/account`                   |
| 内容发布     | 帖子创建、列表、详情、删除、趋势、回复、转发、收藏、点赞、评论。                   | `server/api/v2/posts`、`server/api/v2/comments`、`server/services/v2/posts.ts`                                |
| 群组系统     | 群组创建、列表、详情、成员、角色、禁言、审批、邀请、群内帖子、群内评论、审计日志。 | `server/api/v2/groups`、`server/services/v2/groups.ts`、`app/pages/groups`                                    |
| 通知系统     | 通知列表、已读状态、恢复、删除、批量状态处理。                                     | `server/api/v2/notifications`、`server/services/v2/notifications.ts`、`app/pages/user/[id]/notifications.vue` |
| 媒体上传     | 头像、帖子媒体、独立媒体资源，支持图片、视频、音频校验和本地存储。                 | `server/api/v2/media`、`server/services/v2/media.ts`、`upload/`                                               |
| 标签与搜索   | 标签列表、热门标签、标签关联帖子、标签分析。                                       | `server/api/v2/tags`、`app/pages/tweet/search/[search].vue`                                                   |
| 推荐反馈     | 用户推荐、内容推荐反馈入口。                                                       | `server/api/v2/recommendations`、`server/api/v2/users/recommendations.get.ts`                                 |
| 账号安全     | 安全设置、邮箱变更、密码重置、登录设备、账号声明和申诉。                           | `server/api/v2/users/me/account-statements`、`app/pages/account/security.vue`                                 |
| 审核后台     | 内容、用户、举报、审核配置等管理页面。                                             | `app/pages/moderation`、`app/components/Moderation*.vue`                                                      |
| 实时通信     | WebSocket 连接、房间消息、广播、Redis 发布/订阅。                                  | `server/routes/_ws.ts`、`server/utils/redis.ts`、`app/pages/ws/index.vue`                                     |
| 国际化与主题 | 中英文语言文件、明暗主题、UI 偏好。                                                | `i18n/`、`app/plugins/ui-preferences.client.ts`、`app/components/ColorModeIcon.vue`                           |

## 用户侧页面

| 页面               | 路径                                    | 说明                                               |
| ------------------ | --------------------------------------- | -------------------------------------------------- |
| 首页               | `app/pages/index.vue`                   | 内容流和主要入口。                                 |
| 登录/注册/找回密码 | `app/pages/auth/*`                      | 认证流程、条款页和密码找回流程。                   |
| 账号中心           | `app/pages/account/*`                   | 概览、资料、安全、外观、设置、活跃会话、账号声明。 |
| 用户主页           | `app/pages/user/[id]/profile.vue`       | 公开资料、用户帖子和用户互动入口。                 |
| 用户通知           | `app/pages/user/[id]/notifications.vue` | 通知展示和处理。                                   |
| 帖子详情           | `app/pages/tweet/[id].vue`              | 帖子内容、评论、互动。                             |
| 帖子列表/搜索      | `app/pages/tweet/*`                     | 按类型、用户或搜索词展示内容。                     |
| 群组               | `app/pages/groups*.vue`                 | 群组首页、发现、我的群组、邀请。                   |
| 聊天               | `app/pages/chat.vue`                    | 聊天界面入口。                                     |
| 审核后台           | `app/pages/moderation*.vue`             | 内容审核、用户审核、举报和配置。                   |
| WebSocket 测试     | `app/pages/ws/index.vue`                | 本地验证实时通信能力。                             |

## 架构说明

### 系统链路

```text
浏览器
  ↓
Nuxt 4 前端应用 app/
  ↓  $fetch / useApi / useApiFetch
Nitro Server API server/api
  ↓
业务服务 server/services
  ↓
共享模型 server/models + 通用工具 server/utils
  ↓
Oracle / Redis / SMTP / 本地 upload 存储
```

### 职责边界

- 前端只负责页面、组件、状态和用户交互。
- API 路由只负责解析请求、调用服务和返回响应。
- 服务层负责业务流程和数据库读写编排。
- 模型层负责数据库记录到业务对象的映射。
- 工具层只放无业务语义的通用能力，例如数据库执行、请求解析、响应封装、鉴权解析和 Redis 通信。

### 前端架构

前端采用 Nuxt 4 的 `app/` 目录结构：

- `app/pages`：文件路由页面，覆盖首页、认证、账号、用户、帖子、群组、聊天、审核和测试页面。
- `app/components`：业务组件，例如帖子卡片、评论区、群组卡片、账号表单、审核列表、聊天组件。
- `app/components/ui`：shadcn-nuxt 风格的基础 UI 组件，例如按钮、表单、对话框、下拉菜单、分页、侧边栏。
- `app/stores`：Pinia 状态管理，当前包含用户偏好、推文状态等。
- `app/composables`：API 请求封装和通用组合式函数。
- `app/middleware`：路由中间件，用于登录态和主流程控制。
- `app/plugins`：客户端插件，例如错误处理、UI 偏好和已废弃心跳插件。
- `app/assets/css`：Tailwind CSS 入口。

前端请求主要通过 `useApi.ts` 和 `useApiFetch.ts` 封装，集中处理 API 基础地址、认证失败重试和错误提示。这样可以在迁移 v1/v2 接口时减少页面级改动。

### 后端架构

后端基于 Nuxt Nitro：

- `server/api/v1`：旧版 API。除非处理明确 bug，否则不应做结构性改动。
- `server/api/v2`：新版 API。接口按资源组织，例如 `auth`、`users`、`posts`、`groups`、`notifications`、`media`、`tags`。
- `server/services/v2`：v2 业务服务。复杂业务逻辑不放在路由文件中。
- `server/models`：共享模型和数据库映射，降低 SQL 行字段和响应对象之间的耦合。
- `server/types`：全局类型定义，包含 DTO、VO、响应结构和业务对象类型。
- `server/utils`：通用工具，包括 v2 响应封装、数据库执行、鉴权解析、Redis、WebSocket 会话和上传校验。
- `server/plugins`：Nitro 插件，当前包含 Redis 惰性注入、Oracle 连接池、日志和全局钩子。
- `server/middleware`：服务端中间件，包含鉴权、日志和限流等能力。
- `server/routes/_ws.ts`：WebSocket 路由。

### v2 API 推荐结构

```text
server/api/v2/xxx/*.ts
  解析路径参数和 HTTP 方法
  ↓
server/services/v2/*.ts
  校验请求体、鉴权、业务规则、事务编排
  ↓
server/utils/v2.ts
  执行 SQL、分页、响应封装、错误抛出
  ↓
server/models/v2.ts
  数据库行映射为前端可用对象
```

### 关键运行链路

#### 认证与会话

1. 用户通过邮箱验证码完成注册或密码重置。
2. 登录成功后，服务端签发访问令牌和刷新令牌，并写入 HttpOnly Cookie。
3. 会话信息写入 Oracle，刷新令牌只保存哈希值。
4. 当前访问令牌过期时，前端请求封装可触发刷新流程。
5. 退出登录或删除会话时，服务端撤销 Oracle 中对应会话并清理 Cookie。

#### 数据库访问

1. `server/plugins/02-oracle.ts` 以惰性方式创建 Oracle 连接池。
2. 请求进入 API 后，通过 `event.context.getOracleConnection` 获取连接。
3. v2 服务使用 `server/utils/v2.ts` 中的执行函数进行查询、分页和事务处理。
4. 返回前通过 `server/models/v2.ts` 映射成稳定响应对象。

#### Redis 与实时通信

1. `server/plugins/01-redisClient.ts` 为普通请求提供 Redis 惰性实例。
2. `server/utils/redis.ts` 为 WebSocket 提供发布者、订阅者和降级能力。
3. `server/routes/_ws.ts` 维护连接会话、房间、广播和心跳。
4. 多实例部署时，Redis pub/sub 用于跨实例广播。

#### 媒体上传

1. 前端通过表单上传头像或媒体文件。
2. 服务端使用 `formidable` 接收 multipart 文件。
3. 使用 `file-type` 校验真实 MIME 类型，按配置限制文件类型和大小。
4. 文件保存到 `upload/`，Nginx 通过 `/upload/` 静态直出。
5. 媒体元数据写入 Oracle，业务对象只保存公开 URL 和存储 key。

#### 容器化启动

1. `Dockerfile` 构建 Nuxt 生产产物。
2. `docker-compose.yml` 编排 app、Redis、Oracle、一次性数据库初始化和 Nginx。
3. `.env` 提供应用、数据库、缓存、SMTP 和端口配置。
4. `db-init` 服务会在 app 启动前把 v2 Oracle 基线写入目标数据库。

## API 与数据模型

### v2 API 模块概览

| API 模块          | 能力范围                                                                                                                           |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `auth`            | OTP、注册、登录、刷新当前令牌、退出、会话列表、删除会话、删除其他会话、密码重置。                                                  |
| `users`           | 用户列表、当前用户、用户详情、关注、粉丝、共同关注、用户帖子、用户分析、设置、头像、邮箱、收藏、屏蔽、静音、群组、账号声明与申诉。 |
| `posts`           | 帖子列表、发帖、详情、删除、趋势、评论、点赞、点赞列表、转发、回复、收藏、分析。                                                   |
| `comments`        | 评论删除、评论点赞、取消点赞。                                                                                                     |
| `groups`          | 群组 CRUD、按 slug 查询、热门群组、成员管理、角色变更、禁言、审批、邀请、邀请码、群内帖子、群内评论、置顶、审计日志、所有权转让。  |
| `notifications`   | 通知列表、删除、恢复、单条或批量已读状态。                                                                                         |
| `media`           | 媒体上传和删除。                                                                                                                   |
| `tags`            | 标签列表、热门标签、标签帖子、标签分析。                                                                                           |
| `recommendations` | 推荐反馈。                                                                                                                         |

### 数据模型概览

v2 数据库基线在 `doc/neko_tribe-oracle-v2.sql`，目标是把旧的推文式、动作式模型升级为更清晰的资源模型。

| 领域     | 主要表/对象                                                                                | 说明                                           |
| -------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------- |
| 用户     | `n_users`、`n_user_stats`、`n_user_settings`                                               | 用户主表、统计数据和偏好设置。                 |
| 认证     | `n_auth_otp_events`、`n_auth_sessions`                                                     | 验证码事件、访问/刷新令牌会话和设备信息。      |
| 社交关系 | `n_user_follows`、`n_user_blocks`、`n_user_mutes`                                          | 关注、屏蔽、静音分表，避免旧模型混装关系类型。 |
| 内容     | `n_posts`、`n_post_stats`、`n_post_likes`、`n_post_bookmarks`                              | 帖子、帖子统计、点赞和收藏。                   |
| 评论     | `n_comments`、`n_comment_stats`、`n_comment_likes`                                         | 评论、评论统计和评论点赞。                     |
| 媒体     | `n_media_assets`、`n_post_media`                                                           | 独立媒体资源和帖子媒体关联。                   |
| 标签     | `n_tags`、`n_post_tags`、`n_post_mentions`                                                 | 标签、帖子标签和提及关系。                     |
| 通知     | `n_notifications`、`n_notification_preferences`                                            | 通知记录和通知偏好。                           |
| 账号治理 | `n_account_statements`、`n_statement_appeals`                                              | 账号声明、处罚或风控记录，以及申诉流程。       |
| 群组     | `n_groups`、`n_group_members`、`n_group_posts`、`n_group_invites`、`n_group_audit_logs` 等 | 群组、成员、邀请、群内内容和审计日志。         |

旧版 SQL 和阶段性 SQL 仍保留在 `doc/` 和 `data/` 中，用于追溯历史设计。新环境优先使用 `doc/neko_tribe-oracle-v2.sql`。

## 技术栈

| 领域           | 技术                                                                                                        |
| -------------- | ----------------------------------------------------------------------------------------------------------- |
| 前端           | Nuxt 4、Vue 3、TypeScript、Pinia、Nuxt UI、shadcn-nuxt、Tailwind CSS 4                                      |
| 后端           | Nitro Server API、h3、TypeScript                                                                            |
| API 版本       | `server/api/v1` 旧接口，`server/api/v2` 资源化接口                                                          |
| 数据库         | Oracle 19c，通过 `oracledb` 访问                                                                            |
| 缓存与实时能力 | Redis 7，通过 `ioredis` 访问；Nitro WebSocket 路由为 `server/routes/_ws.ts`                                 |
| 认证           | JWT 访问令牌/刷新令牌、HttpOnly Cookie、bcrypt                                                              |
| 邮件           | SMTP，通过 `nodemailer` 发送                                                                                |
| 媒体           | 本地文件系统上传、`formidable`、`file-type`、`sharp`、`ffprobe-static`，旧版缩略图链路可选依赖系统 `ffmpeg` |
| 运行环境       | Node.js 22、Yarn 1.x、Docker Compose                                                                        |

## 环境要求

- Node.js 22+
- Yarn 1.x；如果本机没有 `yarn`，先执行 `corepack enable`。
- Docker Desktop 或 Docker Engine，并支持 Compose v2。
- Windows 推荐使用 PowerShell；Git Bash、WSL、macOS shell 或 Linux shell 可运行 `.sh` 脚本。
- 如果使用内置 Oracle 镜像，需要 Oracle Container Registry 访问权限并接受镜像协议。
- 可选：如果在 Docker 外运行旧版 v1 媒体缩略图功能，需要本机安装 `ffmpeg`。

## 快速开始: 本地开发

适用于“前端和 Nitro 开发服务器在宿主机运行，Oracle/Redis 用 Docker 启动”的场景。

```bash
corepack enable
yarn install --frozen-lockfile
cp .env.example .env
docker compose up -d redis oracle19c db-init
yarn dev
```

访问地址：

- 应用：`http://localhost:3000`
- WebSocket 测试页：`http://localhost:3000/ws`
- 宿主机访问 Oracle：`localhost:5501/ORCLPDB1`
- 宿主机访问 Redis：`localhost:6379`

PowerShell 等价命令：

```powershell
corepack enable
yarn install --frozen-lockfile
Copy-Item .env.example .env
docker compose up -d redis oracle19c db-init
yarn dev
```

## 快速开始: 完整 Docker 栈

适用于“应用、Redis、Oracle、Nginx 全部在 Docker 中运行”的场景。

```bash
cp .env.example .env
docker compose up -d
```

PowerShell：

```powershell
Copy-Item .env.example .env
docker compose up -d
```

访问地址：

- 应用容器端口：`http://localhost:30001`
- Nginx 反向代理与上传文件静态服务：`http://localhost:30002`
- Oracle 监听端口：`localhost:5501`
- Oracle EM Express：`http://localhost:5500/em`

Oracle 首次启动通常需要数分钟。如果拉取 Oracle 镜像失败，请先执行 `docker login container-registry.oracle.com`，并在 Oracle Container Registry 接受数据库镜像协议；也可以改用外部 Oracle 实例并更新 `.env`。
也可以在 `.env` 里把 `ORACLE_IMAGE` 切换为国内镜像，例如 `registry.cn-hangzhou.aliyuncs.com/zhuyijun/oracle:19c`。

## SentimentFlow 运行方式

两个 Compose 文件都会包含 SentimentFlow 服务。需要让 NekoTribe 应用调用情感分析后端时，在 `.env` 中保持代理开启：

```env
SENTIMENTFLOW_ENABLED=true
SENTIMENTFLOW_HOST_PORT=8846
SENTIMENTFLOW_CONTAINER_PORT=8846
```

端口变更集中在这两个变量中。`SENTIMENTFLOW_HOST_PORT` 控制浏览器和宿主机访问，例如 `http://localhost:${SENTIMENTFLOW_HOST_PORT}/docs`；`SENTIMENTFLOW_CONTAINER_PORT` 控制 SentimentFlow 进程监听端口、Docker 目标端口、健康检查，以及 Compose 内 NekoTribe app 访问 SentimentFlow 的地址。

默认部署使用 `docker-compose.yml`，直接拉取 GitHub Container Registry 上的自动构建镜像：

```bash
docker compose pull sentimentflow
docker compose up -d
```

`SENTIMENTFLOW_IMAGE` 默认值是 `ghcr.io/cthaat/sentimentflow-backend:latest`。如需固定某次自动构建，可改成具体标签，例如 `ghcr.io/cthaat/sentimentflow-backend:sha-1d3ecf9`。

本地源码构建使用 `docker-compose.local.yml`。该文件的内联 Dockerfile 会在镜像构建阶段从 GitHub 拉取 SentimentFlow 源码，而不是使用已发布镜像：

```bash
docker compose -f docker-compose.local.yml up -d --build
```

如果只想重建 SentimentFlow 服务：

```bash
docker compose -f docker-compose.local.yml up -d --build sentimentflow
```

`SENTIMENTFLOW_GIT_CONTEXT` 默认值是 `https://github.com/Cthaat/SentimentFlow.git#main`，可以按需把 `#` 后面的片段改成其他分支、标签或提交。模型文件会保存在 `sentimentflow-models` Docker 卷中。

## 脚本说明

| 脚本                          | 用途                                                                                           |
| ----------------------------- | ---------------------------------------------------------------------------------------------- |
| `scripts/dev.sh`              | 缺少 `.env` 时自动复制模板，启动 Redis/Oracle 容器，安装依赖并运行 `yarn dev`。                |
| `scripts/start.sh`            | 缺少 `.env` 时自动复制模板，并构建启动完整 Docker 栈。                                         |
| `scripts/init-db.sh`          | 默认 Compose 流程之外的手动兜底入口，可用于外部 Oracle 或恢复场景。                            |
| `scripts/docker-init-db.sh`   | `db-init` 服务使用的内部 Compose 入口脚本。                                                     |
| `scripts/dev.ps1`             | `scripts/dev.sh` 的 PowerShell 等价脚本。                                                      |
| `scripts/start.ps1`           | `scripts/start.sh` 的 PowerShell 等价脚本。                                                    |
| `scripts/init-db.ps1`         | `scripts/init-db.sh` 的 PowerShell 等价脚本。                                                  |
| `yarn dev`                    | 启动 Nuxt 开发服务器。                                                                         |
| `yarn build`                  | 构建 Nuxt 生产产物。                                                                           |
| `yarn start` / `yarn preview` | 本地预览已构建的 Nuxt 产物。                                                                   |
| `yarn typecheck`              | 运行 Nuxt TypeScript 类型检查。                                                                |
| `yarn docker:up`              | 执行 `docker compose up -d`。                                                                  |
| `yarn docker:down`            | 停止 Docker Compose 栈。                                                                       |

默认 Compose 流程会在 app 启动前运行一次 `db-init`。它会先检查 `NEKO_APP.N_USERS`，如果 schema 已存在就跳过初始化。v2 SQL 会创建用户、表空间、表、序列、触发器、视图和种子数据；`scripts/init-db.*` 保留给外部 Oracle 或恢复场景使用。

## 环境变量

复制 `.env.example` 为 `.env`。除本地开发外，必须替换所有示例密钥和密码。

| 变量                      | 是否必需      | 示例值                     | 用途                                                        |
| ------------------------- | ------------- | -------------------------- | ----------------------------------------------------------- |
| `NODE_ENV`                | 是            | `development`              | 运行环境。                                                  |
| `APP_PORT`                | Docker        | `30001`                    | 应用容器映射到宿主机的端口。                                |
| `NGINX_PORT`              | Docker        | `30002`                    | Nginx 容器映射到宿主机的端口。                              |
| `ACCESS_SECRET`           | 是            | 替换为随机长密钥           | JWT 访问令牌签名密钥。                                      |
| `ACCESS_EXPIRES_IN`       | 是            | `900`                      | 访问令牌有效期，单位秒。                                    |
| `REFRESH_SECRET`          | 是            | 替换为随机长密钥           | JWT 刷新令牌签名密钥。                                      |
| `REFRESH_EXPIRES_IN`      | 是            | `2592000`                  | 刷新令牌有效期，单位秒。                                    |
| `ORACLE_HOST`             | 是            | `localhost`                | 宿主机开发模式下应用连接的 Oracle 主机。                    |
| `ORACLE_PORT`             | 是            | `5501`                     | 宿主机开发模式下应用连接的 Oracle 端口。                    |
| `ORACLE_SERVICE_NAME`     | 是            | `ORCLPDB1`                 | 应用连接池使用的 Oracle 服务名。                            |
| `ORACLE_SID`              | 否            | 空                         | 兼容字段；当前连接池使用服务名。                            |
| `ORACLE_USER`             | 是            | `neko_app`                 | 应用 schema 用户。                                          |
| `ORACLE_PASSWORD`         | 是            | 来自 v2 SQL                | 本地开发应用 schema 密码。                                  |
| `ORACLE_POOL_MIN`         | 否            | `2`                        | Oracle 连接池最小连接数。                                   |
| `ORACLE_POOL_MAX`         | 否            | `10`                       | Oracle 连接池最大连接数。                                   |
| `ORACLE_POOL_INCREMENT`   | 否            | `1`                        | Oracle 连接池扩容步长。                                     |
| `ORACLE_HOST_PORT`        | Docker        | `5501`                     | Oracle 容器 `1521` 映射到宿主机的端口。                     |
| `ORACLE_EM_PORT`          | Docker        | `5500`                     | Oracle EM Express 映射端口。                                |
| `ORACLE_IMAGE`            | Docker        | `container-registry.oracle.com/database/enterprise:19.3.0.0` | `oracle19c` 和 `db-init` 使用的 Oracle 镜像。               |
| `ORACLE_PWD`              | Docker/初始化 | 替换为安全密码             | Oracle 容器 SYS/SYSTEM 密码，也是初始化脚本的 SYSDBA 密码。 |
| `ORACLE_SYS_SERVICE_NAME` | 初始化        | `ORCLCDB`                  | `db-init` 和 `scripts/init-db.*` 使用的 CDB 服务名。         |
| `DB_INIT_CHECK_TABLE`     | 初始化        | `N_USERS`                  | `db-init` 用来判断数据库是否已初始化的应用 schema 表。       |
| `DOCKER_ORACLE_HOST`      | Docker        | `oracle19c`                | 应用容器内访问 Oracle 的主机名。                            |
| `DOCKER_ORACLE_PORT`      | Docker        | `1521`                     | 应用容器内访问 Oracle 的端口。                              |
| `DOCKER_NODE_ENV`         | Docker        | `production`               | 应用容器运行环境，默认固定为生产模式。                      |
| `DOCKER_REDIS_URL`        | Docker        | `redis://redis:6379`       | 应用容器内 Redis 连接串，覆盖宿主机开发用的 `REDIS_URL`。   |
| `REDIS_URL`               | 否            | 空                         | 可选 Redis 连接字符串；设置后 Redis 工具优先使用它。        |
| `REDIS_HOST`              | 是            | `localhost`                | 宿主机开发模式下 Redis 主机。                               |
| `REDIS_PORT`              | 是            | `6379`                     | Redis 端口。                                                |
| `REDIS_DB`                | 否            | `0`                        | Redis 数据库编号。                                          |
| `REDIS_PASSWORD`          | 否            | 替换为安全密码             | Redis 密码；内置 Redis 服务会读取该值。                     |
| `DOCKER_REDIS_HOST`       | Docker        | `redis`                    | 应用容器内访问 Redis 的主机名。                             |
| `DOCKER_REDIS_PORT`       | Docker        | `6379`                     | 应用容器内访问 Redis 的端口。                               |
| `SMTP_HOST`               | 邮件          | `smtp.example.com`         | 验证码和账号邮件使用的 SMTP 主机。                          |
| `SMTP_PORT`               | 邮件          | `465`                      | SMTP 端口；当前代码按安全 SMTP 创建连接。                   |
| `SMTP_USER`               | 邮件          | 空                         | SMTP 用户名和发件人。                                       |
| `SMTP_PASS`               | 邮件          | 空                         | SMTP 密码或应用专用密码。                                   |
| `NUXT_PUBLIC_WS_URL`      | 否            | `ws://localhost:3000/_ws`  | 客户端运行时使用的公开 WebSocket 地址。                     |
| `DOCKER_PUBLIC_WS_URL`    | Docker        | `ws://localhost:30001/_ws` | 应用容器模式下公开给客户端的 WebSocket 地址。               |
| `NUXT_PUBLIC_API_BASE`    | 否            | 空                         | 客户端 API 基础地址；空表示同源。                           |
| `SENTIMENTFLOW_ENABLED`   | 否            | `true`                     | 是否启用 SentimentFlow 集成和代理访问。                     |
| `SENTIMENTFLOW_BASE_URL`  | 否            | 空                         | 外部 SentimentFlow 地址覆盖项；留空时宿主机开发访问会从 `SENTIMENTFLOW_HOST_PORT` 派生。 |
| `SENTIMENTFLOW_TIMEOUT_MS` | 否           | `10000`                    | 上游代理超时时间，单位毫秒。                                |
| `SENTIMENTFLOW_IMAGE`     | Docker        | `ghcr.io/cthaat/sentimentflow-backend:latest` | `docker-compose.yml` 拉取的 GHCR 镜像。              |
| `SENTIMENTFLOW_LOCAL_IMAGE` | Docker 本地  | `sentimentflow-backend:local` | `docker-compose.local.yml` 构建出的本地镜像标签。       |
| `SENTIMENTFLOW_GIT_CONTEXT` | Docker 本地  | `https://github.com/Cthaat/SentimentFlow.git#main` | `docker-compose.local.yml` 镜像构建阶段拉取的 Git 源。 |
| `SENTIMENTFLOW_CONTAINER_PROJECT_ROOT` | Docker | `/workspace`       | SentimentFlow 容器内项目根目录。                            |
| `SENTIMENTFLOW_MODELS_DIR` | Docker        | `/workspace/models`       | SentimentFlow 容器内模型持久化挂载目录。                    |
| `SENTIMENTFLOW_HOST_PORT` | Docker        | `8846`                     | SentimentFlow 暴露给宿主机和浏览器的端口；修改后访问 `localhost:<端口>`。 |
| `SENTIMENTFLOW_CONTAINER_PORT` | Docker   | `8846`                     | SentimentFlow 容器内端口，用于 Uvicorn、Docker 目标端口、健康检查和 app 容器内访问地址。 |

## 外部服务

| 服务         | 用途                                                         | 本地启动方式                                                                                   | 配置方式                                                                                  |
| ------------ | ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Oracle 19c   | 用户、帖子、群组、通知、认证会话、媒体元数据等主业务数据库。 | 包含在 `docker compose up -d` 中；`db-init` 会在 app 启动前写入 v2 基线。                     | `.env` 中的 `ORACLE_*`。                                                                  |
| Redis 7      | v1 验证码存储、WebSocket 发布/订阅和实时广播。               | `docker compose up -d redis`。                                                                 | `.env` 中的 `REDIS_*`。                                                                   |
| SMTP         | 发送邮箱验证码、密码重置和账号相关邮件。                     | 使用任意兼容 SMTP 的邮件服务商。                                                               | `.env` 中的 `SMTP_*`。                                                                    |
| Nginx        | 静态服务 `/upload/` 文件，并在 Docker 模式下反向代理应用。   | 包含在 `docker compose up -d` 中。                                                             | 完整 Docker 使用 `nginx/nginx.compose.conf`；反代宿主机 dev 服务使用 `nginx/nginx.conf`。 |
| 文件系统上传 | 存储用户头像和媒体文件。                                     | 按需在 `upload/` 下创建，已被 git 忽略。                                                       | 挂载到 Nginx 容器的 `/usr/share/nginx/upload`。                                           |
| 媒体工具链   | 校验图片、视频、音频并为旧版链路生成缩略图。                 | Docker 镜像已安装 `ffmpeg`；宿主机旧版媒体链路需要系统 `ffmpeg`。                              | `sharp`、`file-type`、`ffprobe-static`，可选系统 `ffmpeg`。                               |
| SentimentFlow | 外部情感分析服务，提供预测、训练、模型和统计接口。      | GHCR 模式：运行 `docker compose up -d`；本地构建模式：运行 `docker compose -f docker-compose.local.yml up -d --build`。 | `.env` 中的 `SENTIMENTFLOW_*`；端口集中由 `SENTIMENTFLOW_HOST_PORT` 与 `SENTIMENTFLOW_CONTAINER_PORT` 控制。 |

备注：`doc/neko_tribe-oracle-v2.sql` 是当前 v2 开发数据库基线，并会挂载到 `db-init` 服务。`data/oracle-init/` 下的文件保留为历史群组模块脚本，因为这些脚本本身不是完整数据库基线。

## 文档索引

| 文档                                        | 说明                                           |
| ------------------------------------------- | ---------------------------------------------- |
| `README.md`                                 | 项目总览、架构、启动、配置和部署入口（中文）。 |
| `../README.md`                              | Project overview and setup guide (English).    |
| `docs/README.md`                            | 新增运维文档目录说明。                         |
| `doc/NekoTribe-V2接口与Oracle重构总设计.md` | v2 API 与 Oracle 重构设计总览。                |
| `doc/NekoTribe-V2-Apifox接口详细文档.md`    | v2 接口详细说明。                              |
| `doc/NekoTribe-V2-Apifox导入.json`          | Apifox 导入文件。                              |
| `doc/API v2平滑迁移实战指南(新手版).md`     | v1 到 v2 平滑迁移方法。                        |
| `doc/neko_tribe-oracle-v2.sql`              | v2 Oracle 数据库基线。                         |
| `doc/群组功能API文档.md`                    | 群组功能 API 说明。                            |
| `doc/Token无感刷新实现文档.md`              | Token 无感刷新实现说明。                       |
| `doc/NekoTribe长期最终可执行路线图.md`      | 长期演进路线。                                 |
| `config/versions/README.md`                 | 服务版本元数据说明。                           |
| `script/github/README.md`                   | 标签和发布自动化脚本说明。                     |

## 工程约定

- 业务代码优先使用 TypeScript 明确类型，避免关键数据结构隐式漂移。
- v1 与 v2 API 保持隔离，v2 不调用 v1 路由逻辑。
- 共享能力只能抽到 `server/utils` 或 `server/models`，不得让工具层依赖具体业务模块。
- 新增接口优先采用 REST 风格路径和 HTTP 方法。
- 新增环境配置必须同步更新 `.env.example` 和 README 环境变量表。
- 新增外部服务必须在 README 的“外部服务”中说明用途、启动方式和配置方式。
- 上传文件、数据库运行数据、缓存和构建产物不得提交到 Git。

## 目录结构

```text
NekoTribe/
├── app/                         # Nuxt 4 前端应用：页面、布局、组件、状态、组合式函数
├── server/                      # Nitro 后端
│   ├── api/
│   │   ├── v1/                  # 旧版 API，保持隔离
│   │   └── v2/                  # v2 API 路由
│   ├── services/                # 业务服务，包含 services/v2
│   ├── models/                  # 共享数据库模型与领域映射
│   ├── utils/                   # 请求、响应、数据库、Redis 等通用工具
│   ├── types/                   # 全局服务端/API 类型
│   ├── middleware/              # 服务端中间件
│   ├── plugins/                 # Nitro 插件：Redis、Oracle、日志与钩子
│   └── routes/                  # 非 API 的 Nitro 路由，包含 WebSocket
├── config/                      # 版本元数据和服务配置
├── doc/                         # 既有产品、API、SQL 设计文档
├── docs/                        # 新增运维手册和运行说明
├── data/                        # 本地数据库相关资源；运行期数据库数据已忽略
├── i18n/                        # 国际化语言文件
├── nginx/                       # Nginx 反向代理与上传文件静态服务配置
├── public/                      # 公共静态资源
├── script/                      # 既有发布自动化脚本，不重命名
├── scripts/                     # 本地开发、启动、初始化脚本
├── .env.example                 # 脱敏环境变量模板
├── docker-compose.yml           # 本地依赖与应用编排
├── Dockerfile                   # 标准容器构建入口
└── README.md
```

Nuxt 4 标准前端目录是 `app/`。本项目保留 `app/`，不强行改成 `client/`，避免引入路由、别名和组件路径迁移风险。

## 开发与验证

```bash
yarn install --frozen-lockfile
yarn typecheck
yarn build
```

常用检查：

```bash
docker compose config --quiet
bash -n scripts/dev.sh scripts/start.sh scripts/init-db.sh scripts/docker-init-db.sh
```

PowerShell 脚本语法检查：

```powershell
$errors = @()
foreach ($f in 'scripts/dev.ps1','scripts/start.ps1','scripts/init-db.ps1') {
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$null, [ref]$errors) | Out-Null
}
if ($errors.Count) { $errors; exit 1 }
```

## 生产部署

1. 准备 Oracle、Redis、SMTP 和持久化上传存储。
2. 基于 `.env.example` 创建生产 `.env`，替换所有密钥和密码。
3. 审查并执行生产数据库初始化或迁移 SQL。
4. 构建并运行应用镜像：

```bash
docker build -t nekotribe:prod .
docker run --env-file .env -p 3000:3000 nekotribe:prod
```

5. 在应用前放置 Nginx 或其他反向代理。
6. 挂载持久化 `upload/` 存储，并由反向代理或等价对象存储服务提供 `/upload/` 访问。
7. 生产环境应使用 HTTPS，以便认证 Cookie 可以安全启用 `secure`。

内置 `docker-compose.yml` 面向本地开发和小型测试环境。生产环境建议使用托管 Oracle/Redis，并且不要复用示例密码。

## 常见问题

### Docker 无法拉取 Oracle 镜像

在 `.env` 里通过 `ORACLE_IMAGE` 选择 Oracle 镜像来源。默认官方镜像需要 Oracle Container Registry 权限和镜像协议确认；如需国内镜像，可改为 `registry.cn-hangzhou.aliyuncs.com/zhuyijun/oracle:19c`。

### 应用启动后 API 请求报 Oracle 错误

先用 `docker compose logs db-init` 确认 `db-init` 服务已成功退出。再确认本地开发模式使用 `ORACLE_HOST=localhost`、`ORACLE_PORT=5501`；Docker 应用模式使用 `DOCKER_ORACLE_HOST=oracle19c`、`DOCKER_ORACLE_PORT=1521`。

### Redis 认证失败

确认 `.env` 中的 `REDIS_PASSWORD` 与 Redis 容器实际密码一致。内置 compose 服务会从 `.env` 读取该值。

### `docker compose up -d` 提示 `dependency failed to start`，但稍后 `app` 变成 `healthy`

这通常不是应用彻底启动失败，而是冷启动阶段超过了 Docker 早期健康检查窗口。当前配置已经改为：

- 健康检查走 `GET /api/health`，不再依赖首页 SSR。
- Docker 模式强制覆盖 `DOCKER_REDIS_URL=redis://redis:6379`，避免容器内误连 `localhost`。
- `app` 健康检查窗口已放宽，覆盖 Oracle 冷启动和 Nuxt 首次初始化。

如果仍然出现该问题，优先检查：

1. `docker logs -f nekotribe-app-1`
2. `docker inspect nekotribe-app-1 --format '{{json .State.Health}}'`
3. `.env` 中是否错误写入了 Docker 不应使用的宿主机地址

### 邮箱验证码无法发送

需要配置 `SMTP_HOST`、`SMTP_PORT`、`SMTP_USER` 和 `SMTP_PASS`。应用可以在未配置 SMTP 时启动，但邮箱验证码流程依赖 SMTP。

### 本地是否必须安装 Oracle Instant Client

当前代码没有调用 `oracledb.initOracleClient`，默认使用 node-oracledb thin 模式。只有目标部署需要 thick 模式能力时，才需要安装 Oracle Instant Client。

### 为什么同时存在 `doc/` 和 `docs/`

`doc/` 存放既有产品、API 和 SQL 文档，代码和历史资料中已有引用。`docs/` 用于新增运维手册和运行说明，避免破坏旧链接。

### 为什么同时存在 `script/` 和 `scripts/`

`script/` 被既有发布和版本自动化使用。`scripts/` 存放新增的开发、启动和部署辅助脚本。
