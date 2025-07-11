<div align="center">

# NekoTribe

> 哈基米哦那没录多，阿西噶压库那鲁  
> 一段一段带一段,一段咚鸡烤盒蒜  
> 曼波！

</div>

---

<div align="center">
    
![版本](https://img.shields.io/badge/版本-v1.0.0-blue.svg)
![oracle-server](https://img.shields.io/badge/oracle--server-v1.4.1-blue.svg)
![开发状态](https://img.shields.io/badge/%E5%BC%80%E5%8F%91%E7%8A%B6%E6%80%81-%E6%AD%A3%E5%9C%A8%E5%BC%80%E5%8F%91-yellow.svg)

</div>

## Welcome

- A blog website project built on Nuxt3 + Vuetify, including complete user management, tweet publishing, likes and other functions.
  - 一个基于 Nuxt3 + Vuetify 构建的博客网站项目，包含完整的用户管理、推文发布、点赞等功能喵。

## 🚀 部署地址

- [预览地址](https://neko-tribe.vercel.app)

## 🛠️ 技术栈

| 前端框架 | [![Nuxt](https://img.shields.io/badge/Nuxt-3.12.3-00C58E.svg?logo=nuxt.js&logoColor=white)](https://nuxt.com/) | [![Vue.js](https://img.shields.io/badge/Vue.js-3.4.0-4FC08D.svg?logo=vue.js&logoColor=white)](https://vuejs.org/) | [![Vuetify](https://img.shields.io/badge/Vuetify-3.6.13-1867C0.svg?logo=vuetify&logoColor=white)](https://vuetifyjs.com/zh-Hans/) | [![TypeScript](https://img.shields.io/badge/TypeScript-5.0-3178C6.svg?logo=typescript&logoColor=white)](https://www.typescriptlang.org/) |
| :------: | :------------------------------------------------------------------------------------------------------------: | :---------------------------------------------------------------------------------------------------------------: | :-------------------------------------------------------------------------------------------------------------------------------: | :--------------------------------------------------------------------------------------------------------------------------------------: |

| 状态管理 | [![Pinia](https://img.shields.io/badge/Pinia-2.1.6-yellow.svg?logo=pinia&logoColor=white)](https://pinia.vuejs.org/) | [![Persistedstate](https://img.shields.io/badge/Persistedstate-3.2.0-green.svg)](https://github.com/prazdevs/pinia-plugin-persistedstate) |
| :------: | :------------------------------------------------------------------------------------------------------------------: | :---------------------------------------------------------------------------------------------------------------------------------------: |

| 后端 & 数据库 | [![Nitro](https://img.shields.io/badge/Nitro-2.8.1-purple.svg)](https://nitro.unjs.io/) | [![Oracle](https://img.shields.io/badge/Oracle-19c+-F80000.svg?logo=oracle&logoColor=white)](https://www.oracle.com/database/) | [![SQLite](https://img.shields.io/badge/SQLite-3.46-003B57.svg?logo=sqlite&logoColor=white)](https://github.com/WiseLibs/better-sqlite3) | [![JWT](https://img.shields.io/badge/JWT-9.0.2-black.svg)](https://jwt.io/) |
| :-----------: | :-------------------------------------------------------------------------------------: | :----------------------------------------------------------------------------------------------------------------------------: | :--------------------------------------------------------------------------------------------------------------------------------------: | :-------------------------------------------------------------------------: |

| 认证 & 安全 | [![bcrypt](https://img.shields.io/badge/bcrypt-5.1.1-brown.svg)](https://github.com/kelektiv/node.bcrypt.js) |
| :---------: | :----------------------------------------------------------------------------------------------------------: |

| UI & 样式 | [![Vuetify Module](https://img.shields.io/badge/Vuetify%20Module-0.9.0-1867C0.svg)](https://vuetify-nuxt-module.netlify.app/) | [![Color Mode](https://img.shields.io/badge/Color%20Mode-3.3.2-blue.svg)](https://color-mode.nuxtjs.org/) | [![MDI](https://img.shields.io/badge/Material%20Design%20Icons-7.3.67-2196F3.svg)](https://pictogrammers.com/library/mdi/) | [![Element Plus](https://img.shields.io/badge/Element%20Plus-2.4.2-409EFF.svg)](https://element-plus.org/) |
| :-------: | :---------------------------------------------------------------------------------------------------------------------------: | :-------------------------------------------------------------------------------------------------------: | :------------------------------------------------------------------------------------------------------------------------: | :--------------------------------------------------------------------------------------------------------: |

| 国际化 & 工具 | [![i18n](https://img.shields.io/badge/i18n-8.0.0-green.svg)](https://i18n.nuxtjs.org/) | [![Day.js](https://img.shields.io/badge/Day.js-1.11.10-orange.svg)](https://day.js.org/) | [![Formidable](https://img.shields.io/badge/Formidable-3.5.1-red.svg)](https://github.com/node-formidable/formidable) |
| :-----------: | :------------------------------------------------------------------------------------: | :--------------------------------------------------------------------------------------: | :-------------------------------------------------------------------------------------------------------------------: |

| 代码规范 | [![ESLint](https://img.shields.io/badge/ESLint-8.55.0-4B32C3.svg?logo=eslint&logoColor=white)](https://eslint.org/) | [![Prettier](https://img.shields.io/badge/Prettier-3.1.0-F7B93E.svg?logo=prettier&logoColor=black)](https://prettier.io/) |
| :------: | :-----------------------------------------------------------------------------------------------------------------: | :-----------------------------------------------------------------------------------------------------------------------: |

## ✨ 功能特性

### 🔐 用户管理系统

- [x] **用户注册** - 邮箱密码注册，密码 bcrypt 加密
- [x] **用户登录** - JWT token 身份验证
- [x] **用户注销** - 清除登录状态
- [x] **用户资料管理**
  - [x] 头像上传与更新
  - [x] 邮箱修改
  - [x] 用户名修改
  - [x] 年龄设置
  - [x] 用户ID显示
- [x] **账户删除** - 密码确认后删除账户
- [ ] 关注系统（待实现）
- [ ] 粉丝系统（待实现）

### 📝 推文管理系统

- [x] **推文发布** - 支持标题、正文、封面图片
- [x] **推文删除** - 作者可删除自己的推文
- [x] **推文查看** - 详情页展示完整内容
- [x] **推文列表** - 分页展示所有推文
- [x] **我的文章** - 查看个人发布的推文
- [ ] 推文修改（待实现）
- [x] **推文点赞** - 点赞/取消点赞功能
- [x] **我的点赞** - 查看已点赞的推文
- [ ] 推文评论（UI已实现，后端待开发）
- [ ] 推文转发（待实现）

### 🎨 推文组成

- [x] **正文内容** - 富文本支持
- [x] **多媒体支持**
  - [x] 封面图片上传
  - [x] 头像图片上传
  - [ ] 视频支持（待实现）
  - [ ] 音频支持（待实现）
- [x] **评论区界面** - UI 组件已完成
- [x] **互动数据**
  - [x] 点赞功能
  - [x] 星级评分（前端组件）
  - [ ] 转发功能（待实现）

### 🌟 界面与体验

- [x] **深色模式** - 完整的明暗主题切换
- [x] **国际化** - 中英文双语支持
- [x] **响应式设计** - 移动端适配
- [x] **导航系统** - 侧边栏导航
- [x] **时间显示** - 智能问候语
- [x] **分页功能** - 推文列表分页
- [x] **消息提示** - 操作反馈
- [x] **错误处理** - 404页面等

## 🚦 快速开始

### 环境要求

- Node.js 22 +
- npm

### 安装依赖

```bash
npm install
```

### 环境配置

创建 `.env` 文件：

```env
# JWT密钥
JWT_SECRET=your-super-secret-jwt-key

# Oracle数据库连接（生产环境）
ORACLE_HOST=localhost
ORACLE_PORT=1521
ORACLE_SID=ORCL
ORACLE_USERNAME=twitter_app
ORACLE_PASSWORD=TwitterApp2025#

# SQLite数据库（开发环境）
DATABASE_URL=file:./data/db.sqlite3
```

### 运行开发服务器

```bash
npm run dev
```

### 构建生产版本

```bash
npm run build
npm run start
```

### 数据库初始化

#### SQLite 数据库（开发环境）

```bash
# 数据库文件会自动创建在 .data/ 目录下
npm run dev
```

## 🎯 API 接口文档

本项目提供完整的RESTful API接口，支持用户管理、推文操作、社交功能等。

[![Apifox](https://img.shields.io/badge/Apifox-Neko%20Tribe-brightblue.svg)](https://3kjlg46jpj.apifox.cn)

## 👨‍💻 开发团队

**社交媒体** 🥵🥵🥵  
**作者：Cthaat**

### 🛠️ 技术亮点

- **企业级数据库设计** - 完整的Oracle数据库架构，支持大规模用户和高并发
- **现代化前端技术栈** - Vue3 + Nuxt3 + Vuetify3 + TypeScript
- **RESTful API设计** - 标准化的API接口，支持前后端分离
- **响应式设计** - 完美适配桌面端和移动端
- **国际化支持** - 中英文双语界面
- **深色模式** - 完整的主题切换系统

### 📈 项目数据

- **代码行数**：10,000+ 行
- **数据库表**：9个核心表 + 6个视图 + 2个物化视图
- **API接口**：20+ 个RESTful接口
- **前端组件**：15+ 个可复用组件
- **功能模块**：用户管理、推文发布、社交互动、媒体上传等

### 🏆 设计理念

- **用户体验至上** - 简洁直观的界面设计
- **性能优先** - 数据库优化和前端性能调优
- **安全可靠** - 完善的权限控制和数据安全
- **可扩展性** - 模块化设计，易于功能扩展
- **代码质量** - 规范的代码风格和注释文档

---

_最后更新：2025年6月25日_  
_项目版本：v2.0.0-oracle_
