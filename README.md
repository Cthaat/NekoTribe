# NekoTribe Flutter

[![最新发布](https://img.shields.io/github/v/release/Cthaat/NekoTribe?label=Release)](https://github.com/Cthaat/NekoTribe/releases/latest)
[![Flutter CI](https://github.com/Cthaat/NekoTribe/actions/workflows/ci-flutter.yml/badge.svg?branch=Flutter)](https://github.com/Cthaat/NekoTribe/actions/workflows/ci-flutter.yml?query=branch%3AFlutter)
[![后端镜像](https://img.shields.io/badge/Docker-GHCR-2496ED?logo=docker&logoColor=white)](https://github.com/Cthaat/NekoTribe/pkgs/container/nekotribe-nuxt)
[![Flutter 3.41.9](https://img.shields.io/badge/Flutter-3.41.9-02569B?logo=flutter&logoColor=white)](https://flutter.dev/)

NekoTribe 的 Windows、Android 与 Web 客户端，连接你选择的 Nuxt、Go 或 Rust 自托管后端。

| 分支 | 组件 | 适用场景 |
| --- | --- | --- |
| [`master`](https://github.com/Cthaat/NekoTribe/tree/master) | Nuxt 全栈 | 部署完整社区站点、API 和实时服务 |
| [`codex/go`](https://github.com/Cthaat/NekoTribe/tree/codex/go) | Go 原生后端 | 通过纯 Go 后端提供 API 和实时服务 |
| [`Rust`](https://github.com/Cthaat/NekoTribe/tree/Rust) | Rust 原生后端 | 通过 Rust 后端提供 API 和实时服务 |
| [`Flutter`](https://github.com/Cthaat/NekoTribe/tree/Flutter) | 跨端客户端 | Windows 安装或免安装运行、Android 安装、Web 自托管 |

## ⚡ 快速开始

### 下载 Release

1. 在 [GitHub Releases](https://github.com/Cthaat/NekoTribe/releases/latest) 下载并解压 `NekoTribe-<version>-flutter.zip`。`SHA256SUMS.txt` 提供下载校验值。
2. 选择平台启动客户端。

   | 平台 | 安装或运行 |
   | --- | --- |
   | Windows x64 安装版 | 双击 `windows/NekoTribe-<version>-windows-x64-setup.exe`，选择中文或英文及安装位置。安装后从开始菜单打开 **NekoTribe**。 |
   | Windows x64 绿色版 | 双击 `windows/portable/nekotribe.exe`。移动程序时请保留整个 `portable/` 目录。 |
   | Android | 将 `android/NekoTribe-<version>-android.apk` 复制到手机，在文件管理器打开，按系统提示允许当前来源安装应用。 |
   | Web 本机预览 | 安装 Node.js 22，进入 `web/`。Windows 双击 `start.cmd`，Linux 执行 `sh start.sh`，然后打开 `http://127.0.0.1:30004`。 |
   | Web 静态部署 | 进入 `web/`，参照 [Web 静态部署](#web-静态部署) 配置后端，再将 `web/site/` 设为 Nginx 的站点根目录。 |

3. 在客户端登录页打开 **服务器端点**，选择预设或填写实际的 API 基址。点 **检查 API 和媒体**，确认连通后保存，再返回登录。API 基址可包含反向代理路径，例如 `https://example.com/community`。Android 真机连接电脑上的服务时，使用手机能访问的电脑局域网地址，例如 `http://192.168.1.50:3000`。Android 模拟器可选 `http://10.0.2.2:3000`。

Android 原地升级需要前后版本使用相同签名。在不同签名的构建之间切换可能需要先卸载，卸载会清除应用的本地数据。

### Docker 部署

先部署一个兼容后端。各分支的部署指南提供可执行命令、`.env` 配置、容器清单及 Oracle 19c 授权和 Oracle Free 23 切换说明。

| 后端 | 官方镜像 | 部署指南 |
| --- | --- | --- |
| Nuxt | `ghcr.io/cthaat/nekotribe-nuxt:master` | [Nuxt 部署](https://github.com/Cthaat/NekoTribe/blob/master/README.md) |
| Go | `ghcr.io/cthaat/nekotribe-go:codex-go` | [Go 部署](https://github.com/Cthaat/NekoTribe/blob/codex/go/README.md) |
| Rust | `ghcr.io/cthaat/nekotribe-rust:rust` | [Rust 部署](https://github.com/Cthaat/NekoTribe/blob/Rust/README.md) |

客户端 Docker 预览启动 **1 个常驻 Nginx 容器**。初始化、Oracle、Redis 和可选 AI 服务由选定的后端部署提供。

| 容器 | 镜像 | 作用 | 默认端口 |
| --- | --- | --- | --- |
| `nekotribe-flutter-web` | `nginx:alpine` | 托管 Flutter Web 静态站点 | `127.0.0.1:30004 → 80/tcp` |

在已解压的 `web/` 目录下执行以下命令。输入前把 `API_BASE` 改为浏览器能够访问的后端地址。客户端只需配置连接地址，后端容器的 `.env` 按相应分支填写。

```bash
API_BASE=http://127.0.0.1:3000
curl -fsS "${API_BASE}/api/ready"
node configure-web.mjs site --api "$API_BASE"
docker run -d --rm --name nekotribe-flutter-web \
  -p 127.0.0.1:30004:80 \
  --mount "type=bind,source=$(pwd)/site,target=/var/www/nekotribe/site,readonly" \
  --mount "type=bind,source=$(pwd)/nginx.conf.example,target=/etc/nginx/conf.d/default.conf,readonly" \
  nginx:alpine
```

打开 `http://127.0.0.1:30004`。跨源时，在后端的 `CORS_ALLOWED_ORIGINS` 中加入这个地址。

### 源码运行

先按选定后端的指南配置 `.env` 和迁移数据库。使用 Flutter **3.41.9**、Dart **3.11.5**，并确保目标平台已通过 `flutter doctor -v` 检查。

```bash
git clone --branch Flutter --single-branch https://github.com/Cthaat/NekoTribe.git
cd NekoTribe
flutter pub get
flutter run -d chrome --web-port 30004
```

Windows 开发执行 `flutter run -d windows`。Android 通过 `flutter devices` 查找模拟器或已连接设备的 ID，再执行 `flutter run -d <device-id>`。也可用 Windows 的 `start-web.cmd` 或 Linux 的 `bash scripts/start-web.sh` 启动本机 Web 开发预览。

## 核心功能

- 浏览动态、发帖、关注、通知和账号安全。
- 参与群组、群帖、实时聊天和媒体分享。
- 处理举报、内容审核和申诉。
- 按后端与账号权限使用 AI 写作、知识问答、群运营草稿和审核建议。

## 连接与部署

| 入口 | 常用默认地址 |
| --- | --- |
| Nuxt 源码服务 | `http://127.0.0.1:3000` |
| Nuxt Docker 应用 / Nginx | `http://127.0.0.1:30001` / `http://127.0.0.1:30002` |
| Go | `http://127.0.0.1:30006` |
| Rust | `http://127.0.0.1:30003` |
| 统一网关 | `http://127.0.0.1:30005` |
| Flutter Web 本机预览 | `http://127.0.0.1:30004` |

自定义端点可单独填写 API、实时连接和媒体地址。只填 API 时，客户端从 API 基址推导 WebSocket 和媒体地址，并保留代理路径前缀。端点设置也可以通过应用内的 **恢复默认** 清除。发布后的 Web 配置与构建期 `--dart-define` 提供默认地址，用户已保存的端点优先。

Nuxt、Go、Rust 可共用同一套 Oracle 和 Redis。切换后端前请核对迁移、会话签名密钥、存储路径及文件基址，确保同一数据集的会话与媒体能够继续使用。AI 模型、知识索引、本地文件与 S3 由后端配置，客户端通过配置好的 API 访问。

### Web 静态部署

在解压包的 `web/` 目录运行以下命令，把示例域名换成实际服务地址。

```bash
node configure-web.mjs site --api https://api.example.com
node configure-web.mjs site --check
node check-deployment-endpoints.mjs --api https://api.example.com --origin https://site.example.com
```

- 分离部署时，`configure-web.mjs` 支持 `--realtime wss://socket.example.com`、`--media https://media.example.com` 和 `--share-site https://community.example.com`。最后一项设置群帖公共链接的前端地址。
- 以 `nginx.conf.example` 为起点，设置站点根目录和正式域名，启用 HTTPS。示例包含 SPA 路由回退、Wasm MIME 类型及 `app_config.json` 禁止缓存规则。
- 通过 HTTPS 登录远程站点，并为 API、文件和实时连接使用 HTTPS / WSS。跨源时在后端 `CORS_ALLOWED_ORIGINS` 配置站点实际的 Origin。本机预览可用回环地址。
- 发布到子路径时，构建时添加 `--base-href /community/`，并同步调整静态站点路由和公开配置文件的缓存规则。

## 源码构建与验收

Windows 需要 Visual Studio 的 **使用 C++ 的桌面开发** 工作负载。生成双语安装程序时使用 Inno Setup 6.5+，可通过 `INNO_SETUP_ISCC` 指定 `ISCC.exe` 路径。Android 需要 JDK 17、Android SDK Platform 36、Build Tools 及 NDK `28.2.13676358`。打包脚本使用 Node.js 22，APK 的结构校验还需要 PATH 中的 Python 3。

在 Flutter 工作树根目录执行。打包脚本输出到新的目录；下面的 Windows、Android、Web 分别在对应的构建环境执行。

```bash
flutter pub get
flutter analyze --no-fatal-infos
flutter test

# Windows x64
flutter build windows --release --no-pub --build-name 2.0.0
node scripts/package-windows.mjs --version v2.0.0 --out release-windows --require-installer

# Android
flutter build apk --release --no-pub
apksigner verify --verbose build/app/outputs/flutter-apk/app-release.apk
node scripts/package-android.mjs --version v2.0.0 --out release-android

# Web
flutter build web --no-pub --no-web-resources-cdn --pwa-strategy=none
node scripts/package-web.mjs build/web --out release-web
```

`apksigner` 位于 Android SDK 的 `build-tools/<version>/` 中。正式签名同时需要 `ANDROID_KEYSTORE_PATH`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS` 和 `ANDROID_KEY_PASSWORD`。四项都留空时，Release APK 使用本机构建环境的 debug 密钥签名。发布者应持有固定的签名密钥用于可升级的发布包。GitHub Actions 使用 `ANDROID_KEYSTORE_BASE64` 和三个签名凭据 Secret，在 runner 上临时生成密钥库文件。

## 项目结构

<details>
<summary>查看目录和技术栈</summary>

| 路径 | 内容 |
| --- | --- |
| `lib/` | Flutter UI、Riverpod 状态、go_router 路由、Dio API 和 WebSocket 客户端 |
| `assets/config/app_config.json` | 服务器端点默认值和预设 |
| `contracts/` | v2 OpenAPI 快照、来源与规范 |
| `windows/`、`android/`、`web/` | 支持的三个平台工程 |
| `scripts/`、`packaging/` | Web 配置与预览工具、平台打包入口和发布模板 |
| `test/` | 单元、组件及契约测试 |

</details>

## 参与开发

在并排检出的 `nuxt`、`go`、`rust`、`flutter` 工作树中，从 `nuxt/` 校验跨分支契约与台账。

```bash
node scripts/contracts.mjs check --workspace-root ..
node scripts/parity.mjs check --workspace-root ..
```

- [统一部署手册](https://github.com/Cthaat/NekoTribe/blob/master/docs/deployment.md)
- [Flutter CI 工作流](.github/workflows/ci-flutter.yml)
- [客户端契约来源](contracts/source.json)
