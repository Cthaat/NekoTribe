# Token 无感刷新实现文档

## 概述

本项目已实现了完整的 Token 无感刷新机制，当 API 请求遇到 401 错误（Token 过期）时，系统会自动刷新 Token 并重试请求，用户无需感知。

## 实现原理

### 1. 响应拦截器

在 `composables/useApi.ts` 和 `composables/useApiFetch.ts` 中添加了响应错误拦截器：

- 监听所有 API 请求的 401 错误响应
- 检测到 401 错误时，自动调用 Token 刷新接口
- 刷新成功后，自动重试原始请求
- 排除刷新接口本身（避免死循环）

### 2. 防重复刷新机制

在 `stores/user.ts` 的 `refreshAccessToken` 函数中实现：

- 使用 Promise 缓存机制
- 多个并发请求触发刷新时，只执行一次刷新操作
- 所有请求等待同一个刷新 Promise 完成

### 3. 两种请求方式支持

#### apiFetch（用于事件驱动请求）

```typescript
// 自动处理 401 错误并重试
const response = await apiFetch('/api/v1/some-endpoint', {
  method: 'POST',
  body: { data: 'value' }
});
```

#### useApiFetch（用于组合式 API）

```typescript
// 自动处理 401 错误并重试
const { data, error, refresh } = useApiFetch(
  '/api/v1/some-endpoint',
  {
    method: 'GET'
  }
);
```

## 核心代码改动

### 1. composables/useApi.ts

```typescript
// 添加了 onResponseError 拦截器
async onResponseError({ response, options: requestOptions }) {
  if (response.status === 401 && !path.includes('/auth/refresh')) {
    const { usePreferenceStore } = await import('~/stores/user');
    const preferenceStore = usePreferenceStore();
    await preferenceStore.refreshAccessToken();

    // 重试原始请求
    return $fetch(path, {
      ...(requestOptions as any),
      baseURL: config.public.apiBase
    } as any);
  }
}
```

### 2. composables/useApiFetch.ts

```typescript
// 添加了 watch 监听错误并自动重试
watch(originalError, async newError => {
  if (newError && (newError as any).statusCode === 401) {
    const { usePreferenceStore } = await import(
      '~/stores/user'
    );
    const preferenceStore = usePreferenceStore();
    await preferenceStore.refreshAccessToken();

    // 自动重新请求
    if (originalRefresh) {
      await originalRefresh();
    }
  }
});
```

### 3. stores/user.ts

```typescript
// 防重复刷新机制
let refreshPromise: Promise<void> | null = null;

async function refreshAccessToken() {
  if (refreshPromise) {
    return refreshPromise;
  }

  refreshPromise = (async () => {
    try {
      const response = await apiFetch(
        '/api/v1/auth/refresh',
        {
          method: 'GET',
          headers: {
            Authorization: `Bearer ${preferences.value.access_token}`
          }
        }
      );

      if (response.code === 200) {
        setAuthTokens(
          response.data.accessToken,
          response.data.refreshToken
        );
      }
    } finally {
      refreshPromise = null;
    }
  })();

  return refreshPromise;
}
```

## 测试方法

### 0. 使用测试页面（推荐）

访问 `/test-token-refresh` 页面，该页面提供了可视化的测试界面：

```
http://localhost:3000/test-token-refresh
```

测试页面功能：

- 📊 实时显示 Token 信息和剩余时间
- 🚀 发起需要认证的 API 请求（自动测试刷新机制）
- 🔄 手动刷新 Token
- ⚠️ 篡改 Token（模拟过期场景）
- 🗑️ 清除所有 Token
- 📝 实时操作日志显示

### 1. 手动测试 Token 过期

可以通过以下方式测试：

#### 方法 A：修改 Token 过期时间（推荐）

1. 在 `.env` 文件中临时修改 `ACCESS_EXPIRES_IN` 为很短的时间（如 10s）
   ```
   ACCESS_EXPIRES_IN=10s
   ```
2. 重启开发服务器
3. 登录后等待 10 秒
4. 执行任何需要认证的操作（如发推文、点赞等）
5. 观察浏览器控制台，应该看到：
   ```
   [apiFetch] 检测到401错误，尝试刷新token
   [PreferenceStore] 开始刷新access token
   [PreferenceStore] 刷新成功，更新令牌
   [apiFetch] Token刷新成功，重试原始请求
   ```
6. 操作应该成功完成，用户无感知

#### 方法 B：篡改现有 Token

1. 打开浏览器开发者工具 -> Application/存储 -> Cookies
2. 找到 `user-preferences-and-auth` cookie
3. 修改其中的 `access_token` 值（随意改几个字符）
4. 刷新页面
5. 执行任何需要认证的操作
6. 观察控制台日志

#### 方法 C：使用心跳检测（已有功能）

1. 项目已有 `plugins/heartbeat.client.ts`，每 30 秒检查一次 Token
2. 当 Token 剩余时间少于 60 秒时，自动刷新
3. 可以观察控制台日志：
   ```
   [Heartbeat] Token 剩余有效期: XX 秒
   [Heartbeat] Token 即将过期，正在主动刷新...
   ```

### 2. 并发请求测试

测试防重复刷新机制：

```javascript
// 在浏览器控制台执行
// 同时发起多个请求
Promise.all([
  fetch('/api/v1/tweets/timeline', {
    headers: { Authorization: 'Bearer invalid_token' }
  }),
  fetch('/api/v1/notifications', {
    headers: { Authorization: 'Bearer invalid_token' }
  }),
  fetch('/api/v1/users/suggestions', {
    headers: { Authorization: 'Bearer invalid_token' }
  })
]);
```

应该只看到一次刷新日志：

```
[PreferenceStore] 开始刷新access token
[PreferenceStore] Token刷新已在进行中，复用现有请求
[PreferenceStore] Token刷新已在进行中，复用现有请求
```

## 注意事项

### 1. 刷新 Token 接口不会被拦截

`/api/v1/auth/refresh` 接口本身不会被拦截处理，避免死循环。

### 2. Refresh Token 过期处理

如果 Refresh Token 也过期了，系统会：

1. 清除所有 Token
2. 跳转到登录页
3. 用户需要重新登录

### 3. 服务端中间件

`server/middleware/auth.ts` 会验证 Token 并返回 401 错误，触发客户端刷新机制。

### 4. Cookie 存储

Token 存储在 Cookie 中（`user-preferences-and-auth`），同时包含：

- `access_token`
- `refresh_token`
- 其他用户偏好设置

## 流程图

```
用户发起请求
    ↓
apiFetch/useApiFetch
    ↓
服务端验证 Token
    ↓
Token 有效？
    ├─ 是 → 返回数据 → 完成
    └─ 否 → 返回 401
           ↓
       响应拦截器捕获 401
           ↓
       调用 refreshAccessToken()
           ↓
       刷新成功？
           ├─ 是 → 重试原始请求 → 返回数据 → 完成
           └─ 否 → 清除 Token → 跳转登录页
```

## 相关文件

- `composables/useApi.ts` - apiFetch 实现
- `composables/useApiFetch.ts` - useApiFetch 实现
- `stores/user.ts` - Token 管理和刷新逻辑
- `server/middleware/auth.ts` - 服务端 Token 验证
- `server/api/v1/auth/refresh.get.ts` - 刷新 Token 接口
- `plugins/heartbeat.client.ts` - 主动检测和刷新

## 总结

无感刷新机制已完整实现，具备以下特性：
✅ 自动检测 401 错误
✅ 自动刷新 Token
✅ 自动重试失败请求
✅ 防止重复刷新
✅ 支持并发请求
✅ 主动心跳检测
✅ 用户完全无感知
