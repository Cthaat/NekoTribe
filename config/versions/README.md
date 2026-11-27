> [!NOTE]
> **历史与局部引用说明**：本说明及文中 `service-name/v1.0.0` 标签触发自动更新 `config/versions/` 与 `README.md` 徽章的工作流已不再启用（现行 CI/发版流为 `.github/workflows/ci-nuxt.yml`、`publish-rolling.yml`、`release.yml`，使用 `master` 分支与 `vX.Y.Z` 标签）。目前仅 `Neko.json`、`oracle-server.json` 与 `shadcn-web.json` 仍被前端关于页面 `app/pages/about.vue` 静态导入（其中 `oracle-server.json` 亦被兼容路由 `server/api/v1/system/config.get.ts` 读取），三者已对齐至已发布的 `v2.0.0` 正式版基线（`tag: "v2.0.0"`、`releaseDate: "2026-11-21T10:21:42Z"`、`buildNumber: "2"` 对应 `Release All Stacks` 工作流第 2 次运行）；其余 JSON（含空文件 `nekotribe-service.json`）为历史遗留。

# 服务版本管理

此目录用于管理各个微服务的版本信息。

## 文件结构

- `{service-name}.json` - 每个服务的版本配置文件
- `services-summary.json` - 所有服务版本的汇总信息
- `README.md` - 本说明文件

## 版本配置文件格式

每个服务的版本配置文件包含以下信息：

```json
{
  "serviceName": "user-service",
  "version": "1.0.0",
  "tag": "user-service/v1.0.0",
  "releaseDate": "2025-07-01T12:00:00Z",
  "buildNumber": "123"
}
```

## 支持的标签格式

- `user-service/v1.0.0` - 正式版本
- `order-service/v1.2.1` - 修复版本
- `payment-service/v3.1.0-beta.1` - 预发布版本

## 自动化流程

当推送符合格式的版本标签时，GitHub Actions 会自动：

1. 解析服务名和版本号
2. 更新对应的版本配置文件
3. 更新 README.md 中的版本徽章
4. 创建 GitHub Release
5. 提交所有更改到主分支

## 版本规范

建议遵循语义化版本规范（SemVer）：

- `MAJOR.MINOR.PATCH`
- `MAJOR.MINOR.PATCH-prerelease.number`

示例：
- `1.0.0` - 首次发布
- `1.0.1` - 修复补丁
- `1.1.0` - 新功能
- `2.0.0` - 破坏性更改
- `2.0.0-beta.1` - 测试版本
