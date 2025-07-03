# 标签自动化脚本使用说明

## 功能描述

这个脚本可以帮助你自动创建和推送标签，触发 GitHub Actions 工作流来自动更新版本信息。

## 使用方法

### 方法 1: 使用 npm/yarn 命令

```bash
# 使用 npm
npm run tag

# 使用 yarn
yarn tag

# 或者
npm run release
yarn release
```

### 方法 2: 直接运行脚本

```bash
node script/github/github-action.js
```

## 标签格式

标签必须遵循以下格式：

- `service-name/v1.0.0` - 正式版本
- `service-name/v1.2.1` - 修复版本  
- `service-name/v3.1.0-beta.1` - 预发布版本
- `service-name/v2.0.0-alpha.1` - 内测版本

## 工作流程

1. **运行脚本** - 执行 `npm run tag` 或 `yarn tag`
2. **输入标签名** - 按照格式输入，例如: `shadcn-ui/v1.0.0`
3. **输入描述** - 可选的标签描述信息
4. **确认创建** - 确认后脚本会自动创建并推送标签
5. **自动触发** - GitHub Actions 工作流自动触发
6. **自动更新** - 工作流会自动：
   - 创建/更新服务版本配置文件 (`config/versions/`)
   - 更新 README.md 中的版本徽章
   - 提交更改到当前分支
   - 创建 GitHub Release

## 注意事项

- 确保你在正确的分支上运行脚本
- 标签名不能重复（除非选择覆盖）
- 需要有推送权限到远程仓库
- GitHub Actions 需要 `NEKO_TOKEN` 密钥配置

## 示例

```bash
$ npm run tag

🚀 GitHub Action 标签自动化脚本
========================================
📌 当前分支: main

📝 请输入标签名
格式示例: service-name/v1.0.0 或 service-name/v1.0.0-beta.1
标签名: shadcn-ui/v1.0.0
标签描述 (可选): 初始版本发布

📋 标签信息确认:
   标签名: shadcn-ui/v1.0.0
   当前分支: main
   描述: 初始版本发布

确认创建并推送标签? (y/N): y

🏷️  创建标签...
✅ 标签创建成功
📤 推送标签到远程仓库...
✅ 标签推送成功

🎉 成功创建并推送标签: shadcn-ui/v1.0.0
📌 服务名: shadcn-ui
🔄 GitHub Action 工作流将自动触发
📝 版本更新将提交到当前分支: main
```

## 故障排除

如果遇到问题，请检查：

1. 是否在 Git 仓库中运行
2. 是否有未提交的更改
3. 标签格式是否正确
4. 是否有推送权限
5. GitHub Actions 是否正确配置
