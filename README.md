# NekoTribe

![icon](./public/icon.png)<br/>

### 🏷️ 版本信息
![版本](https://img.shields.io/badge/版本-v1.0.5-blue.svg)
![数据库](https://img.shields.io/badge/数据库-base-green.svg)
![开发状态](https://img.shields.io/badge/%E5%BC%80%E5%8F%91%E7%8A%B6%E6%80%81-%E6%AD%A3%E5%9C%A8%E5%BC%80%E5%8F%91-yellow.svg)

### 🛠️ 技术栈
![Nuxt](https://img.shields.io/badge/Nuxt-3.12.3-00C58E.svg?logo=nuxt.js&logoColor=white)
![Vue.js](https://img.shields.io/badge/Vue.js-3.4.0-4FC08D.svg?logo=vue.js&logoColor=white)
![TypeScript](https://img.shields.io/badge/TypeScript-5.0-3178C6.svg?logo=typescript&logoColor=white)
![Vuetify](https://img.shields.io/badge/Vuetify-3.6.13-1867C0.svg?logo=vuetify&logoColor=white)
![Node.js](https://img.shields.io/badge/Node.js-22.0-339933.svg?logo=node.js&logoColor=white)

### 🗄️ 数据库
![Oracle](https://img.shields.io/badge/Oracle-19c+-F80000.svg?logo=oracle&logoColor=white)
![SQLite](https://img.shields.io/badge/SQLite-3.46-003B57.svg?logo=sqlite&logoColor=white)

一个基于 Nuxt3 + Vuetify 构建的 Twitter 克隆项目，包含完整的用户管理、推文发布、点赞等功能。

## 🚀 部署地址
- [预览地址](https://neko-tribe.vercel.app)

## 🛠️ 技术栈

### 前端框架
- [**Nuxt 3**](https://nuxt.com/) - Vue.js 全栈框架
- [**Vue 3**](https://vuejs.org/) - 渐进式前端框架
- [**Vuetify 3**](https://vuetifyjs.com/zh-Hans/) - Material Design 组件库
- [**TypeScript**](https://www.typescriptlang.org/) - 类型安全的 JavaScript

### 状态管理
- [**Pinia**](https://pinia.vuejs.org/) - Vue 状态管理
- [**@pinia-plugin-persistedstate**](https://github.com/prazdevs/pinia-plugin-persistedstate) - 状态持久化

### 后端 & 数据库
- [**Nitro**](https://nitro.unjs.io/) - 全栈服务器引擎
- [**Oracle 19c+**](https://www.oracle.com/database/) - 企业级关系型数据库
- [**Better SQLite3**](https://github.com/WiseLibs/better-sqlite3) - 轻量级数据库（开发环境）
- [**JWT**](https://jwt.io/) - 身份验证
- [**bcrypt**](https://github.com/kelektiv/node.bcrypt.js) - 密码加密

### UI & 样式
- [**Vuetify Nuxt Module**](https://vuetify-nuxt-module.netlify.app/) - Vuetify 集成
- [**@nuxtjs/color-mode**](https://color-mode.nuxtjs.org/) - 深色模式支持
- [**Material Design Icons**](https://pictogrammers.com/library/mdi/) - 图标库
- [**Element Plus**](https://element-plus.org/) - 消息提示组件

### 国际化 & 工具
- [**@nuxtjs/i18n**](https://i18n.nuxtjs.org/) - 国际化支持
- [**Day.js**](https://day.js.org/) - 日期处理
- [**Formidable**](https://github.com/node-formidable/formidable) - 文件上传
- [**ESLint + Prettier**](https://eslint.org/) - 代码规范

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

## 📁 项目结构

```
twitter-clone/
├── components/           # Vue 组件
│   ├── NavBar.vue       # 导航栏
│   ├── TweetCard.vue    # 推文卡片
│   ├── AvatarPage.vue   # 头像上传
│   ├── ImgCard.vue      # 图片上传
│   └── ...
├── pages/               # 页面路由
│   ├── index.vue        # 主布局
│   ├── login.vue        # 登录页
│   ├── register.vue     # 注册页
│   ├── detail/[id].vue  # 推文详情
│   └── index/           # 子页面
│       ├── main.vue     # 首页
│       ├── myaccount.vue # 个人设置
│       ├── myarticle.vue # 我的文章
│       └── mylike.vue   # 我的点赞
├── server/api/          # API 接口
│   ├── user/            # 用户相关API
│   │   ├── login.post.ts
│   │   ├── register.post.ts
│   │   ├── update.put.ts
│   │   └── ...
│   └── article/         # 文章相关API
│       ├── addArticle.post.ts
│       ├── getList.post.ts
│       ├── likeArticle.post.ts
│       └── ...
├── stores/              # 状态管理
│   └── user.ts          # 用户状态
├── public/              # 静态资源
│   ├── avatars/         # 用户头像
│   └── cover/           # 推文封面
└── .data/               # 数据库文件
    └── db.sqlite3       # SQLite 数据库
```

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

### 🔐 用户管理API
- `POST /api/user/register` - 用户注册
  ```json
  {
    "email": "user@example.com",
    "password": "password123"
  }
  ```

- `POST /api/user/login` - 用户登录
  ```json
  {
    "email": "user@example.com", 
    "password": "password123"
  }
  ```

- `GET /api/user/logout` - 用户登出
- `GET /api/user/getUserInfo` - 获取当前用户信息
- `PUT /api/user/update` - 更新用户资料（支持头像上传）
- `DELETE /api/user/delete` - 删除用户账户

### 📝 推文管理API
- `POST /api/article/addArticle` - 发布推文
  ```json
  {
    "title": "推文标题",
    "content": "推文内容", 
    "cover": "封面图片文件",
    "hashtags": "标签1,标签2,标签3"
  }
  ```

- `POST /api/article/getList` - 获取推文列表（分页）
  ```json
  {
    "page": 1,
    "pageSize": 15
  }
  ```

- `GET /api/article/getMyArticleList` - 获取我的推文列表
- `GET /api/article/[id]` - 获取推文详情
- `DELETE /api/article/[id]` - 删除推文
- `POST /api/article/likeArticle` - 点赞/取消点赞
  ```json
  {
    "articleId": 12345
  }
  ```

### 👥 社交功能API（数据库已支持，待前端实现）
- `POST /api/follow/manage` - 管理关注关系
- `GET /api/follow/followers/[userId]` - 获取粉丝列表
- `GET /api/follow/following/[userId]` - 获取关注列表
- `POST /api/comment/create` - 发表评论
- `GET /api/comment/list/[tweetId]` - 获取评论列表
- `POST /api/hashtag/trending` - 获取热门话题
- `GET /api/media/upload` - 媒体文件上传

### 📊 统计分析API（数据库已支持）
- `GET /api/stats/user/[userId]` - 用户统计数据
- `GET /api/stats/tweet/[tweetId]` - 推文统计数据
- `GET /api/stats/trending` - 趋势分析数据

## 🔧 开发计划

### ✅ 已完成功能
- [x] **用户管理系统** - 注册、登录、资料管理
- [x] **推文发布系统** - 文本、图片、标签支持
- [x] **点赞互动系统** - 点赞/取消点赞
- [x] **文件上传系统** - 头像、封面图片
- [x] **响应式界面** - 深色模式、国际化
- [x] **Oracle数据库设计** - 完整的企业级数据库架构

### 🚧 进行中功能
- [ ] **评论系统** - 多层级嵌套评论（数据库已完成，前端开发中）
- [ ] **关注系统** - 用户关注/粉丝功能（数据库已完成）
- [ ] **话题标签** - 热门话题、标签搜索（数据库已完成）

### 📋 待实现功能

#### 核心社交功能
- [ ] **推文转发** - 原创转发、引用转发
- [ ] **@用户提及** - 用户提及和通知
- [ ] **私信系统** - 用户间私密消息
- [ ] **推文编辑** - 已发布推文的编辑功能

#### 媒体功能增强
- [ ] **视频上传** - 视频文件上传和播放
- [ ] **音频支持** - 音频文件和语音消息
- [ ] **GIF动图** - GIF图片支持
- [ ] **媒体处理** - 缩略图生成、格式转换

#### 高级功能
- [ ] **实时通知** - WebSocket实时消息推送
- [ ] **全文搜索** - 基于Elasticsearch的内容搜索
- [ ] **推荐算法** - 智能推文推荐
- [ ] **数据分析** - 用户行为分析面板

#### 系统功能
- [ ] **内容审核** - 自动内容过滤和人工审核
- [ ] **反垃圾** - 垃圾信息检测和防护
- [ ] **API限流** - 接口访问频率限制
- [ ] **缓存系统** - Redis缓存优化

### 🎯 性能优化计划
- [ ] **数据库优化**
  - [ ] 查询性能优化
  - [ ] 索引策略调整
  - [ ] 分区表实施
  - [ ] 读写分离

- [ ] **前端优化**
  - [ ] 代码分割和懒加载
  - [ ] 图片懒加载和压缩
  - [ ] CDN集成
  - [ ] PWA支持

- [ ] **系统架构**
  - [ ] 微服务架构改造
  - [ ] 负载均衡
  - [ ] 容器化部署
  - [ ] 监控和日志系统

### 🧪 测试计划
- [ ] **单元测试** - 核心业务逻辑测试
- [ ] **集成测试** - API接口测试
- [ ] **E2E测试** - 端到端用户流程测试
- [ ] **性能测试** - 负载测试和压力测试
- [ ] **安全测试** - 安全漏洞扫描

## 👨‍💻 开发团队

**Web应用开发大作业** 🥵🥵🥵  
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

*最后更新：2025年6月25日*  
*项目版本：v2.0.0-oracle*