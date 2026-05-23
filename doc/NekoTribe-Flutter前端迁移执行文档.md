# NekoTribe 前端迁移到 Flutter 执行文档

> 适用日期：2026-05-23  
> 适用仓库：`C:\Code\NekoTribe`  
> 目标：把当前 Nuxt 4 / Vue 3 前端迁移为 Flutter 多平台客户端，同时继续复用现有 `/api/v2/**`、`/_ws`、`/storage/**` 后端契约。  
> 使用方式：把本文档按阶段交给 AI，每次只执行一个阶段。每个阶段完成后先跑验收，再进入下一阶段。  
> 说明：用户需求中提到“把前端迁移到 Flutter”，同时又说“写出完整后端代码”。本文按“完整 Flutter 前端代码”来写；后端只列 Flutter 必须依赖的兼容改造项。如果后端已经按 Spring Boot 迁移文档实现，则 Flutter 端直接对接 Spring Boot。

## 0. 迁移结论

### 0.1 最重要的判断

Flutter 不是打包现有 Nuxt 页面，而是重写一个新的客户端。

可以复用：

- 后端 API 路径：`/api/v2/**`
- 后端响应结构：`code/message/data/meta`
- DTO 字段：`snake_case`
- 认证和会话规则
- WebSocket 路径：`/_ws`
- WebSocket JSON 消息协议
- 媒体访问路径：`/storage/**`
- 业务流程：注册、登录、发帖、评论、群组、聊天、通知、审核、AI 情感分析

不能直接复用：

- Nuxt 页面文件：`app/pages/**/*.vue`
- Vue 组件：`app/components/**/*.vue`
- shadcn-nuxt 组件
- Pinia store
- Vue composables
- Tailwind CSS 样式

因此迁移思路是：

```text
当前 Nuxt/Vue 前端
  app/api/v2/*          -> Flutter lib/core/network + lib/features/*/data
  app/types/v2.ts       -> Flutter freezed/json_serializable models
  app/services/*        -> Flutter repositories + mappers
  app/pages/*           -> Flutter screens
  app/components/*      -> Flutter widgets
  app/stores/user.ts    -> Flutter auth/session/settings providers
  useRealtimeSocket.ts  -> Flutter WebSocket service
```

### 0.2 推荐目标技术栈

Flutter 项目建议创建在仓库根目录：

```text
frontend_flutter/
```

推荐栈：

| 能力 | 推荐 |
|---|---|
| Flutter SDK | Flutter 3.x 稳定版 |
| 路由 | `go_router` |
| 状态管理 | `riverpod` / `flutter_riverpod` |
| HTTP | `dio` |
| JSON model | `freezed` + `json_serializable` |
| 安全存储 | `flutter_secure_storage` |
| 普通缓存 | `shared_preferences` |
| WebSocket | `web_socket_channel` |
| 图片缓存 | `cached_network_image` |
| 文件选择 | `file_picker` |
| 图片选择 | `image_picker` |
| MIME | `mime` |
| 国际化 | Flutter `intl` / `flutter_localizations` |
| 桌面窗口 | 可选 `window_manager` |
| 图表 | `fl_chart` 或 `syncfusion_flutter_charts`，优先 `fl_chart` |
| 表单校验 | 自写 validator 或 `reactive_forms`，第一版建议自写 |

第一版不要引入过多框架。核心目标是完整复刻业务，而不是做新的架构实验。

### 0.3 迁移前置条件

后端必须保持这些外部契约：

- v2 API 基础路径：`/api/v2/**`
- WebSocket：`/_ws`
- 静态资源：`/storage/**`
- 旧上传资源：`/uploads/**` 返回 410 或兼容跳转
- 健康检查：`/api/health`
- SentimentFlow 代理：`/api/v2/integrations/sentiment-flow/**`
- 响应结构：`{ code, message, data, meta }`
- 分页字段：`page`、`page_size`、`total`、`has_next`
- JSON 字段继续使用 `snake_case`

当前后端 v2 路由文件统计：

| 方法 | 数量 |
|---|---:|
| GET | 58 |
| POST | 38 |
| PUT | 13 |
| PATCH | 13 |
| DELETE | 26 |
| 总计 | 148 |

`doc/v2.openapi.json` 当前包含 89 个 paths 和 46 个 schemas，可作为接口文档参考，但不是唯一真相。Flutter 迁移时以这些文件为准：

- `app/types/v2.ts`
- `app/api/v2/*.ts`
- `app/services/*.ts`
- `server/api/v2/**/*.ts`
- `server/services/v2/*.ts`
- `server/routes/_ws.ts`
- `doc/NekoTribe-SpringBoot后端迁移执行文档.md`

## 1. 当前项目阅读结论

### 1.1 当前前端结构

```text
app/
  api/
    v2/
      client.ts             # v2Request / v2RequestData
      auth.ts               # 登录、注册、OTP、2FA、会话
      users.ts              # 用户资料、设置、关系
      posts.ts              # 帖子、评论、点赞、收藏、上传媒体
      groups.ts             # 群组、成员、邀请、群组帖子
      chat.ts               # 群聊频道、消息、私聊
      notifications.ts      # 通知列表、已读、删除、恢复
      moderation.ts         # 审核、举报、处罚、设置
    sentiment-flow/
      client.ts             # SentimentFlow 请求封装
      index.ts              # SentimentFlow 代理 API
  types/
    v2.ts                   # 核心 DTO 类型
    auth.ts                 # Auth VM
    users.ts                # 用户 VM
    posts.ts                # 帖子 VM
    groups.ts               # 群组 VM
    notifications.ts        # 通知 VM
    moderation.ts           # 审核 VM
    sentiment-flow.ts       # AI 情感分析 VM
  services/
    auth.ts                 # DTO -> VM 映射
    users.ts
    posts.ts
    groups.ts
    chat.ts
    notifications.ts
    moderation.ts
    sentiment-flow.ts
  composables/
    useApi.ts               # HTTP 统一封装、刷新 token、设备头、错误归一化
    useRealtimeSocket.ts    # WebSocket 客户端
    useNotificationMailbox.ts
    usePostFeed.ts
  stores/
    user.ts                 # 当前用户、偏好、会话
  pages/
    auth/
    account/
    groups/
    moderation/
    tweet/
    user/
    chat.vue
    meow.vue
    index.vue
  components/
    TweetCard.vue
    TweetComposer.vue
    ChatRoom.vue
    GroupManageModal.vue
    SecurityPage*.vue
    Moderation*.vue
```

Flutter 迁移时不要从 UI 开始硬写页面。应先把 `app/api/v2`、`app/types/v2.ts`、`app/services` 翻译成 Flutter 的 network、models、repositories，再写 screen。

### 1.2 当前后端契约

后端核心在：

```text
server/
  api/v2/**/*.ts
  services/v2/
    auth.ts
    users.ts
    posts.ts
    groups.ts
    chat.ts
    notifications.ts
    presence.ts
    moderation.ts
    media.ts
  routes/
    _ws.ts
    storage/[...segments].get.ts
  utils/
    v2.ts
    redis.ts
    wsSession.ts
```

`server/utils/v2.ts` 定义统一响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {},
  "meta": null
}
```

错误码：

| code | HTTP | 含义 |
|---:|---:|---|
| 40001 | 400 | 请求参数错误 |
| 40101 | 401 | 未认证或 token 无效 |
| 40301 | 403 | 权限不足 |
| 40401 | 404 | 资源不存在 |
| 40901 | 409 | 资源冲突 |
| 42201 | 422 | 业务规则不允许 |
| 50001 | 500 | 服务器内部错误 |

### 1.3 Flutter 最关键的后端适配点

当前 Web 前端使用 Cookie 认证：

- 登录接口：`POST /api/v2/auth/tokens`
- 刷新接口：`PATCH /api/v2/auth/tokens/current`
- 登出接口：`DELETE /api/v2/auth/tokens/current`
- 后端设置 HttpOnly Cookie：`access_token`、`refresh_token`
- 响应体中的 `tokens` 只包含：
  - `session_id`
  - `access_token_expires_at`
  - `refresh_token_expires_at`

当前后端中间件已经支持 `Authorization: Bearer <token>`，WebSocket 也支持：

1. `/_ws?token=<access_token>`
2. `Authorization: Bearer <access_token>`
3. Cookie `access_token`

但是 Flutter 客户端如果拿不到 token 字符串，使用 Bearer 会困难。

因此推荐后端做一个兼容增强：

```json
{
  "session_id": "session_xxx",
  "access_token": "jwt_access_token",
  "refresh_token": "jwt_refresh_token",
  "access_token_expires_at": "2026-05-23T12:00:00.000Z",
  "refresh_token_expires_at": "2026-06-22T12:00:00.000Z"
}
```

这属于向 `tokens` 对象增加字段，现有 Nuxt 前端会忽略额外字段，兼容性最好。

如果暂时不改后端，Flutter 也可以用 `dio_cookie_manager` + `cookie_jar` 维持 Cookie 会话，但 WebSocket 还要从 CookieJar 手动拼接 Cookie 头，长期维护不如 Bearer 清晰。

本迁移文档选择推荐路线：

```text
HTTP 请求：Authorization: Bearer <access_token>
刷新请求：POST/PATCH refresh endpoint 时携带 refresh_token
WebSocket：/_ws?token=<access_token> 或 Authorization header
安全存储：flutter_secure_storage
```

后端实现时仍然保留 Cookie，兼容旧 Web 前端。

## 2. Flutter 目标项目结构

创建：

```text
frontend_flutter/
  pubspec.yaml
  analysis_options.yaml
  lib/
    main.dart
    app.dart
    bootstrap.dart
    core/
      config/
        app_config.dart
        environment.dart
      constants/
        api_paths.dart
        storage_paths.dart
      network/
        api_client.dart
        api_response.dart
        api_exception.dart
        auth_interceptor.dart
        refresh_token_interceptor.dart
        request_headers.dart
      auth/
        token_pair.dart
        token_store.dart
        auth_session.dart
        auth_state.dart
      realtime/
        realtime_message.dart
        realtime_service.dart
        realtime_provider.dart
      storage/
        asset_url_resolver.dart
        media_picker_service.dart
      routing/
        app_router.dart
        route_guards.dart
      theme/
        app_theme.dart
        app_colors.dart
        app_text_styles.dart
      i18n/
        app_localizations.dart
      errors/
        error_mapper.dart
      pagination/
        page_meta.dart
        paged_result.dart
    shared/
      widgets/
        app_scaffold.dart
        app_bottom_nav.dart
        adaptive_page.dart
        avatar_view.dart
        media_grid.dart
        empty_state.dart
        loading_view.dart
        error_view.dart
        primary_button.dart
        confirm_dialog.dart
      utils/
        date_formatters.dart
        validators.dart
    features/
      auth/
      account/
      users/
      posts/
      media/
      notifications/
      groups/
      chat/
      moderation/
      sentiment_flow/
  test/
  integration_test/
```

每个 feature 内部统一结构：

```text
features/posts/
  data/
    posts_api.dart
    posts_repository.dart
  domain/
    post_models.dart
    post_state.dart
  presentation/
    screens/
    widgets/
    controllers/
```

AI 生成代码时必须遵守：

- 所有 DTO 都使用 `fromJson/toJson`
- 后端字段保持 `snake_case`
- Flutter UI 内部可以使用 camelCase
- Repository 层负责 DTO 到 UI model 的转换
- 不允许在 Widget 里直接拼 URL 或写 Dio 请求
- 不允许在 Widget 里直接读写 token
- 所有需要登录的页面走 auth guard

## 3. 全局模型和网络层

### 阶段 1：创建 Flutter 项目骨架

#### 目标

建立可运行的 Flutter 项目，先不写业务页面，只完成多平台工程、依赖、主题、路由空壳。

#### 创建命令

```powershell
flutter create frontend_flutter
cd frontend_flutter
flutter pub add dio flutter_riverpod go_router freezed_annotation json_annotation flutter_secure_storage shared_preferences web_socket_channel cached_network_image file_picker image_picker mime intl uuid
flutter pub add --dev build_runner freezed json_serializable flutter_lints
```

#### pubspec 关键依赖

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_localizations:
    sdk: flutter
  dio: ^5.0.0
  flutter_riverpod: ^2.0.0
  go_router: ^14.0.0
  freezed_annotation: ^2.0.0
  json_annotation: ^4.0.0
  flutter_secure_storage: ^9.0.0
  shared_preferences: ^2.0.0
  web_socket_channel: ^3.0.0
  cached_network_image: ^3.0.0
  file_picker: ^8.0.0
  image_picker: ^1.0.0
  mime: ^1.0.0
  intl: ^0.19.0
  uuid: ^4.0.0

dev_dependencies:
  build_runner: ^2.0.0
  freezed: ^2.0.0
  json_serializable: ^6.0.0
  flutter_lints: ^4.0.0
```

版本号由 AI 按当前 Flutter SDK 兼容性调整，不要固定到不可解析版本。

#### AppConfig

创建 `lib/core/config/app_config.dart`：

```dart
class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.wsBaseUrl,
    required this.storageBaseUrl,
  });

  final String apiBaseUrl;
  final String wsBaseUrl;
  final String storageBaseUrl;

  static const dev = AppConfig(
    apiBaseUrl: 'http://localhost:3000',
    wsBaseUrl: 'ws://localhost:3000/_ws',
    storageBaseUrl: 'http://localhost:3000',
  );
}
```

桌面端和 Android 模拟器注意：

- Windows/macOS/Linux 本机：`localhost`
- Android emulator 访问宿主机：`10.0.2.2`
- 真机：使用局域网 IP 或公网域名

#### 验收

- `flutter analyze` 通过。
- `flutter test` 通过。
- `flutter run -d windows` 能打开空壳。
- `flutter run -d chrome` 能打开空壳。
- App 首页显示基本导航框架。

#### 给 AI 的提示词

```text
执行《NekoTribe 前端迁移到 Flutter 执行文档》的阶段 1。
在仓库根目录创建 frontend_flutter，初始化 Flutter 项目。
只创建工程骨架、依赖、AppConfig、空路由、主题和一个空首页。
不要实现任何业务接口。
完成后运行 flutter analyze 和 flutter test。
```

### 阶段 2：统一响应、异常和 Dio 客户端

#### 目标

把当前 `app/api/v2/client.ts` 和 `app/composables/useApi.ts` 的核心行为迁移为 Flutter 网络层。

必须实现：

- `ApiResponse<T>`
- `ApiMeta`
- `ApiException`
- `ApiClient`
- `AuthInterceptor`
- `RefreshTokenInterceptor`
- `x-request-id`
- `x-client-platform: flutter`
- `x-device-fingerprint`
- `x-device-info`
- 401 自动刷新
- auth entry paths 不触发刷新重试
- refresh path 不触发递归刷新

#### Dart 响应模型

```dart
class ApiMeta {
  const ApiMeta({
    this.page,
    this.pageSize,
    this.total,
    this.hasNext,
    this.limit,
  });

  final int? page;
  final int? pageSize;
  final int? total;
  final bool? hasNext;
  final int? limit;

  factory ApiMeta.fromJson(Map<String, dynamic> json) => ApiMeta(
        page: json['page'] as int?,
        pageSize: json['page_size'] as int?,
        total: json['total'] as int?,
        hasNext: json['has_next'] as bool?,
        limit: json['limit'] as int?,
      );
}

class ApiResponse<T> {
  const ApiResponse({
    required this.code,
    required this.message,
    required this.data,
    required this.meta,
  });

  final int code;
  final String message;
  final T data;
  final ApiMeta? meta;
}
```

#### auth entry paths

这些路径遇到 401 不要自动刷新：

```text
/api/v2/auth/otp
/api/v2/auth/otp/verification
/api/v2/auth/registration
/api/v2/auth/tokens
/api/v2/auth/two-factor/challenges
/api/v2/auth/two-factor/challenges/{id}
/api/v2/auth/password-reset
```

refresh path：

```text
/api/v2/auth/tokens/current
```

#### 请求头规则

每个请求都带：

```text
x-request-id: uuid
x-client-platform: flutter
x-device-fingerprint: stable uuid from secure storage
x-device-info: platform/version/model
Authorization: Bearer <access_token>    # 登录后
```

#### 错误映射

后端 v2 错误通常是：

```json
{
  "code": 40101,
  "message": "未认证或 token 无效",
  "data": null,
  "meta": null
}
```

Flutter 需要把它映射为：

```dart
class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.data,
  });
}
```

UI 不直接展示 Dio 原始错误。统一展示 `ApiException.message`。

#### 验收

- 能请求 `/api/health`。
- 访问受保护接口未登录时得到统一 `ApiException(40101)`。
- 登录接口 401 不触发刷新。
- 普通接口 401 会触发一次刷新，刷新失败后清理登录态。
- `x-device-fingerprint` 多次启动保持一致。

#### 给 AI 的提示词

```text
执行阶段 2。迁移 Nuxt 的 app/api/v2/client.ts 和 app/composables/useApi.ts 的核心行为到 Flutter。
创建 ApiResponse、ApiMeta、ApiException、ApiClient、AuthInterceptor、RefreshTokenInterceptor、TokenStore 和 DeviceHeaders。
保持 v2 响应 code/message/data/meta、snake_case 字段、auth entry path 不刷新、refresh path 不递归。
不要写业务页面。完成后为 ApiClient 写单元测试。
```

## 4. 认证和会话

### 阶段 3：Auth 模块

#### 源文件

- `app/api/v2/auth.ts`
- `app/services/auth.ts`
- `app/types/auth.ts`
- `app/pages/auth/login.vue`
- `app/pages/auth/sign-up.vue`
- `app/pages/auth/forgot-password.vue`
- `server/services/v2/auth.ts`
- `server/middleware/auth.ts`

#### 必须实现的接口

| 方法 | 路径 | Flutter 方法 |
|---|---|---|
| POST | `/api/v2/auth/otp` | `createOtp` |
| POST | `/api/v2/auth/otp/verification` | `verifyOtp` |
| POST | `/api/v2/auth/registration` | `register` |
| POST | `/api/v2/auth/tokens` | `login` |
| POST | `/api/v2/auth/two-factor/challenges/{id}` | `completeTwoFactorLogin` |
| PATCH | `/api/v2/auth/tokens/current` | `refreshCurrentToken` |
| DELETE | `/api/v2/auth/tokens/current` | `logoutCurrent` |
| POST | `/api/v2/auth/password-reset` | `passwordReset` |
| GET | `/api/v2/auth/sessions` | `listSessions` |
| DELETE | `/api/v2/auth/sessions/{id}` | `revokeSession` |
| DELETE | `/api/v2/auth/sessions/others` | `revokeOtherSessions` |

#### 后端兼容要求

为了 Flutter 原生客户端，Spring Boot 或现有后端需要返回 token 字符串：

```dart
class AuthTokenData {
  final String sessionId;
  final String? accessToken;
  final String? refreshToken;
  final DateTime accessTokenExpiresAt;
  final DateTime refreshTokenExpiresAt;
}
```

如果后端暂时不返回 token，则 Flutter 第一版可以启用 Cookie 模式：

- `dio_cookie_manager`
- `PersistCookieJar`
- WebSocket 连接前从 CookieJar 取 `access_token`
- 拼接 `Cookie: access_token=...`

但正式方案仍推荐 Bearer token。

#### 登录结果

登录返回两种情况：

```text
普通登录成功：
  user + tokens

需要二次验证：
  two_factor_required: true
  challenge_id
  account
  expires_at
```

Flutter 用 sealed union 表示：

```dart
sealed class LoginResult {}
class LoginSuccess extends LoginResult {}
class TwoFactorRequired extends LoginResult {}
```

#### 安全存储

登录成功后保存：

- access token
- refresh token
- session id
- access expires at
- refresh expires at
- current user summary

使用：

```text
flutter_secure_storage
```

不要把 token 存在 `shared_preferences`。

#### 页面

Flutter 页面：

```text
/auth/login
/auth/register
/auth/forgot-password
/auth/two-factor
```

登录流程：

1. 用户输入 account/password/remember_me。
2. 调用 `AuthRepository.login`。
3. 如果 `TwoFactorRequired`，跳转二次验证页。
4. 如果 `LoginSuccess`，保存 token 和用户，连接 WebSocket。
5. 跳转首页。

注册流程：

1. 输入 email。
2. `createOtp(type=register, channel=email)`。
3. 输入验证码。
4. `verifyOtp`。
5. 提交注册表单。
6. 注册成功后提示登录或自动进入登录。

忘记密码：

1. 输入 email。
2. `createOtp(type=password_reset)`。
3. 验证 OTP。
4. `passwordReset`。
5. 调用 `logoutCurrent` 清理旧会话。

#### 验收

- 错误密码显示后端 message，不崩溃。
- 登录成功后 token 保存在 secure storage。
- 重启 App 后仍能保持登录态。
- access token 过期后，普通接口触发刷新。
- refresh token 失效后清理登录态并跳转登录。
- 2FA 用户登录进入验证码页。
- WebSocket 登录后自动连接。

#### 给 AI 的提示词

```text
执行阶段 3。根据 app/api/v2/auth.ts、app/services/auth.ts、app/types/auth.ts 和 server/services/v2/auth.ts 实现 Flutter Auth 模块。
创建 auth models、AuthApi、AuthRepository、AuthController、登录/注册/忘记密码/二次验证页面。
必须支持 LoginSuccess 和 TwoFactorRequired 两种返回，token 使用 flutter_secure_storage。
认证请求保持 snake_case，请求头带 x-device-fingerprint 和 x-device-info。
完成后跑 flutter analyze、auth repository 单元测试，并手动说明登录验收步骤。
```

## 5. 用户、账号和设置

### 阶段 4：Users + Account 模块

#### 源文件

- `app/api/v2/users.ts`
- `app/services/users.ts`
- `app/services/account.ts`
- `app/types/users.ts`
- `app/types/account.ts`
- `app/pages/account/*.vue`
- `app/components/ProfileForm.vue`
- `app/components/SecurityPage*.vue`
- `server/services/v2/users.ts`

#### 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v2/users/me` | 当前用户 |
| PATCH | `/api/v2/users/me` | 更新个人资料 |
| DELETE | `/api/v2/users/me` | 删除账号 |
| PATCH | `/api/v2/users/me/email` | 修改邮箱 |
| PUT | `/api/v2/users/me/avatar` | 更新头像 |
| GET | `/api/v2/users/me/settings` | 用户设置 |
| PATCH | `/api/v2/users/me/settings` | 修改设置 |
| POST | `/api/v2/users/me/two-factor/setup` | 开启 2FA 准备 |
| POST | `/api/v2/users/me/two-factor/confirm` | 确认 2FA |
| DELETE | `/api/v2/users/me/two-factor` | 关闭 2FA |
| GET | `/api/v2/users/me/account-statements` | 账号声明 |
| PATCH | `/api/v2/users/me/account-statements/{id}` | 更新声明状态 |
| POST | `/api/v2/users/me/account-statements/{id}/appeals` | 申诉 |
| GET | `/api/v2/users` | 搜索用户 |
| GET | `/api/v2/users/{id}` | 用户主页 |
| GET | `/api/v2/users/{id}/analytics` | 用户统计 |
| GET | `/api/v2/users/{id}/analytics/daily` | 用户日统计 |
| GET | `/api/v2/users/{id}/followers` | 粉丝 |
| GET | `/api/v2/users/{id}/following` | 关注 |
| POST | `/api/v2/users/{id}/followers` | 关注 |
| DELETE | `/api/v2/users/{id}/followers` | 取消关注 |
| GET | `/api/v2/users/{id}/mutual-following` | 共同关注 |
| GET | `/api/v2/users/recommendations` | 推荐用户 |
| GET | `/api/v2/users/me/blocks` | 拉黑列表 |
| POST | `/api/v2/users/me/blocks/{target_id}` | 拉黑 |
| DELETE | `/api/v2/users/me/blocks/{target_id}` | 取消拉黑 |
| GET | `/api/v2/users/me/mutes` | 静音列表 |
| POST | `/api/v2/users/me/mutes/{target_id}` | 静音 |
| DELETE | `/api/v2/users/me/mutes/{target_id}` | 取消静音 |

#### Flutter 页面

```text
/account
/account/profile
/account/settings
/account/security
/account/active
/account/statements
/account/likes
/account/posts
/user/:id/profile
/user/:id/followers
/user/:id/following
```

#### 数据模型要点

`V2PublicUser` 和 `V2SelfUser` 必须完整翻译：

- `user_id`
- `username`
- `display_name`
- `avatar_url`
- `bio`
- `location`
- `website`
- `is_verified`
- `followers_count`
- `following_count`
- `posts_count`
- `likes_count`
- `relationship`
- `online_status`
- `last_seen_at`
- `email`
- `phone`
- `birth_date`
- `status`

Flutter UI 内部可以映射为：

```text
id
username
displayName
avatarUrl
followersCount
```

但 Repository 层必须保留 DTO 层。

#### 设置字段

必须支持：

- `two_factor_enabled`
- `login_alerts`
- `profile_visibility`
- `show_online_status`
- `allow_dm_from_strangers`
- `push_notification_enabled`
- `email_notification_enabled`
- `ai_sentiment_enabled`
- `ai_sentiment_model_id`
- `ai_sentiment_return_probabilities`
- `ai_sentiment_include_metadata`
- `ai_sentiment_top_k`

#### 验收

- 个人资料可读取和保存。
- 头像上传成功并刷新当前用户头像。
- 设置页保存后重新打开仍一致。
- 关注/取消关注会更新关系和粉丝数。
- 用户主页能显示在线状态。
- 账号安全页可管理 2FA 和活跃会话。

#### 给 AI 的提示词

```text
执行阶段 4。根据 app/api/v2/users.ts、app/services/users.ts、app/services/account.ts 实现 Flutter 用户和账号模块。
创建 UsersApi、UsersRepository、AccountRepository、current user provider、账号资料/设置/安全/会话/账号声明页面。
DTO 必须来自 app/types/v2.ts，字段保持 snake_case，UI model 可使用 camelCase。
完成后验证 /api/v2/users/me、settings、sessions、用户主页、关注/取消关注。
```

## 6. 媒体和资源

### 阶段 5：Media 模块

#### 源文件

- `app/api/v2/posts.ts` 中 `v2UploadMedia`
- `app/utils/assets.ts`
- `server/services/v2/media.ts`
- `server/storage/index.ts`
- `server/routes/storage/[...segments].get.ts`

#### 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/api/v2/media` | 上传帖子/聊天/群组媒体 |
| DELETE | `/api/v2/media/{id}` | 删除媒体 |
| GET | `/storage/**` | 访问文件 |

#### 上传规则

`POST /api/v2/media` 必须使用：

```text
multipart/form-data
```

字段：

| 字段 | 必填 | 说明 |
|---|---|---|
| `file` 或 `media` | 是 | 文件本体 |
| `alt_text` | 否 | 替代文本 |
| `description` | 否 | 媒体描述 |

后端限制：

- 头像只支持 jpg/png/gif，最大 10MB。
- 普通媒体支持图片、视频、音频、文档、文本、压缩包，最大 500MB。
- 资源 URL 使用 `/storage/**`。
- 旧 `/uploads/**` 要转换到 `/storage/**`。
- 空头像使用 `/storage/default-avatar.png`。

#### Flutter AssetUrlResolver

必须实现等价于 `app/utils/assets.ts` 的规则：

```text
空值、/default-avatar.png、default-avatar.png -> /storage/default-avatar.png
/storage/* -> 原样保留
/uploads/* -> /storage/*
/upload/* -> /storage/*
完整 URL 中 path 为 /uploads/* 或 /upload/* -> /storage/*
其他 URL -> 原样保留
```

#### 页面和组件

共享组件：

- `AvatarView`
- `MediaGrid`
- `MediaPreview`
- `MediaPickerButton`
- `UploadProgressOverlay`

被使用的模块：

- 发帖
- 回复
- 聊天发图/发文件
- 群组头像
- 个人头像
- 审核详情

#### 验收

- 选择图片后能上传。
- 上传成功返回 `V2MediaAsset`。
- `public_url` 可在 Flutter 图片组件中显示。
- `/uploads/xxx` 老 URL 会被转换为 `/storage/xxx`。
- 大文件超过限制时显示后端错误。
- 删除媒体后关联页面不崩溃。

#### 给 AI 的提示词

```text
执行阶段 5。迁移媒体上传和资源 URL 规范。
根据 app/api/v2/posts.ts 的 v2UploadMedia、app/utils/assets.ts、server/services/v2/media.ts 实现 Flutter MediaApi、MediaRepository、AssetUrlResolver 和共享媒体组件。
multipart 字段必须使用 file 或 media，支持 alt_text 和 description。
完成后用一张图片和一个不支持文件类型分别验证成功和失败。
```

## 7. 帖子、评论、标签和首页信息流

### 阶段 6：Posts 模块

#### 源文件

- `app/api/v2/posts.ts`
- `app/services/posts.ts`
- `app/types/posts.ts`
- `app/components/TweetCard.vue`
- `app/components/TweetComposer.vue`
- `app/components/CommentSection.vue`
- `app/pages/index.vue`
- `app/pages/meow.vue`
- `app/pages/tweet/[id].vue`
- `app/pages/tweet/[type]/[user].vue`
- `app/pages/tweet/search/[search].vue`
- `server/services/v2/posts.ts`

#### 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v2/posts` | 信息流/搜索 |
| POST | `/api/v2/posts` | 创建帖子 |
| GET | `/api/v2/posts/trending` | 热门帖子 |
| GET | `/api/v2/posts/{id}` | 帖子详情 |
| PUT | `/api/v2/posts/{id}` | 编辑帖子 |
| DELETE | `/api/v2/posts/{id}` | 删除帖子 |
| GET | `/api/v2/posts/{id}/analytics` | 帖子统计 |
| GET | `/api/v2/posts/{id}/comments` | 评论列表 |
| POST | `/api/v2/posts/{id}/comments` | 创建评论 |
| GET | `/api/v2/posts/{id}/replies` | 回复列表 |
| GET | `/api/v2/posts/{id}/retweets` | 转发列表 |
| POST | `/api/v2/posts/{id}/retweets` | 转发 |
| GET | `/api/v2/posts/{id}/likes` | 点赞用户 |
| POST | `/api/v2/posts/{id}/likes` | 点赞 |
| DELETE | `/api/v2/posts/{id}/likes` | 取消点赞 |
| POST | `/api/v2/posts/{id}/bookmarks` | 收藏 |
| DELETE | `/api/v2/posts/{id}/bookmarks` | 取消收藏 |
| DELETE | `/api/v2/comments/{id}` | 删除评论 |
| POST | `/api/v2/comments/{id}/likes` | 点赞评论 |
| DELETE | `/api/v2/comments/{id}/likes` | 取消点赞评论 |
| GET | `/api/v2/tags` | 标签搜索 |
| GET | `/api/v2/tags/trending` | 热门标签 |
| GET | `/api/v2/tags/{name}/posts` | 标签帖子 |
| GET | `/api/v2/tags/{name}/analytics` | 标签统计 |
| POST | `/api/v2/recommendations/feedback` | 推荐反馈 |
| POST | `/api/v2/reports` | 举报 |

#### Flutter 页面

```text
/
/meow
/tweet/:id
/tweet/search/:keyword
/tweet/:type/:user
/account/posts
/account/likes
```

#### 核心模型

必须完整翻译：

- `V2Post`
- `V2PostStats`
- `V2ViewerPostState`
- `V2Comment`
- `V2CommentStats`
- `V2CommentViewerState`
- `V2CreatePostPayload`
- `V2UpdatePostPayload`
- `V2RetweetPayload`
- `V2MediaAsset`
- `V2TagItem`
- `V2TagAnalytics`

#### UI 行为

帖子卡片要支持：

- 作者头像和名称
- 创建时间
- 正文
- 媒体网格
- 标签
- 点赞数、评论数、回复数、转发数、浏览数
- 当前用户是否已点赞
- 当前用户是否已收藏
- 当前用户是否可删除
- 点赞/取消点赞
- 收藏/取消收藏
- 转发
- 举报
- 删除

发帖框要支持：

- 文字
- 图片/视频/文件上传
- 可见性：`public`、`followers`、`mentioned`、`private`
- 标签
- 提及用户
- 媒体描述
- 回复、引用、转发

分页：

- `page`
- `page_size`
- `meta.has_next`
- 下拉刷新
- 上拉加载
- 防重复请求

#### 验收

- 未登录时首页可显示公开内容，操作类按钮提示登录。
- 登录后可发帖。
- 发帖后列表顶部出现新帖子或刷新可见。
- 点赞、收藏、转发状态立即更新。
- 详情页评论和回复可分页。
- 搜索页按关键词请求 `/api/v2/posts?q=...`。
- 删除自己的帖子后列表移除。

#### 给 AI 的提示词

```text
执行阶段 6。迁移帖子、评论、标签、首页信息流。
根据 app/api/v2/posts.ts、app/services/posts.ts、TweetCard.vue、TweetComposer.vue 和 tweet 页面实现 Flutter PostsApi、PostsRepository、PostFeedController、TweetCard、TweetComposer、PostDetailScreen。
保持所有 v2 DTO 字段、分页 meta、点赞/收藏/转发/评论/举报行为。
不要实现群组帖子，群组帖子在阶段 8。
```

## 8. 通知和实时连接

### 阶段 7：Realtime + Notifications 模块

#### 源文件

- `app/composables/useRealtimeSocket.ts`
- `app/plugins/realtime.client.ts`
- `app/composables/useNotificationMailbox.ts`
- `app/api/v2/notifications.ts`
- `app/services/notifications.ts`
- `server/routes/_ws.ts`
- `server/utils/redis.ts`
- `server/utils/wsSession.ts`
- `server/services/v2/notifications.ts`
- `server/services/v2/presence.ts`

#### 通知接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v2/notifications` | 通知列表 |
| PUT | `/api/v2/notifications/{id}/read-status` | 单条已读/未读 |
| PUT | `/api/v2/notifications/read-status` | 批量已读/未读 |
| DELETE | `/api/v2/notifications/{id}` | 删除通知 |
| PUT | `/api/v2/notifications/{id}/restore-status` | 恢复通知 |

#### WebSocket 连接

路径：

```text
/_ws
```

Flutter 推荐：

```text
ws://host/_ws?token=<access_token>
wss://host/_ws?token=<access_token>
```

不要使用：

```text
0.0.0.0
::
[::]
```

这些是服务端监听地址，不是客户端可访问地址。

#### 客户端发送消息

```json
{ "type": "ping" }
```

```json
{
  "type": "chat_join_channel",
  "data": { "channel_id": 1001 }
}
```

```json
{
  "type": "chat_leave_channel",
  "data": { "channel_id": 1001 }
}
```

#### 服务端消息类型

必须支持：

```text
broadcast
user_message
room_message
chat_message
chat_message_deleted
chat_message_updated
chat_reaction_updated
chat_channel_updated
direct_message
notification_created
notification_read_status_updated
notifications_read_status_updated
notification_deleted
notification_restored
presence_update
pong
error
system_notification
```

#### Flutter RealtimeService

职责：

- 登录后连接。
- 登出后断开。
- 每 30 秒发送 `ping`。
- 收到 `pong` 保持连接。
- 断线 3 秒后重连。
- token 刷新后使用新 token 重连。
- 支持订阅 listener。
- 支持进入聊天频道时发送 `chat_join_channel`。
- 支持离开频道时发送 `chat_leave_channel`。

#### 通知 UI

页面：

```text
/notifications
/user/:id/notifications
```

通知列表支持：

- 类型筛选：`all/like/retweet/comment/follow/mention/system`
- 只看未读
- 显示已删除
- 标记已读
- 批量已读
- 删除
- 恢复
- 收到实时消息后刷新当前列表

#### 验收

- 登录后 WebSocket 连接成功，收到 `system_notification`。
- 断网/断服后自动重连。
- 后端推送 `notification_created` 后 Flutter 显示本地 toast/snackbar，并刷新通知列表。
- 批量已读后 unread 状态更新。
- 登出后 WebSocket 断开且不再重连。

#### 给 AI 的提示词

```text
执行阶段 7。迁移实时连接和通知。
根据 useRealtimeSocket.ts、realtime.client.ts、useNotificationMailbox.ts、server/routes/_ws.ts 实现 Flutter RealtimeService、RealtimeProvider、NotificationsApi、NotificationsRepository、NotificationsScreen。
WebSocket 必须使用 /_ws，支持 token query、ping、重连、消息分发和通知事件刷新。
不要在这个阶段写聊天 UI，只实现实时基础设施和通知列表。
```

## 9. 群组

### 阶段 8：Groups 模块

#### 源文件

- `app/api/v2/groups.ts`
- `app/services/groups.ts`
- `app/types/groups.ts`
- `app/pages/groups.vue`
- `app/pages/groups/discover.vue`
- `app/pages/groups/my.vue`
- `app/pages/groups/invites.vue`
- `app/pages/groups/posts.vue`
- `app/components/CreateGroupModal.vue`
- `app/components/GroupManageModal.vue`
- `app/components/GroupDetailModal.vue`
- `server/services/v2/groups.ts`

#### 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v2/groups` | 发现群组 |
| POST | `/api/v2/groups` | 创建群组 |
| GET | `/api/v2/groups/popular` | 热门群组 |
| GET | `/api/v2/users/me/groups` | 我的群组 |
| GET | `/api/v2/users/me/group-invites` | 我的邀请 |
| GET | `/api/v2/groups/{id}` | 群组详情 |
| PATCH | `/api/v2/groups/{id}` | 更新群组 |
| DELETE | `/api/v2/groups/{id}` | 删除群组 |
| GET | `/api/v2/groups/by-slug/{slug}` | slug 查群组 |
| GET | `/api/v2/groups/invite-codes/{code}` | 邀请码详情 |
| POST | `/api/v2/groups/{id}/members/current` | 加入群组 |
| DELETE | `/api/v2/groups/{id}/members/current` | 退出群组 |
| GET | `/api/v2/groups/{id}/members` | 成员列表 |
| PUT | `/api/v2/groups/{id}/members/{user_id}/approval-status` | 审批成员 |
| DELETE | `/api/v2/groups/{id}/members/{user_id}` | 移除成员 |
| PATCH | `/api/v2/groups/{id}/members/{user_id}/role` | 改角色 |
| PATCH | `/api/v2/groups/{id}/members/{user_id}/roles` | 改角色兼容路径 |
| PUT | `/api/v2/groups/{id}/members/{user_id}/mute-status` | 禁言 |
| DELETE | `/api/v2/groups/{id}/members/{user_id}/mute-status` | 取消禁言 |
| PUT | `/api/v2/groups/{id}/ownership` | 转让群主 |
| GET | `/api/v2/groups/{id}/notification-preference` | 群通知设置 |
| PUT | `/api/v2/groups/{id}/notification-preference` | 更新群通知设置 |
| GET | `/api/v2/groups/{id}/invites` | 群邀请列表 |
| POST | `/api/v2/groups/{id}/invites` | 创建邀请 |
| POST | `/api/v2/groups/invites/{invite_id}/responses` | 接受/拒绝邀请 |
| GET | `/api/v2/groups/{id}/audit-logs` | 群审计日志 |

#### 群组帖子接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v2/groups/{id}/posts` | 群组帖子 |
| POST | `/api/v2/groups/{id}/posts` | 创建群组帖子 |
| GET | `/api/v2/groups/{id}/posts/{post_id}` | 群组帖子详情 |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}` | 删除群组帖子 |
| PUT | `/api/v2/groups/{id}/posts/{post_id}/pin-status` | 置顶 |
| POST | `/api/v2/groups/{id}/posts/{post_id}/likes` | 点赞 |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}/likes` | 取消点赞 |
| GET | `/api/v2/groups/{id}/posts/{post_id}/comments` | 评论 |
| POST | `/api/v2/groups/{id}/posts/{post_id}/comments` | 创建评论 |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}` | 删除评论 |
| POST | `/api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes` | 点赞评论 |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes` | 取消点赞评论 |

#### Flutter 页面

```text
/groups
/groups/discover
/groups/my
/groups/invites
/groups/posts
/groups/:id
/groups/:id/manage
/groups/:id/members
/groups/:id/posts/:postId
```

#### 权限

群组角色：

```text
owner
admin
moderator
member
```

注意：群组角色和审核后台权限不是一回事。审核后台权限由 `MODERATION_ADMIN_ACCOUNTS` 控制，不要把群组 moderator 当成审核管理员。

#### 验收

- 发现群组分页可用。
- 创建群组可上传头像。
- 加入/退出群组成功。
- 群组详情同时加载成员和帖子。
- 管理员可以审批、移除、禁言、改角色。
- 群组帖子可以发、删、评论、点赞、置顶。
- 邀请码和邀请列表可用。

#### 给 AI 的提示词

```text
执行阶段 8。迁移群组和群组帖子。
根据 app/api/v2/groups.ts、app/services/groups.ts、groups 页面和 server/services/v2/groups.ts 实现 Flutter GroupsApi、GroupsRepository、群组发现/我的群组/邀请/详情/管理/帖子页面。
注意群组角色和审核后台权限不能混淆。
群组头像上传复用阶段 5 的 MediaRepository。
```

## 10. 聊天和私聊

### 阶段 9：Chat 模块

#### 源文件

- `app/api/v2/chat.ts`
- `app/services/chat.ts`
- `app/pages/chat.vue`
- `app/components/ChatRoom.vue`
- `app/components/ChatInput.vue`
- `app/components/ChatChannelList.vue`
- `app/components/ChatDirectConversationList.vue`
- `server/services/v2/chat.ts`
- `server/routes/_ws.ts`

#### 群组聊天接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v2/chat/groups` | 有聊天权限的群组 |
| GET | `/api/v2/chat/groups/{id}/channels` | 频道列表 |
| POST | `/api/v2/chat/groups/{id}/channels` | 创建频道 |
| GET | `/api/v2/chat/groups/{id}/members` | 聊天成员 |
| GET | `/api/v2/chat/channels/{channel_id}/messages` | 消息列表 |
| POST | `/api/v2/chat/channels/{channel_id}/messages` | 发送消息 |
| PATCH | `/api/v2/chat/channels/{channel_id}` | 更新频道 |
| DELETE | `/api/v2/chat/channels/{channel_id}` | 删除频道 |
| PUT | `/api/v2/chat/channels/{channel_id}/read-status` | 已读 |
| PUT | `/api/v2/chat/channels/{channel_id}/mute-status` | 静音 |
| PATCH | `/api/v2/chat/messages/{message_id}` | 编辑消息 |
| DELETE | `/api/v2/chat/messages/{message_id}` | 删除消息 |
| PUT | `/api/v2/chat/messages/{message_id}/pin-status` | 置顶消息 |
| POST | `/api/v2/chat/messages/{message_id}/reactions` | 添加表情反应 |
| DELETE | `/api/v2/chat/messages/{message_id}/reactions` | 删除表情反应 |

#### 私聊接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v2/chat/direct-conversations` | 私聊会话列表 |
| POST | `/api/v2/chat/direct-conversations` | 创建私聊 |
| GET | `/api/v2/chat/direct-conversations/{conversation_id}/messages` | 私聊消息 |
| POST | `/api/v2/chat/direct-conversations/{conversation_id}/messages` | 发送私聊消息 |

#### Flutter 页面

```text
/chat
/chat/group/:groupId/channel/:channelId
/chat/direct
/chat/direct/:conversationId
```

移动端建议：

- 底部导航入口进入 Chat。
- Chat 首页显示两个 Tab：群组频道、私聊。
- 频道列表和消息列表在手机上分屏导航，不做桌面三栏。
- Windows/macOS/Linux 可以使用自适应布局做左频道列表、右消息窗口。

#### WebSocket 行为

进入频道详情：

```json
{
  "type": "chat_join_channel",
  "data": { "channel_id": 123 }
}
```

离开频道：

```json
{
  "type": "chat_leave_channel",
  "data": { "channel_id": 123 }
}
```

收到：

- `chat_message`：如果当前频道匹配，插入消息；否则更新频道 unread。
- `chat_message_updated`：替换消息。
- `chat_message_deleted`：标记删除或移除。
- `chat_reaction_updated`：更新 reaction。
- `direct_message`：如果当前私聊匹配，插入消息；否则更新私聊列表 preview/unread。
- `presence_update`：更新用户在线状态。

#### 验收

- 可加载聊天群组、频道、成员。
- 进入频道后发送 `chat_join_channel`。
- 两个账号打开同一频道，A 发消息，B 实时收到。
- 编辑/删除/表情反应实时更新。
- 私聊列表显示 last_message 和 unread_count。
- 对方在线时收到私聊实时更新。
- 发送图片/文件复用媒体上传。

#### 给 AI 的提示词

```text
执行阶段 9。迁移群聊和私聊。
根据 app/api/v2/chat.ts、app/services/chat.ts、app/pages/chat.vue、ChatRoom.vue、ChatDirectConversationList.vue 和 server/routes/_ws.ts 实现 Flutter Chat 模块。
必须接入阶段 7 的 RealtimeService，进入频道发送 chat_join_channel，离开频道发送 chat_leave_channel。
支持群聊、频道管理、消息列表、发送、编辑、删除、表情反应、置顶、已读、静音和私聊。
```

## 11. 审核后台和举报

### 阶段 10：Moderation 模块

#### 源文件

- `app/api/v2/moderation.ts`
- `app/services/moderation.ts`
- `app/pages/moderation*.vue`
- `app/components/Moderation*.vue`
- `server/services/v2/moderation.ts`

#### 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v2/moderation/stats` | 审核统计 |
| GET | `/api/v2/moderation/content` | 内容队列 |
| POST | `/api/v2/moderation/content/{post_id}/actions` | 单条内容操作 |
| POST | `/api/v2/moderation/content/bulk-actions` | 批量操作 |
| GET | `/api/v2/moderation/reports` | 举报列表 |
| PATCH | `/api/v2/moderation/reports/{report_id}` | 更新举报 |
| GET | `/api/v2/moderation/users` | 用户审核 |
| POST | `/api/v2/moderation/users/{user_id}/actions` | 用户处罚 |
| GET | `/api/v2/moderation/appeals` | 申诉列表 |
| PATCH | `/api/v2/moderation/appeals/{appeal_id}` | 处理申诉 |
| GET | `/api/v2/moderation/settings` | 审核设置 |
| PATCH | `/api/v2/moderation/settings` | 更新审核设置 |
| POST | `/api/v2/reports` | 普通用户举报入口 |

#### 权限

审核后台访问由后端 `requireModerationAccess()` 控制：

- 必须登录。
- 当前用户在 `n_users` 中 `is_active = 1` 且 `status = 'active'`。
- username 或 email 在 `MODERATION_ADMIN_ACCOUNTS` 中。
- 如果未配置，默认允许 `v2_admin`。
- `MODERATION_ALLOW_ALL=true` 仅开发环境使用，仍要求登录。

不要在 Flutter 前端硬编码“群组管理员可以访问审核后台”。

#### Flutter 页面

```text
/moderation
/moderation/content
/moderation/reports
/moderation/users
/moderation/settings
/moderation/appeals
```

#### 普通用户举报

在帖子卡片、群组帖子、评论等位置提供举报入口，调用：

```text
POST /api/v2/reports
```

请求：

```json
{
  "target_type": "post",
  "target_id": 100001,
  "reason": "spam",
  "description": "..."
}
```

#### 验收

- 普通用户看不到审核后台入口，直接访问返回 403 时显示无权限。
- 审核账号可进入统计、内容、举报、用户、设置。
- 内容审核操作后列表状态更新。
- 普通帖子卡片可举报。

#### 给 AI 的提示词

```text
执行阶段 10。迁移审核后台和普通举报。
根据 app/api/v2/moderation.ts、app/services/moderation.ts 和 server/services/v2/moderation.ts 实现 Flutter Moderation 模块。
严格遵守 requireModerationAccess 的权限含义，不要把群组角色当成审核权限。
普通举报入口要集成到帖子卡片和群组帖子中。
```

## 12. SentimentFlow AI 情感分析

### 阶段 11：SentimentFlow 模块

#### 源文件

- `app/api/sentiment-flow/client.ts`
- `app/api/sentiment-flow/index.ts`
- `app/services/sentiment-flow.ts`
- `app/types/sentiment-flow.ts`
- `app/components/AiSentimentControlPanel.vue`
- `app/components/AiSentimentPredictionDialog.vue`
- `server/api/v2/integrations/sentiment-flow/[...path].ts`
- `server/api/v2/integrations/sentiment-flow/config.get.ts`

#### 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v2/integrations/sentiment-flow/config` | 集成配置 |
| ANY | `/api/v2/integrations/sentiment-flow/**` | 代理 SentimentFlow |

#### Flutter 行为

保留后端代理路径，不直接访问 SentimentFlow 服务容器：

```text
Flutter -> Spring Boot/Nuxt backend -> SentimentFlow
```

必须实现：

- 检查配置是否启用。
- 文本预测。
- 模型列表。
- 当前模型。
- 设置当前模型。
- 训练任务状态。
- 账号设置里的 AI 偏好。
- 发帖时的预测弹窗。

#### 和用户设置联动

读取：

```text
GET /api/v2/users/me/settings
```

字段：

- `ai_sentiment_enabled`
- `ai_sentiment_model_id`
- `ai_sentiment_return_probabilities`
- `ai_sentiment_include_metadata`
- `ai_sentiment_top_k`

#### 验收

- `SENTIMENTFLOW_ENABLED=false` 时 UI 不发起预测，只显示未启用状态。
- 开启后可对发帖内容预测。
- 账号设置保存后发帖面板读取新配置。
- 代理错误显示后端 message。

#### 给 AI 的提示词

```text
执行阶段 11。迁移 SentimentFlow AI 情感分析前端。
根据 app/api/sentiment-flow、app/services/sentiment-flow.ts、AiSentimentControlPanel.vue、AiSentimentPredictionDialog.vue 实现 Flutter SentimentFlowApi、SentimentFlowRepository、账号 AI 设置和发帖预测弹窗。
所有调用必须走 /api/v2/integrations/sentiment-flow，不允许 Flutter 直接访问 SentimentFlow 容器地址。
```

## 13. 导航、布局、主题和国际化

### 阶段 12：UI Shell 和多端适配

#### 源文件

- `app/layouts/default.vue`
- `app/layouts/chat.vue`
- `app/components/AppSidebar.vue`
- `app/components/NavMain.vue`
- `app/components/NavSecondary.vue`
- `app/components/NavUser.vue`
- `app/assets/css/tailwind.css`
- `nuxt.config.ts` 的 i18n 配置

#### Flutter 导航结构

移动端：

```text
BottomNavigationBar:
  Home
  Explore
  Groups
  Chat
  Account
```

桌面端：

```text
NavigationRail 或侧边栏:
  首页
  搜索
  群组
  聊天
  通知
  账号
  审核
```

路由建议：

```text
/
/meow
/search
/groups
/chat
/notifications
/account
/moderation
```

#### 主题

迁移现有能力：

- light/dark/system
- compact mode 可选
- 字号 normal/large 可选
- 中文/英文

Flutter provider：

```text
ThemeController
LocaleController
UserPreferenceController
```

偏好保存：

- token 使用 secure storage
- UI 偏好使用 shared_preferences
- 后端用户设置仍调用 `/api/v2/users/me/settings`

#### 验收

- 手机宽度下底部导航正常。
- 桌面宽度下侧边导航正常。
- 深色/浅色切换不丢失。
- 中文/英文切换不丢失。
- 未登录只显示公开入口。
- 登录后显示通知、聊天、账号入口。

#### 给 AI 的提示词

```text
执行阶段 12。迁移全局布局、导航、主题和国际化。
参考 app/layouts/default.vue、app/layouts/chat.vue、AppSidebar.vue、NavUser.vue 和 nuxt.config.ts 的 i18n 配置。
Flutter 移动端使用底部导航，桌面端使用 NavigationRail/侧边栏。
不要阻塞业务页面，先把已有阶段页面接入统一 Shell。
```

## 14. 离线体验、缓存和性能

### 阶段 13：客户端缓存和体验优化

#### 目标

在主要功能完成后补客户端体验，不影响后端 Redis 缓存。

#### 推荐内容

- 当前用户缓存
- 首页最近一页缓存
- 通知未读数缓存
- 图片缓存
- 草稿缓存
- 失败重试
- 分页防抖
- 网络状态提示

#### 不要做

- 不要在 Flutter 客户端长期缓存敏感 token 以外的完整私密数据。
- 不要绕过后端权限判断。
- 不要自己在客户端推断审核权限。
- 不要让本地缓存覆盖服务器最新状态。

#### 验收

- 断网时已加载页面可阅读。
- 重新联网后可刷新。
- 草稿不会因切页面丢失。
- 图片缓存能减少重复加载。

#### 给 AI 的提示词

```text
执行阶段 13。为 Flutter 客户端添加非侵入式缓存和体验优化。
只缓存展示数据和草稿，不改变 API 契约，不绕过后端权限。
重点处理首页、通知、聊天列表、图片缓存、网络状态提示。
```

## 15. 多平台构建和发布

### 阶段 14：构建 Android/iOS/Windows/macOS/Linux/Web

#### 平台目标

| 平台 | 优先级 | 命令 |
|---|---|---|
| Android | 高 | `flutter build apk` / `flutter build appbundle` |
| Windows | 高 | `flutter build windows` |
| Web | 中 | `flutter build web` |
| iOS | 中 | `flutter build ios` |
| macOS | 中 | `flutter build macos` |
| Linux | 低 | `flutter build linux` |

#### 环境配置

不要把 API 地址写死在代码中。

建议支持：

```text
--dart-define=API_BASE_URL=https://api.example.com
--dart-define=WS_BASE_URL=wss://api.example.com/_ws
--dart-define=STORAGE_BASE_URL=https://api.example.com
```

`AppConfig` 从 `String.fromEnvironment` 读取。

#### Android 注意

开发环境如果后端是 HTTP，需要 Android network security config 允许明文 HTTP。

生产环境必须使用 HTTPS/WSS。

#### iOS 注意

开发环境 HTTP 需要 ATS 例外配置，生产环境必须 HTTPS/WSS。

#### 桌面注意

Windows/macOS/Linux 访问本机后端使用 `localhost`。

如果后端在 Docker 中，确认端口映射。

#### 验收

- Android debug 可登录。
- Windows release 可登录。
- Web build 可访问公开首页。
- HTTPS 环境下 WebSocket 使用 WSS。
- 打包后的 App 不包含开发环境密钥。

#### 给 AI 的提示词

```text
执行阶段 14。完善 Flutter 多平台构建配置。
支持 --dart-define 注入 API_BASE_URL、WS_BASE_URL、STORAGE_BASE_URL。
配置 Android/iOS 开发 HTTP 访问说明，生产必须 HTTPS/WSS。
验证 Android、Windows、Web 至少三个平台构建。
```

## 16. Nuxt 页面到 Flutter 页面映射

| Nuxt 页面 | Flutter 目标 |
|---|---|
| `app/pages/index.vue` | `HomeTimelineScreen` |
| `app/pages/meow.vue` | `ComposeTimelineScreen` 或首页发帖入口 |
| `app/pages/auth/login.vue` | `LoginScreen` |
| `app/pages/auth/sign-up.vue` | `RegisterScreen` |
| `app/pages/auth/forgot-password.vue` | `ForgotPasswordScreen` |
| `app/pages/account.vue` | `AccountShellScreen` |
| `app/pages/account/overview.vue` | `AccountOverviewScreen` |
| `app/pages/account/profile.vue` | `ProfileEditScreen` |
| `app/pages/account/settings.vue` | `AccountSettingsScreen` |
| `app/pages/account/security.vue` | `SecurityScreen` |
| `app/pages/account/active.vue` | `ActiveSessionsScreen` |
| `app/pages/account/statements.vue` | `AccountStatementsScreen` |
| `app/pages/account/posts.vue` | `MyPostsScreen` |
| `app/pages/account/likes.vue` | `LikedPostsScreen` |
| `app/pages/chat.vue` | `ChatShellScreen` |
| `app/pages/groups.vue` | `GroupsShellScreen` |
| `app/pages/groups/discover.vue` | `GroupDiscoverScreen` |
| `app/pages/groups/my.vue` | `MyGroupsScreen` |
| `app/pages/groups/invites.vue` | `GroupInvitesScreen` |
| `app/pages/groups/posts.vue` | `GroupPostFeedScreen` |
| `app/pages/moderation.vue` | `ModerationShellScreen` |
| `app/pages/moderation/content.vue` | `ModerationContentScreen` |
| `app/pages/moderation/reports.vue` | `ModerationReportsScreen` |
| `app/pages/moderation/users.vue` | `ModerationUsersScreen` |
| `app/pages/moderation/settings.vue` | `ModerationSettingsScreen` |
| `app/pages/tweet/[id].vue` | `PostDetailScreen` |
| `app/pages/tweet/search/[search].vue` | `PostSearchScreen` |
| `app/pages/tweet/[type]/[user].vue` | `UserTimelineScreen` |
| `app/pages/user/[id]/profile.vue` | `UserProfileScreen` |
| `app/pages/user/[id]/notifications.vue` | `NotificationsScreen` |
| `app/pages/about.vue` | `AboutScreen` |
| `app/pages/ws/index.vue` | 开发调试页，可不迁移 |
| `app/pages/test*.vue` | 测试页，不迁移到正式 App |

## 17. Flutter 模型生成规则

### 17.1 Source of truth

模型以 `app/types/v2.ts` 为主，`server/types/v2.d.ts` 和 `doc/v2.openapi.json` 为辅。

AI 应按下面顺序生成 Dart model：

1. `V2ApiMeta`
2. `V2ApiResponse<T>`
3. Auth models
4. User models
5. Media models
6. Post/comment/tag models
7. Notification models
8. Group models
9. Chat models
10. Moderation models
11. SentimentFlow models

### 17.2 JSON 命名

推荐：

```dart
@JsonSerializable(fieldRename: FieldRename.snake)
class PublicUserDto {
  const PublicUserDto({
    required this.userId,
    required this.username,
    required this.displayName,
  });

  final int userId;
  final String username;
  final String displayName;

  factory PublicUserDto.fromJson(Map<String, dynamic> json) =>
      _$PublicUserDtoFromJson(json);
}
```

如果字段名特殊，使用：

```dart
@JsonKey(name: 'user_id')
final int userId;
```

### 17.3 数字和布尔

后端部分布尔字段是 `0/1`：

- `is_verified`
- `is_active`
- `is_read`

Flutter DTO 层可以保持 `int`，UI model 层转换为 `bool`。

不要在 DTO 解析时盲目把所有 `int` 转 bool。

### 17.4 日期

后端日期是字符串：

```text
2026-05-23T12:00:00.000Z
```

DTO 层可以使用 `String`，UI model 层再解析为 `DateTime?`。第一版建议 DTO 保持 String，减少解析失败风险。

### 17.5 分页

Repository 返回：

```dart
class PagedResult<T> {
  const PagedResult({
    required this.items,
    required this.meta,
  });

  final List<T> items;
  final ApiMeta? meta;

  bool get hasNext => meta?.hasNext ?? false;
}
```

## 18. 完整 v2 路由索引

下面是当前 `server/api/v2` 的路由索引。Flutter 不一定每个阶段都实现全部 UI，但 API 层应按模块逐步覆盖。

| 方法 | 路径 |
|---|---|
| POST | `/api/v2/auth/otp` |
| POST | `/api/v2/auth/otp/verification` |
| POST | `/api/v2/auth/password-reset` |
| POST | `/api/v2/auth/registration` |
| DELETE | `/api/v2/auth/sessions/{id}` |
| GET | `/api/v2/auth/sessions` |
| DELETE | `/api/v2/auth/sessions/others` |
| POST | `/api/v2/auth/tokens` |
| DELETE | `/api/v2/auth/tokens/current` |
| PATCH | `/api/v2/auth/tokens/current` |
| POST | `/api/v2/auth/two-factor/challenges` |
| POST | `/api/v2/auth/two-factor/challenges/{id}` |
| DELETE | `/api/v2/chat/channels/{channel_id}` |
| PATCH | `/api/v2/chat/channels/{channel_id}` |
| GET | `/api/v2/chat/channels/{channel_id}/messages` |
| POST | `/api/v2/chat/channels/{channel_id}/messages` |
| PUT | `/api/v2/chat/channels/{channel_id}/mute-status` |
| PUT | `/api/v2/chat/channels/{channel_id}/read-status` |
| GET | `/api/v2/chat/direct-conversations` |
| POST | `/api/v2/chat/direct-conversations` |
| GET | `/api/v2/chat/direct-conversations/{conversation_id}/messages` |
| POST | `/api/v2/chat/direct-conversations/{conversation_id}/messages` |
| GET | `/api/v2/chat/groups` |
| GET | `/api/v2/chat/groups/{id}/channels` |
| POST | `/api/v2/chat/groups/{id}/channels` |
| GET | `/api/v2/chat/groups/{id}/members` |
| DELETE | `/api/v2/chat/messages/{message_id}` |
| PATCH | `/api/v2/chat/messages/{message_id}` |
| PUT | `/api/v2/chat/messages/{message_id}/pin-status` |
| DELETE | `/api/v2/chat/messages/{message_id}/reactions` |
| POST | `/api/v2/chat/messages/{message_id}/reactions` |
| DELETE | `/api/v2/comments/{id}` |
| DELETE | `/api/v2/comments/{id}/likes` |
| POST | `/api/v2/comments/{id}/likes` |
| DELETE | `/api/v2/groups/{id}` |
| GET | `/api/v2/groups/{id}` |
| PATCH | `/api/v2/groups/{id}` |
| GET | `/api/v2/groups/{id}/audit-logs` |
| GET | `/api/v2/groups/{id}/invites` |
| POST | `/api/v2/groups/{id}/invites` |
| DELETE | `/api/v2/groups/{id}/members/{user_id}` |
| PUT | `/api/v2/groups/{id}/members/{user_id}/approval-status` |
| DELETE | `/api/v2/groups/{id}/members/{user_id}/mute-status` |
| PUT | `/api/v2/groups/{id}/members/{user_id}/mute-status` |
| PATCH | `/api/v2/groups/{id}/members/{user_id}/role` |
| PATCH | `/api/v2/groups/{id}/members/{user_id}/roles` |
| DELETE | `/api/v2/groups/{id}/members/current` |
| POST | `/api/v2/groups/{id}/members/current` |
| GET | `/api/v2/groups/{id}/members` |
| GET | `/api/v2/groups/{id}/notification-preference` |
| PUT | `/api/v2/groups/{id}/notification-preference` |
| PUT | `/api/v2/groups/{id}/ownership` |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}` |
| GET | `/api/v2/groups/{id}/posts/{post_id}` |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}` |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes` |
| POST | `/api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes` |
| GET | `/api/v2/groups/{id}/posts/{post_id}/comments` |
| POST | `/api/v2/groups/{id}/posts/{post_id}/comments` |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}/likes` |
| POST | `/api/v2/groups/{id}/posts/{post_id}/likes` |
| PUT | `/api/v2/groups/{id}/posts/{post_id}/pin-status` |
| GET | `/api/v2/groups/{id}/posts` |
| POST | `/api/v2/groups/{id}/posts` |
| GET | `/api/v2/groups/by-slug/{slug}` |
| GET | `/api/v2/groups` |
| POST | `/api/v2/groups` |
| GET | `/api/v2/groups/invite-codes/{code}` |
| POST | `/api/v2/groups/invites/{invite_id}/responses` |
| GET | `/api/v2/groups/popular` |
| GET | `/api/v2/integrations/sentiment-flow/config` |
| DELETE | `/api/v2/media/{id}` |
| POST | `/api/v2/media` |
| PATCH | `/api/v2/moderation/appeals/{appeal_id}` |
| GET | `/api/v2/moderation/appeals` |
| POST | `/api/v2/moderation/content/{post_id}/actions` |
| POST | `/api/v2/moderation/content/bulk-actions` |
| GET | `/api/v2/moderation/content` |
| PATCH | `/api/v2/moderation/reports/{report_id}` |
| GET | `/api/v2/moderation/reports` |
| GET | `/api/v2/moderation/settings` |
| PATCH | `/api/v2/moderation/settings` |
| GET | `/api/v2/moderation/stats` |
| POST | `/api/v2/moderation/users/{user_id}/actions` |
| GET | `/api/v2/moderation/users` |
| DELETE | `/api/v2/notifications/{id}` |
| PUT | `/api/v2/notifications/{id}/read-status` |
| PUT | `/api/v2/notifications/{id}/restore-status` |
| GET | `/api/v2/notifications` |
| PUT | `/api/v2/notifications/read-status` |
| DELETE | `/api/v2/posts/{id}` |
| GET | `/api/v2/posts/{id}` |
| PUT | `/api/v2/posts/{id}` |
| GET | `/api/v2/posts/{id}/analytics` |
| DELETE | `/api/v2/posts/{id}/bookmarks` |
| POST | `/api/v2/posts/{id}/bookmarks` |
| GET | `/api/v2/posts/{id}/comments` |
| POST | `/api/v2/posts/{id}/comments` |
| DELETE | `/api/v2/posts/{id}/likes` |
| GET | `/api/v2/posts/{id}/likes` |
| POST | `/api/v2/posts/{id}/likes` |
| GET | `/api/v2/posts/{id}/replies` |
| GET | `/api/v2/posts/{id}/retweets` |
| POST | `/api/v2/posts/{id}/retweets` |
| GET | `/api/v2/posts` |
| POST | `/api/v2/posts` |
| GET | `/api/v2/posts/trending` |
| POST | `/api/v2/recommendations/feedback` |
| POST | `/api/v2/reports` |
| GET | `/api/v2/tags/{name}/analytics` |
| GET | `/api/v2/tags/{name}/posts` |
| GET | `/api/v2/tags` |
| GET | `/api/v2/tags/trending` |
| GET | `/api/v2/users/{id}` |
| GET | `/api/v2/users/{id}/analytics` |
| GET | `/api/v2/users/{id}/analytics/daily` |
| DELETE | `/api/v2/users/{id}/followers` |
| GET | `/api/v2/users/{id}/followers` |
| POST | `/api/v2/users/{id}/followers` |
| GET | `/api/v2/users/{id}/following` |
| GET | `/api/v2/users/{id}/mutual-following` |
| GET | `/api/v2/users/{id}/posts` |
| GET | `/api/v2/users` |
| DELETE | `/api/v2/users/me` |
| GET | `/api/v2/users/me` |
| PATCH | `/api/v2/users/me` |
| PATCH | `/api/v2/users/me/account-statements/{id}` |
| POST | `/api/v2/users/me/account-statements/{id}/appeals` |
| GET | `/api/v2/users/me/account-statements` |
| PUT | `/api/v2/users/me/avatar` |
| GET | `/api/v2/users/me/blocks` |
| DELETE | `/api/v2/users/me/blocks/{target_id}` |
| POST | `/api/v2/users/me/blocks/{target_id}` |
| GET | `/api/v2/users/me/bookmarks` |
| PATCH | `/api/v2/users/me/email` |
| GET | `/api/v2/users/me/group-invites` |
| GET | `/api/v2/users/me/groups` |
| GET | `/api/v2/users/me/likes` |
| GET | `/api/v2/users/me/mutes` |
| DELETE | `/api/v2/users/me/mutes/{target_id}` |
| POST | `/api/v2/users/me/mutes/{target_id}` |
| GET | `/api/v2/users/me/posts` |
| GET | `/api/v2/users/me/settings` |
| PATCH | `/api/v2/users/me/settings` |
| DELETE | `/api/v2/users/me/two-factor` |
| POST | `/api/v2/users/me/two-factor/confirm` |
| POST | `/api/v2/users/me/two-factor/setup` |
| GET | `/api/v2/users/recommendations` |

额外路由：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/_ws` | WebSocket |
| GET | `/api/health` | 健康检查 |
| GET | `/storage/**` | 资源读取 |
| GET | `/uploads/**` | 旧上传路径，当前返回 410 |
| ANY | `/api/v2/integrations/sentiment-flow/**` | SentimentFlow 代理 |

## 19. 总验收清单

每个阶段完成后至少检查：

- `flutter analyze`
- `flutter test`
- 关键页面手动运行
- 未登录/已登录两种状态
- token 过期刷新
- 后端错误显示
- 移动端窄屏
- 桌面端宽屏

完整迁移完成后检查：

1. 注册、登录、2FA、忘记密码。
2. 当前用户资料、设置、安全、会话。
3. 首页信息流、搜索、帖子详情。
4. 发帖、上传媒体、评论、点赞、收藏、转发、举报。
5. 用户主页、关注、粉丝、关注列表。
6. 通知列表、实时通知、已读、删除、恢复。
7. 群组发现、我的群组、邀请、管理、成员、群组帖子。
8. 群聊频道、私聊、实时消息、消息编辑删除、reaction。
9. 审核后台、举报、处罚、设置。
10. SentimentFlow 配置、预测、账号偏好。
11. Android debug。
12. Windows release。
13. Web build。

## 20. 总提示词模板

后续每次让 AI 执行一个阶段时，使用这个模板：

```text
你在 C:\Code\NekoTribe 仓库中工作。
请严格按照 doc/NekoTribe-Flutter前端迁移执行文档.md 的阶段 X 实现。

约束：
1. 不要修改无关文件。
2. Flutter 项目目录是 frontend_flutter。
3. API 契约以 app/types/v2.ts、app/api/v2/*.ts、server/api/v2/**/*.ts、server/services/v2/*.ts 为准。
4. 后端响应保持 code/message/data/meta。
5. JSON 字段保持 snake_case。
6. 需要登录的请求使用 Authorization: Bearer access_token。
7. token 存储使用 flutter_secure_storage。
8. WebSocket 保持 /_ws 和现有 JSON 协议。
9. 媒体资源统一使用 /storage/**。
10. 完成后必须运行 flutter analyze 和相关测试。

本次只做阶段 X，不提前实现后续阶段。
```

## 21. 推荐实施顺序

按下面顺序执行，风险最低：

1. 阶段 1：Flutter 项目骨架
2. 阶段 2：网络层、响应、异常、token
3. 阶段 3：认证
4. 阶段 5：媒体和资源
5. 阶段 4：用户、账号和设置
6. 阶段 6：帖子、评论、标签
7. 阶段 7：实时连接和通知
8. 阶段 8：群组
9. 阶段 9：聊天和私聊
10. 阶段 10：审核
11. 阶段 11：SentimentFlow
12. 阶段 12：导航、主题、国际化
13. 阶段 13：缓存和体验优化
14. 阶段 14：多平台构建和发布

这样排序的原因：

- 认证和网络层是一切业务的地基。
- 媒体上传会被头像、发帖、群组、聊天共同复用。
- 用户设置影响通知、在线状态、AI 情感分析。
- 实时连接先于聊天实现，可以先验证通知和 presence。
- 审核、SentimentFlow 属于后期功能，不应阻塞核心社交功能。

