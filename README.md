# NekoTribe

English | [中文](doc/README.md)

NekoTribe is a full-stack social application built on Nuxt 4. It bundles a Vue frontend, Nitro Server API, Oracle data model, Redis realtime messaging, media uploads, notifications, account security flows, and parallel v1/v2 APIs.

This repo is organized so a new developer can start quickly after clone: copy the env sample, start Docker dependencies with Compose-driven Oracle initialization, run the local dev server, then begin integration.

## Highlights

- Full-stack Nuxt 4 app with a clear frontend/backend boundary.
- Parallel v1/v2 API evolution to avoid risky big-bang migration.
- Oracle 19c, Redis 7, and WebSocket realtime messaging.
- Media upload pipeline with validation and local storage.
- Docker-first local dev and full-stack runtime scripts.

## Quick Links

- API docs: https://3kjlg46jpj.apifox.cn
- Quick start: [Local Development](#quick-start-local-development)
- Quick start: [Full Docker Stack](#quick-start-full-docker-stack)
- Config: [Environment Variables](#environment-variables)
- Docs: [Documentation Index](#documentation-index)

## Table of Contents

- [Project Overview](#project-overview)
- [Core Capabilities](#core-capabilities)
- [User-Facing Pages](#user-facing-pages)
- [Architecture](#architecture)
- [API and Data Model](#api-and-data-model)
- [Tech Stack](#tech-stack)
- [Requirements](#requirements)
- [Quick Start: Local Development](#quick-start-local-development)
- [Quick Start: Full Docker Stack](#quick-start-full-docker-stack)
- [Scripts](#scripts)
- [Environment Variables](#environment-variables)
- [External Services](#external-services)
- [Documentation Index](#documentation-index)
- [Engineering Conventions](#engineering-conventions)
- [Directory Structure](#directory-structure)
- [Development and Verification](#development-and-verification)
- [Production Deployment](#production-deployment)
- [FAQ](#faq)

## Project Overview

NekoTribe aims to build a full-stack application for social content publishing, group interaction, and account security management. It is not a simple frontend demo project; it includes complete server APIs, database models, auth sessions, file uploads, realtime communication, and a containerized runtime.

The project is currently evolving in parallel from v1 to v2:

- v1 keeps legacy endpoints and business paths for compatibility.
- v2 is rebuilt with resource-oriented APIs, the Oracle v2 data model, and clearer service layering.
- The frontend can migrate to v2 gradually, while the backend keeps v1/v2 in parallel to avoid risky big-bang switches.
- Operations include `.env.example`, Docker Compose, Nginx config, and Compose-driven database initialization to reduce environment setup cost.

## Core Capabilities

| Module                  | Description                                                                                                       | Primary Locations                                                                                             |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Authentication          | Registration, login, refresh tokens, logout, OTP, password reset, session management.                             | `server/api/v2/auth`, `server/services/v2/auth.ts`, `app/pages/auth`                                          |
| User Profile            | Current user profile, public profile, avatar, email, settings, follow/followers, block, mute, user stats.         | `server/api/v2/users`, `server/services/v2/users.ts`, `app/pages/user`, `app/pages/account`                   |
| Content Publishing      | Post creation, list, detail, delete, trends, replies, reposts, bookmarks, likes, comments.                        | `server/api/v2/posts`, `server/api/v2/comments`, `server/services/v2/posts.ts`                                |
| Groups                  | Group creation, list, detail, members, roles, mutes, approvals, invites, group posts, group comments, audit logs. | `server/api/v2/groups`, `server/services/v2/groups.ts`, `app/pages/groups`                                    |
| Notifications           | Notification list, read status, restore, delete, batch status handling.                                           | `server/api/v2/notifications`, `server/services/v2/notifications.ts`, `app/pages/user/[id]/notifications.vue` |
| Media Upload            | Avatars, post media, standalone media assets, with image/video/audio validation and local storage.                | `server/api/v2/media`, `server/services/v2/media.ts`, `upload/`                                               |
| Tags and Search         | Tag list, hot tags, tag posts, tag analytics.                                                                     | `server/api/v2/tags`, `app/pages/tweet/search/[search].vue`                                                   |
| Recommendation Feedback | User recommendations, content recommendation feedback entry.                                                      | `server/api/v2/recommendations`, `server/api/v2/users/recommendations.get.ts`                                 |
| Account Security        | Security settings, email change, password reset, login devices, account statements and appeals.                   | `server/api/v2/users/me/account-statements`, `app/pages/account/security.vue`                                 |
| Moderation Console      | Admin pages for content, users, reports, and moderation config.                                                   | `app/pages/moderation`, `app/components/Moderation*.vue`                                                      |
| Realtime Messaging      | WebSocket connections, room messages, broadcasts, Redis pub/sub.                                                  | `server/routes/_ws.ts`, `server/utils/redis.ts`, `app/pages/ws/index.vue`                                     |
| i18n and Theme          | Chinese/English locales, light/dark theme, UI preferences.                                                        | `i18n/`, `app/plugins/ui-preferences.client.ts`, `app/components/ColorModeIcon.vue`                           |

## User-Facing Pages

| Page                              | Path                                    | Description                                                                             |
| --------------------------------- | --------------------------------------- | --------------------------------------------------------------------------------------- |
| Home                              | `app/pages/index.vue`                   | Feed and main entry.                                                                    |
| Login / Register / Password Reset | `app/pages/auth/*`                      | Auth flows, terms, and password recovery.                                               |
| Account Center                    | `app/pages/account/*`                   | Overview, profile, security, appearance, settings, active sessions, account statements. |
| User Profile                      | `app/pages/user/[id]/profile.vue`       | Public profile, user posts, user interactions.                                          |
| User Notifications                | `app/pages/user/[id]/notifications.vue` | Notification display and handling.                                                      |
| Post Detail                       | `app/pages/tweet/[id].vue`              | Post content, comments, interactions.                                                   |
| Post List / Search                | `app/pages/tweet/*`                     | Content by type, user, or query.                                                        |
| Groups                            | `app/pages/groups*.vue`                 | Group home, discover, my groups, invites.                                               |
| Chat                              | `app/pages/chat.vue`                    | Chat entry page.                                                                        |
| Moderation Console                | `app/pages/moderation*.vue`             | Content moderation, user review, reports, configuration.                                |
| WebSocket Test                    | `app/pages/ws/index.vue`                | Local verification for realtime messaging.                                              |

## Architecture

### System Flow

```text
Browser
  ↓
Nuxt 4 frontend app/
  ↓  $fetch / useApi / useApiFetch
Nitro Server API server/api
  ↓
Business services server/services
  ↓
Shared models server/models + common utils server/utils
  ↓
Oracle / Redis / SMTP / local upload storage
```

### Responsibility Boundaries

- The frontend only handles pages, components, state, and user interaction.
- API routes only parse requests, call services, and return responses.
- The service layer owns business flows and database orchestration.
- The model layer maps database rows to business objects.
- The utils layer holds generic, non-domain utilities such as DB execution, request parsing, response wrappers, auth parsing, and Redis communication.

### Frontend Architecture

The frontend follows Nuxt 4's `app/` directory structure:

- `app/pages`: file-based routes for home, auth, account, users, posts, groups, chat, moderation, and test pages.
- `app/components`: business components such as post cards, comment sections, group cards, account forms, moderation lists, chat widgets.
- `app/components/ui`: shadcn-nuxt style base UI components such as buttons, forms, dialogs, dropdowns, pagination, sidebars.
- `app/stores`: Pinia state management, currently user preferences and tweet state.
- `app/composables`: API wrappers and shared composables.
- `app/middleware`: route middleware for auth state and main flow control.
- `app/plugins`: client plugins such as error handling, UI preferences, and a deprecated heartbeat plugin.
- `app/assets/css`: Tailwind CSS entry.

Frontend requests are wrapped by `useApi.ts` and `useApiFetch.ts` to centralize API base URLs, auth-failure retries, and error notifications. This reduces page-level changes when migrating v1/v2 APIs.

### Backend Architecture

The backend is based on Nuxt Nitro:

- `server/api/v1`: legacy APIs. Avoid structural changes unless fixing an explicit bug.
- `server/api/v2`: new APIs, organized by resource like `auth`, `users`, `posts`, `groups`, `notifications`, `media`, `tags`.
- `server/services/v2`: v2 service layer. Complex business logic stays out of route files.
- `server/models`: shared models and DB mapping, reducing coupling between SQL rows and response objects.
- `server/types`: global type definitions, including DTOs, VOs, response structures, and domain types.
- `server/utils`: generic utilities, including v2 response wrappers, DB execution, auth parsing, Redis, WebSocket sessions, and upload validation.
- `server/plugins`: Nitro plugins, currently Redis lazy injection, Oracle pools, logging, and global hooks.
- `server/middleware`: server middleware for auth, logging, and rate limits.
- `server/routes/_ws.ts`: WebSocket route.

### v2 API Pattern

```text
server/api/v2/xxx/*.ts
  Parse path params and HTTP methods
  ↓
server/services/v2/*.ts
  Validate body, auth, business rules, transaction orchestration
  ↓
server/utils/v2.ts
  Execute SQL, paginate, wrap responses, throw errors
  ↓
server/models/v2.ts
  Map DB rows into frontend-ready objects
```

### Key Runtime Flows

#### Auth and Sessions

1. Users complete registration or password reset with an email OTP.
2. After login, the server issues access and refresh tokens and writes them to HttpOnly cookies.
3. Session data is stored in Oracle; refresh tokens are stored as hashes only.
4. When access tokens expire, frontend request wrappers can trigger refresh flow.
5. Logout or session deletion revokes the session in Oracle and clears cookies.

#### Database Access

1. `server/plugins/02-oracle.ts` creates the Oracle pool lazily.
2. Requests get a connection via `event.context.getOracleConnection`.
3. v2 services use execution helpers in `server/utils/v2.ts` for queries, pagination, and transactions.
4. Responses are mapped via `server/models/v2.ts` before return.

#### Redis and Realtime Messaging

1. `server/plugins/01-redisClient.ts` provides a lazy Redis instance for normal requests.
2. `server/utils/redis.ts` provides publishers, subscribers, and fallbacks for WebSocket.
3. `server/routes/_ws.ts` maintains sessions, rooms, broadcasts, and heartbeat.
4. In multi-instance deployments, Redis pub/sub enables cross-instance broadcasts.

#### Media Uploads

1. The frontend uploads avatars or media files via form submissions.
2. The server uses `formidable` to receive multipart files.
3. `file-type` validates real MIME types and limits file types and sizes.
4. Files are saved to `upload/`, and Nginx serves them from `/upload/`.
5. Media metadata is stored in Oracle, while business objects only store public URLs and storage keys.

#### Containerized Startup

1. `Dockerfile` builds Nuxt production artifacts.
2. `docker-compose.yml` orchestrates app, Redis, Oracle, one-shot database initialization, and Nginx.
3. `.env` provides app, DB, cache, SMTP, and port configuration.
4. The `db-init` service writes the v2 Oracle baseline before the app starts.

## API and Data Model

### v2 API Module Overview

| API Module        | Scope                                                                                                                                                                                   |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `auth`            | OTP, registration, login, refresh current token, logout, session list, delete session, delete other sessions, password reset.                                                           |
| `users`           | User list, current user, user detail, follow, followers, mutual follow, user posts, analytics, settings, avatar, email, bookmarks, block, mute, groups, account statements and appeals. |
| `posts`           | Post list, create, detail, delete, trends, comments, likes, like list, repost, reply, bookmarks, analytics.                                                                             |
| `comments`        | Comment delete, comment like, unlike.                                                                                                                                                   |
| `groups`          | Group CRUD, query by slug, hot groups, member management, role changes, mute, approvals, invites, invite codes, group posts, group comments, pin, audit logs, ownership transfer.       |
| `notifications`   | Notification list, delete, restore, single or batch read status.                                                                                                                        |
| `media`           | Media upload and delete.                                                                                                                                                                |
| `tags`            | Tag list, hot tags, tag posts, tag analytics.                                                                                                                                           |
| `recommendations` | Recommendation feedback.                                                                                                                                                                |

### Data Model Overview

The v2 database baseline is in `doc/neko_tribe-oracle-v2.sql`, aiming to upgrade the old tweet/action models into clearer resource models.

| Domain             | Primary Tables/Objects                                                                        | Description                                                |
| ------------------ | --------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Users              | `n_users`, `n_user_stats`, `n_user_settings`                                                  | User master, stats, and preference settings.               |
| Auth               | `n_auth_otp_events`, `n_auth_sessions`                                                        | OTP events, access/refresh token sessions and device info. |
| Social Graph       | `n_user_follows`, `n_user_blocks`, `n_user_mutes`                                             | Follow, block, mute tables to avoid mixing relation types. |
| Content            | `n_posts`, `n_post_stats`, `n_post_likes`, `n_post_bookmarks`                                 | Posts, post stats, likes, bookmarks.                       |
| Comments           | `n_comments`, `n_comment_stats`, `n_comment_likes`                                            | Comments, comment stats, comment likes.                    |
| Media              | `n_media_assets`, `n_post_media`                                                              | Media assets and post media relations.                     |
| Tags               | `n_tags`, `n_post_tags`, `n_post_mentions`                                                    | Tags, post tags, mentions.                                 |
| Notifications      | `n_notifications`, `n_notification_preferences`                                               | Notification records and preferences.                      |
| Account Governance | `n_account_statements`, `n_statement_appeals`                                                 | Account statements, enforcement records, and appeal flow.  |
| Groups             | `n_groups`, `n_group_members`, `n_group_posts`, `n_group_invites`, `n_group_audit_logs`, etc. | Groups, members, invites, group content, audit logs.       |

Legacy SQL and stage SQL remain in `doc/` and `data/` to trace historical designs. New environments should use `doc/neko_tribe-oracle-v2.sql` first.

## Tech Stack

| Area               | Technology                                                                                                               |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| Frontend           | Nuxt 4, Vue 3, TypeScript, Pinia, Nuxt UI, shadcn-nuxt, Tailwind CSS 4                                                   |
| Backend            | Nitro Server API, h3, TypeScript                                                                                         |
| API Versioning     | Legacy `server/api/v1`, resource-style `server/api/v2`                                                                   |
| Database           | Oracle 19c, accessed via `oracledb`                                                                                      |
| Cache and Realtime | Redis 7 via `ioredis`; Nitro WebSocket route at `server/routes/_ws.ts`                                                   |
| Auth               | JWT access/refresh tokens, HttpOnly cookies, bcrypt                                                                      |
| Email              | SMTP via `nodemailer`                                                                                                    |
| Media              | Local file uploads, `formidable`, `file-type`, `sharp`, `ffprobe-static`, optional system `ffmpeg` for legacy thumbnails |
| Runtime            | Node.js 22, Yarn 1.x, Docker Compose                                                                                     |

## Requirements

- Node.js 22+
- Yarn 1.x; if `yarn` is missing, run `corepack enable` first.
- Docker Desktop or Docker Engine with Compose v2.
- Windows is recommended with PowerShell; Git Bash, WSL, macOS shell, or Linux shell can run `.sh` scripts.
- If using the built-in Oracle image, Oracle Container Registry access and license acceptance are required.
- Optional: for legacy v1 media thumbnails outside Docker, install `ffmpeg` locally.

## Quick Start: Local Development

For "frontend and Nitro dev servers run on the host, Oracle/Redis run in Docker":

```bash
corepack enable
yarn install --frozen-lockfile
cp .env.example .env
docker compose up -d redis oracle19c db-init
yarn dev
```

Access:

- App: `http://localhost:3000`
- WebSocket test page: `http://localhost:3000/ws`
- Host Oracle: `localhost:5501/ORCLPDB1`
- Host Redis: `localhost:6379`

PowerShell equivalent:

```powershell
corepack enable
yarn install --frozen-lockfile
Copy-Item .env.example .env
docker compose up -d redis oracle19c db-init
yarn dev
```

## Quick Start: Full Docker Stack

For "app, Redis, Oracle, Nginx all run in Docker":

```bash
cp .env.example .env
docker compose up -d
```

PowerShell:

```powershell
Copy-Item .env.example .env
docker compose up -d
```

Access:

- App container port: `http://localhost:30001`
- Nginx reverse proxy and upload static: `http://localhost:30002`
- SentimentFlow backend API: `http://localhost:8846/health`, `http://localhost:8846/docs`
- SentimentFlow frontend UI: `http://localhost:30008`
- Oracle listener port: `localhost:5501`
- Oracle EM Express: `http://localhost:5500/em`

Oracle usually needs a few minutes on first boot. If the Oracle image fails to pull, run `docker login container-registry.oracle.com`, accept the database image license in the Oracle Container Registry; or use an external Oracle instance and update `.env`.
You can also switch `ORACLE_IMAGE` in `.env` to a domestic mirror, for example `registry.cn-hangzhou.aliyuncs.com/zhuyijun/oracle:19c`.

## SentimentFlow Runtime

SentimentFlow is included in both Compose files as two services:

- `sentimentflow`: FastAPI backend for prediction, training, models, and statistics.
- `sentimentflow-frontend`: Next.js frontend UI that talks to the backend through `BACKEND_API_URL`.

Keep the NekoTribe proxy enabled in `.env` when the app should call the sentiment-analysis backend:

```env
SENTIMENTFLOW_ENABLED=true
SENTIMENTFLOW_HOST_PORT=8846
SENTIMENTFLOW_CONTAINER_PORT=8846
SENTIMENTFLOW_FRONTEND_HOST_PORT=30008
SENTIMENTFLOW_FRONTEND_CONTAINER_PORT=3000
```

Port changes are centralized in `.env`. `SENTIMENTFLOW_HOST_PORT` controls host/browser access to the backend, for example `http://localhost:${SENTIMENTFLOW_HOST_PORT}/docs`; `SENTIMENTFLOW_CONTAINER_PORT` controls the backend process port, Docker target port, backend healthcheck, NekoTribe app-to-backend URL, and the frontend container's `BACKEND_API_URL`. `SENTIMENTFLOW_FRONTEND_HOST_PORT` controls host/browser access to the SentimentFlow UI, and `SENTIMENTFLOW_FRONTEND_CONTAINER_PORT` controls the Next.js server port inside the frontend container.

### Docker Deployment: GHCR Images

`docker-compose.yml` pulls the published GitHub Container Registry images:

- Backend: `ghcr.io/cthaat/sentimentflow-backend:latest`
- Frontend: `ghcr.io/cthaat/sentimentflow-frontend:latest`

```bash
cp .env.example .env
docker compose pull sentimentflow sentimentflow-frontend
docker compose up -d
```

PowerShell:

```powershell
Copy-Item .env.example .env
docker compose pull sentimentflow sentimentflow-frontend
docker compose up -d
```

Default URLs:

- NekoTribe app: `http://localhost:30001`
- SentimentFlow backend health: `http://localhost:8846/health`
- SentimentFlow backend docs: `http://localhost:8846/docs`
- SentimentFlow frontend UI: `http://localhost:30008`

To pin an automatic build, set image variables to specific tags in `.env`, for example:

```env
SENTIMENTFLOW_IMAGE=ghcr.io/cthaat/sentimentflow-backend:sha-1d3ecf9
SENTIMENTFLOW_FRONTEND_IMAGE=ghcr.io/cthaat/sentimentflow-frontend:sha-1d3ecf9
```

### Docker Deployment: Build From GitHub

`docker-compose.local.yml` builds NekoTribe locally and builds both SentimentFlow services from the Git source configured by `SENTIMENTFLOW_GIT_REPO` and `SENTIMENTFLOW_GIT_REF`. This avoids Docker Compose remote build-context path issues on Windows because the inline Dockerfiles clone the repository inside the build stage.

```bash
cp .env.example .env
docker compose -f docker-compose.local.yml up -d --build
```

PowerShell:

```powershell
Copy-Item .env.example .env
docker compose -f docker-compose.local.yml up -d --build
```

To rebuild only SentimentFlow:

```bash
docker compose -f docker-compose.local.yml up -d --build sentimentflow sentimentflow-frontend
```

`SENTIMENTFLOW_GIT_REPO` defaults to `https://github.com/Cthaat/SentimentFlow.git`, and `SENTIMENTFLOW_GIT_REF` defaults to `main`; change `SENTIMENTFLOW_GIT_REF` to another branch, tag, or commit when needed. For example, use `SENTIMENTFLOW_GIT_REF=1d3ecf9` to build that commit. Model artifacts are kept in the `sentimentflow-models` Docker volume or the local `./sentimentflow-models` folder in local-build mode.

`SENTIMENTFLOW_PIP_INDEX_URL` and `SENTIMENTFLOW_TORCH_INDEX_URL` both default to `https://pypi.org/simple` for the local backend build. The backend installs torch in its own cacheable layer so CUDA-capable torch dependencies can be reused across rebuilds instead of being downloaded every time. If package downloads are slow, you can change the PyPI index to a mirror, but hash mismatch errors usually mean the mirror or network returned a different file, so switch back to the official index before retrying.

CUDA training requires Docker GPU access. The Compose files request all available GPUs for the `sentimentflow` backend by default through `SENTIMENTFLOW_GPUS=all`, and pass `NVIDIA_DRIVER_CAPABILITIES=compute,utility` into the container. Before training, verify that your NVIDIA driver, Docker Desktop/Engine GPU support, and CUDA container runtime are working.

### Non-Docker SentimentFlow Deployment

Use this when NekoTribe runs on the host and only Oracle/Redis are in Docker, or when SentimentFlow is started manually.

1. Start NekoTribe host development dependencies:

```powershell
Copy-Item .env.example .env
docker compose up -d redis oracle19c db-init
```

2. Start the SentimentFlow backend:

```powershell
git clone https://github.com/Cthaat/SentimentFlow.git
Set-Location SentimentFlow\backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
$env:SENTIMENTFLOW_PROJECT_ROOT = (Resolve-Path ..)
$env:SENTIMENTFLOW_CONTAINER_PORT = "8846"
uvicorn app.main:app --host 0.0.0.0 --port 8846
```

3. Start the SentimentFlow frontend in another terminal:

```powershell
Set-Location SentimentFlow\frontend
corepack enable
yarn install --frozen-lockfile
$env:BACKEND_API_URL = "http://localhost:8846"
$env:BACKEND_API_TIMEOUT_MS = "10000"
yarn dev --hostname 0.0.0.0 --port 30008
```

For a production-style frontend outside Docker:

```powershell
yarn build
$env:PORT = "30008"
$env:HOSTNAME = "0.0.0.0"
$env:BACKEND_API_URL = "http://localhost:8846"
yarn start
```

4. In NekoTribe `.env`, keep `SENTIMENTFLOW_BASE_URL` empty when using the default backend host port, or set it explicitly when the backend is elsewhere:

```env
SENTIMENTFLOW_ENABLED=true
SENTIMENTFLOW_BASE_URL=
SENTIMENTFLOW_HOST_PORT=8846
SENTIMENTFLOW_CONTAINER_PORT=8846
```

Then run `yarn dev`. Verify `http://localhost:8846/health`, `http://localhost:8846/docs`, `http://localhost:30008`, and NekoTribe's SentimentFlow integration page.

## Scripts

| Script                        | Purpose                                                                                                        |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `scripts/dev.sh`              | If `.env` is missing, copy template, start Redis/Oracle containers, install dependencies, then run `yarn dev`. |
| `scripts/start.sh`            | If `.env` is missing, copy template, then build and start full Docker stack.                                   |
| `scripts/init-db.sh`          | Manual fallback for executing `doc/neko_tribe-oracle-v2.sql` outside the default Compose flow.                 |
| `scripts/docker-init-db.sh`   | Internal Compose entrypoint used by the `db-init` service.                                                     |
| `scripts/dev.ps1`             | PowerShell equivalent of `scripts/dev.sh`.                                                                     |
| `scripts/start.ps1`           | PowerShell equivalent of `scripts/start.sh`.                                                                   |
| `scripts/init-db.ps1`         | PowerShell equivalent of `scripts/init-db.sh`.                                                                 |
| `yarn dev`                    | Start Nuxt dev server.                                                                                         |
| `yarn build`                  | Build Nuxt production output.                                                                                  |
| `yarn start` / `yarn preview` | Preview the built Nuxt output locally.                                                                         |
| `yarn typecheck`              | Run Nuxt TypeScript type checking.                                                                             |
| `yarn docker:up`              | Run `docker compose up -d`.                                                                                    |
| `yarn docker:down`            | Stop the Docker Compose stack.                                                                                 |

The default Compose flow runs `db-init` once before `app` starts. It checks `NEKO_APP.N_USERS` first and skips initialization when the schema already exists. The v2 SQL creates users, tablespaces, tables, sequences, triggers, views, and seed data; manual `scripts/init-db.*` is kept for external Oracle instances or recovery work.

## Environment Variables

Copy `.env.example` to `.env`. For non-local environments, replace all example secrets and passwords.

| Variable                  | Required    | Example                           | Purpose                                                         |
| ------------------------- | ----------- | --------------------------------- | --------------------------------------------------------------- |
| `NODE_ENV`                | Yes         | `development`                     | Runtime environment.                                            |
| `APP_PORT`                | Docker      | `30001`                           | App container port mapped to host.                              |
| `NGINX_PORT`              | Docker      | `30002`                           | Nginx container port mapped to host.                            |
| `ACCESS_SECRET`           | Yes         | Replace with a random long secret | JWT access token signing secret.                                |
| `ACCESS_EXPIRES_IN`       | Yes         | `900`                             | Access token TTL in seconds.                                    |
| `REFRESH_SECRET`          | Yes         | Replace with a random long secret | JWT refresh token signing secret.                               |
| `REFRESH_EXPIRES_IN`      | Yes         | `2592000`                         | Refresh token TTL in seconds.                                   |
| `ORACLE_HOST`             | Yes         | `localhost`                       | Oracle host for host dev mode.                                  |
| `ORACLE_PORT`             | Yes         | `5501`                            | Oracle port for host dev mode.                                  |
| `ORACLE_SERVICE_NAME`     | Yes         | `ORCLPDB1`                        | Oracle service name for connection pool.                        |
| `ORACLE_SID`              | No          | empty                             | Compatibility field; pool uses service name.                    |
| `ORACLE_USER`             | Yes         | `neko_app`                        | App schema user.                                                |
| `ORACLE_PASSWORD`         | Yes         | From v2 SQL                       | App schema password for local dev.                              |
| `ORACLE_POOL_MIN`         | No          | `2`                               | Oracle pool minimum connections.                                |
| `ORACLE_POOL_MAX`         | No          | `10`                              | Oracle pool maximum connections.                                |
| `ORACLE_POOL_INCREMENT`   | No          | `1`                               | Oracle pool growth step.                                        |
| `ORACLE_HOST_PORT`        | Docker      | `5501`                            | Oracle container `1521` mapped to host.                         |
| `ORACLE_EM_PORT`          | Docker      | `5500`                            | Oracle EM Express mapped port.                                  |
| `ORACLE_IMAGE`            | Docker      | `container-registry.oracle.com/database/enterprise:19.3.0.0` | Oracle image used by `oracle19c` and `db-init`.                 |
| `ORACLE_PWD`              | Docker/Init | Replace with a strong password    | SYS/SYSTEM password for the Oracle container and init scripts.  |
| `ORACLE_SYS_SERVICE_NAME` | Init        | `ORCLCDB`                         | CDB service name used by `db-init` and `scripts/init-db.*`.     |
| `DB_INIT_CHECK_TABLE`     | Init        | `N_USERS`                         | App schema table used by `db-init` to detect an initialized DB. |
| `DOCKER_ORACLE_HOST`      | Docker      | `oracle19c`                       | Oracle host inside the app container.                           |
| `DOCKER_ORACLE_PORT`      | Docker      | `1521`                            | Oracle port inside the app container.                           |
| `DOCKER_NODE_ENV`         | Docker      | `production`                      | App container runtime, fixed to production.                     |
| `DOCKER_REDIS_URL`        | Docker      | `redis://redis:6379`              | Redis URL inside the app container, overrides host `REDIS_URL`. |
| `REDIS_URL`               | No          | empty                             | Optional Redis URL; preferred by Redis utils if set.            |
| `REDIS_HOST`              | Yes         | `localhost`                       | Redis host for host dev mode.                                   |
| `REDIS_PORT`              | Yes         | `6379`                            | Redis port.                                                     |
| `REDIS_DB`                | No          | `0`                               | Redis database number.                                          |
| `REDIS_PASSWORD`          | No          | Replace with a strong password    | Redis password; compose service reads it from `.env`.           |
| `DOCKER_REDIS_HOST`       | Docker      | `redis`                           | Redis host inside the app container.                            |
| `DOCKER_REDIS_PORT`       | Docker      | `6379`                            | Redis port inside the app container.                            |
| `SMTP_HOST`               | Email       | `smtp.example.com`                | SMTP host for OTP and account emails.                           |
| `SMTP_PORT`               | Email       | `465`                             | SMTP port; current code uses secure SMTP.                       |
| `SMTP_USER`               | Email       | empty                             | SMTP username and sender.                                       |
| `SMTP_PASS`               | Email       | empty                             | SMTP password or app-specific password.                         |
| `NUXT_PUBLIC_WS_URL`      | No          | `ws://localhost:3000/_ws`         | Public WebSocket URL for local client.                          |
| `DOCKER_PUBLIC_WS_URL`    | Docker      | `ws://localhost:30001/_ws`        | Public WebSocket URL for Docker mode.                           |
| `NUXT_PUBLIC_API_BASE`    | No          | empty                             | Client API base; empty means same origin.                       |
| `SENTIMENTFLOW_ENABLED`   | No          | `true`                            | Toggle SentimentFlow integration and proxy access.              |
| `SENTIMENTFLOW_BASE_URL`  | No          | empty                             | Optional external SentimentFlow URL override; leave empty to derive host-dev access from `SENTIMENTFLOW_HOST_PORT`. |
| `SENTIMENTFLOW_TIMEOUT_MS` | No         | `10000`                           | Upstream proxy timeout in milliseconds.                         |
| `SENTIMENTFLOW_IMAGE`     | Docker      | `ghcr.io/cthaat/sentimentflow-backend:latest` | GHCR image pulled by `docker-compose.yml`.                      |
| `SENTIMENTFLOW_LOCAL_IMAGE` | Docker local | `sentimentflow-backend:local`   | Local image tag produced by `docker-compose.local.yml`.         |
| `SENTIMENTFLOW_FRONTEND_IMAGE` | Docker | `ghcr.io/cthaat/sentimentflow-frontend:latest` | SentimentFlow frontend GHCR image pulled by `docker-compose.yml`. |
| `SENTIMENTFLOW_FRONTEND_LOCAL_IMAGE` | Docker local | `sentimentflow-frontend:local` | SentimentFlow frontend image tag produced by `docker-compose.local.yml`. |
| `SENTIMENTFLOW_GIT_REPO` | Docker local | `https://github.com/Cthaat/SentimentFlow.git` | Git repository fetched inside the `docker-compose.local.yml` image build. |
| `SENTIMENTFLOW_GIT_REF` | Docker local | `main` | Git branch, tag, or commit fetched for local SentimentFlow builds. |
| `SENTIMENTFLOW_PIP_INDEX_URL` | Docker local | `https://pypi.org/simple` | Python package index used by the local SentimentFlow backend build. |
| `SENTIMENTFLOW_TORCH_INDEX_URL` | Docker local | `https://pypi.org/simple` | PyTorch package index used by the local SentimentFlow backend build; default keeps CUDA-capable torch available. |
| `SENTIMENTFLOW_TORCH_PACKAGE` | Docker local | `torch` | Torch package spec installed before the remaining backend requirements so Docker can cache the heavy CUDA dependency layer. |
| `SENTIMENTFLOW_GPUS` | Docker | `all` | GPU device request for the SentimentFlow backend container. |
| `SENTIMENTFLOW_NVIDIA_DRIVER_CAPABILITIES` | Docker | `compute,utility` | NVIDIA driver capabilities exposed to the SentimentFlow backend container for CUDA training. |
| `SENTIMENTFLOW_CONTAINER_PROJECT_ROOT` | Docker | `/workspace`             | SentimentFlow project root inside the image/container.          |
| `SENTIMENTFLOW_MODELS_DIR` | Docker      | `/workspace/models`               | Persistent model artifact mount target in the SentimentFlow container. |
| `SENTIMENTFLOW_HOST_PORT` | Docker      | `8846`                            | Host/browser port for SentimentFlow; change this for `localhost:<port>` access. |
| `SENTIMENTFLOW_CONTAINER_PORT` | Docker | `8846`                            | Container/internal port used by Uvicorn, Docker target port, healthcheck, and app-to-SentimentFlow Compose URL. |
| `SENTIMENTFLOW_FRONTEND_HOST_PORT` | Docker | `30008`                    | Host/browser port for the SentimentFlow frontend UI.            |
| `SENTIMENTFLOW_FRONTEND_CONTAINER_PORT` | Docker | `3000`                  | Container/internal port used by the Next.js frontend server, Docker target port, and frontend healthcheck. |

## External Services

| Service             | Purpose                                                                            | Local Startup                                                                               | Configuration                                                                 |
| ------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Oracle 19c          | Primary DB for users, posts, groups, notifications, auth sessions, media metadata. | Included in `docker compose up -d`; `db-init` applies the v2 baseline before app startup. | `ORACLE_*` in `.env`.                                                         |
| Redis 7             | v1 OTP storage, WebSocket pub/sub, realtime broadcasts.                            | `docker compose up -d redis`.                                                               | `REDIS_*` in `.env`.                                                          |
| SMTP                | Send OTP, password reset, and account emails.                                      | Any SMTP-compatible provider.                                                               | `SMTP_*` in `.env`.                                                           |
| Nginx               | Serve `/upload/` files and reverse proxy in Docker mode.                           | Included in `docker compose up -d`.                                                         | `nginx/nginx.compose.conf` for Docker; `nginx/nginx.conf` for host dev proxy. |
| File Upload Storage | Store user avatars and media files.                                                | Create under `upload/` as needed; git-ignored.                                              | Mount to `/usr/share/nginx/upload` in Nginx.                                  |
| Media Toolchain     | Validate images/video/audio and generate legacy thumbnails.                        | Docker image includes `ffmpeg`; host legacy flow needs system `ffmpeg`.                     | `sharp`, `file-type`, `ffprobe-static`, optional system `ffmpeg`.             |
| SentimentFlow backend + frontend | External sentiment analysis API and UI for predict, training, models, and admin operations. | GHCR mode: `docker compose up -d`; local build mode: `docker compose -f docker-compose.local.yml up -d --build`. | `SENTIMENTFLOW_*`; backend ports use `SENTIMENTFLOW_HOST_PORT` / `SENTIMENTFLOW_CONTAINER_PORT`, frontend ports use `SENTIMENTFLOW_FRONTEND_HOST_PORT` / `SENTIMENTFLOW_FRONTEND_CONTAINER_PORT`. |

Note: `doc/neko_tribe-oracle-v2.sql` is the current v2 dev baseline and is mounted into the `db-init` service. Files under `data/oracle-init/` are kept as historical group-module scripts because these scripts are not a full DB baseline.

## Documentation Index

| Document                                    | Description                                                                             |
| ------------------------------------------- | --------------------------------------------------------------------------------------- |
| `README.md`                                 | Project overview, architecture, startup, configuration, and deployment entry (English). |
| `doc/README.md`                             | Project overview and setup guide (Chinese).                                             |
| `docs/README.md`                            | New ops docs directory overview.                                                        |
| `doc/NekoTribe-V2接口与Oracle重构总设计.md` | v2 API and Oracle refactor design overview.                                             |
| `doc/NekoTribe-V2-Apifox接口详细文档.md`    | v2 API detailed specification.                                                          |
| `doc/NekoTribe-V2-Apifox导入.json`          | Apifox import file.                                                                     |
| `doc/API v2平滑迁移实战指南(新手版).md`     | v1 to v2 migration guide.                                                               |
| `doc/neko_tribe-oracle-v2.sql`              | v2 Oracle database baseline.                                                            |
| `doc/群组功能API文档.md`                    | Group API specification.                                                                |
| `doc/Token无感刷新实现文档.md`              | Token silent refresh design.                                                            |
| `doc/NekoTribe长期最终可执行路线图.md`      | Long-term roadmap.                                                                      |
| `config/versions/README.md`                 | Service version metadata.                                                               |
| `script/github/README.md`                   | Tagging and release automation scripts.                                                 |

## Engineering Conventions

- Prefer TypeScript types for business code to avoid implicit data drift.
- Keep v1 and v2 APIs isolated; v2 must not call v1 route logic.
- Shared capabilities may only live in `server/utils` or `server/models`, and must not depend on business modules.
- New APIs should use REST-style paths and HTTP methods.
- New env config must update `.env.example` and the README env table.
- New external services must be described in "External Services" with purpose, startup, and configuration.
- Uploads, database runtime data, caches, and build artifacts must not be committed to Git.

## Directory Structure

```text
NekoTribe/
├── app/                         # Nuxt 4 frontend: pages, layouts, components, stores, composables
├── server/                      # Nitro backend
│   ├── api/
│   │   ├── v1/                  # Legacy APIs, kept isolated
│   │   └── v2/                  # v2 API routes
│   ├── services/                # Business services, including services/v2
│   ├── models/                  # Shared DB models and domain mapping
│   ├── utils/                   # Request/response, DB, Redis common utilities
│   ├── types/                   # Global server/API types
│   ├── middleware/              # Server middleware
│   ├── plugins/                 # Nitro plugins: Redis, Oracle, logging, hooks
│   └── routes/                  # Non-API Nitro routes, including WebSocket
├── config/                      # Version metadata and service config
├── doc/                         # Existing product, API, and SQL docs
├── docs/                        # New ops manuals and runtime notes
├── data/                        # Local DB resources; runtime data is ignored
├── i18n/                        # Locale files
├── nginx/                       # Nginx reverse proxy and upload static config
├── public/                      # Public static assets
├── script/                      # Existing release automation scripts, do not rename
├── scripts/                     # Local dev, startup, and init scripts
├── .env.example                 # Redacted env template
├── docker-compose.yml           # Local dependencies and app orchestration
├── Dockerfile                   # Container build entry
└── README.md
```

Nuxt 4's standard frontend directory is `app/`. This project keeps `app/` (instead of forcing `client/`) to avoid routing, alias, and component path migration risk.

## Development and Verification

```bash
yarn install --frozen-lockfile
yarn typecheck
yarn build
```

Common checks:

```bash
docker compose config --quiet
bash -n scripts/dev.sh scripts/start.sh scripts/init-db.sh scripts/docker-init-db.sh
```

PowerShell script syntax check:

```powershell
$errors = @()
foreach ($f in 'scripts/dev.ps1','scripts/start.ps1','scripts/init-db.ps1') {
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$null, [ref]$errors) | Out-Null
}
if ($errors.Count) { $errors; exit 1 }
```

## Production Deployment

1. Prepare Oracle, Redis, SMTP, and persistent upload storage.
2. Create production `.env` from `.env.example`, replacing all secrets and passwords.
3. Review and run production DB init or migration SQL.
4. Build and run the app image:

```bash
docker build -t nekotribe:prod .
docker run --env-file .env -p 3000:3000 nekotribe:prod
```

5. Place Nginx or another reverse proxy in front of the app.
6. Mount persistent `upload/` storage and serve `/upload/` via the proxy or an equivalent object store.
7. Use HTTPS in production so auth cookies can safely enable `secure`.

The bundled `docker-compose.yml` targets local dev and small test environments. For production, prefer managed Oracle/Redis and avoid example passwords.

## FAQ

### Docker cannot pull the Oracle image

Set `ORACLE_IMAGE` in `.env` to choose the Oracle source. The default official image requires Oracle Container Registry access and license acceptance. If you want a domestic mirror, set it to a reachable image such as `registry.cn-hangzhou.aliyuncs.com/zhuyijun/oracle:19c`.

### Oracle errors after app startup

Confirm the `db-init` service exited successfully with `docker compose logs db-init`. Also confirm host dev uses `ORACLE_HOST=localhost`, `ORACLE_PORT=5501`, while Docker app mode uses `DOCKER_ORACLE_HOST=oracle19c`, `DOCKER_ORACLE_PORT=1521`.

### Redis authentication failure

Confirm `REDIS_PASSWORD` in `.env` matches the Redis container password. The built-in compose service reads the value from `.env`.

### `docker compose up -d` shows `dependency failed to start`, but `app` later becomes `healthy`

This is usually not a real failure, but a cold-start phase exceeding the early health check window. Current config has been adjusted:

- Health checks use `GET /api/health` instead of homepage SSR.
- Docker mode forces `DOCKER_REDIS_URL=redis://redis:6379` to avoid localhost inside containers.
- The `app` health window was widened to cover Oracle cold start and Nuxt first init.

If it still happens, check:

1. `docker logs -f nekotribe-app-1`
2. `docker inspect nekotribe-app-1 --format '{{json .State.Health}}'`
3. Whether `.env` mistakenly uses host-only addresses for Docker mode

### Email OTP not sending

Configure `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, and `SMTP_PASS`. The app can start without SMTP, but email OTP flow depends on it.

### Do I need Oracle Instant Client locally?

Current code does not call `oracledb.initOracleClient`, so it defaults to node-oracledb thin mode. Install Oracle Instant Client only if your target deployment needs thick mode features.

### Why both `doc/` and `docs/`

`doc/` stores existing product, API, and SQL docs with historical references. `docs/` is for new ops manuals and runtime notes, avoiding breaking old links.

### Why both `script/` and `scripts/`

`script/` is used by existing release/version automation. `scripts/` holds new dev, startup, and deployment helpers.
