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
