# Twitter Clone
![icon](./public/icon.png)<br/>
推特山寨版

一个基于 Nuxt3 + Vuetify 构建的 Twitter 克隆项目，包含完整的用户管理、推文发布、点赞等功能。

## 🚀 部署地址
- 预览地址：[https://twitter-clone-kohl-rho.vercel.app/](https://twitter-clone-kohl-rho.vercel.app/)

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

#### Oracle 数据库（生产环境）
```bash
# 1. 创建Oracle数据库用户和表空间
sqlplus sys/password@localhost:1521/ORCL as sysdba
@oracle_db_setup.sql

# 2. 连接应用用户并创建表结构
sqlplus twitter_app/TwitterApp2025#@localhost:1521/ORCL
@twitter_clone_oracle_db.sql

# 3. 验证数据库安装
sqlplus twitter_app/TwitterApp2025#@localhost:1521/ORCL
SELECT table_name FROM user_tables WHERE table_name LIKE 'T_%';
```

## 📊 数据库架构设计

本项目支持两种数据库部署方案：
- **开发环境**：SQLite3 轻量级数据库
- **生产环境**：Oracle 19c+ 企业级数据库

### 🏗️ Oracle 数据库设计

#### 表空间配置
- **twitter_data** - 用户数据表空间 (500MB, 最大2GB)
- **twitter_index** - 索引表空间 (200MB, 最大1GB)  
- **twitter_temp** - 临时表空间 (100MB, 最大500MB)
- **twitter_undo** - 回滚表空间 (200MB, 最大1GB)

#### 用户权限管理
- **twitter_app** - 应用用户，拥有完整的CRUD权限
- **twitter_admin** - 管理员用户，拥有DBA权限
- **twitter_readonly** - 只读用户，用于报表查询

### 📋 核心数据表结构

#### t_users - 用户基础信息表
```sql
user_id          NUMBER(10)      -- 用户唯一标识符
email            VARCHAR2(100)   -- 邮箱地址（唯一）
username         VARCHAR2(50)    -- 用户名（唯一）
password_hash    VARCHAR2(255)   -- bcrypt加密密码
avatar_url       VARCHAR2(500)   -- 头像URL
display_name     VARCHAR2(100)   -- 显示名称
bio              VARCHAR2(500)   -- 个人简介
location         VARCHAR2(100)   -- 地理位置
website          VARCHAR2(200)   -- 个人网站
birth_date       DATE            -- 出生日期
phone            VARCHAR2(20)    -- 手机号码
is_verified      NUMBER(1)       -- 认证状态 (0-未认证, 1-已认证)
is_active        NUMBER(1)       -- 账户状态 (0-禁用, 1-激活)
followers_count  NUMBER(10)      -- 粉丝数量
following_count  NUMBER(10)      -- 关注数量
tweets_count     NUMBER(10)      -- 推文数量
likes_count      NUMBER(10)      -- 获赞数量
created_at       TIMESTAMP       -- 创建时间
updated_at       TIMESTAMP       -- 更新时间
last_login_at    TIMESTAMP       -- 最后登录时间
```

#### t_tweets - 推文内容表
```sql
tweet_id             NUMBER(15)      -- 推文唯一标识符
author_id            NUMBER(10)      -- 作者ID（外键）
content              CLOB            -- 推文内容
reply_to_tweet_id    NUMBER(15)      -- 回复的推文ID
retweet_of_tweet_id  NUMBER(15)      -- 转发的推文ID
quote_tweet_id       NUMBER(15)      -- 引用推文ID
is_retweet           NUMBER(1)       -- 是否为转发
is_quote_tweet       NUMBER(1)       -- 是否为引用推文
likes_count          NUMBER(10)      -- 点赞数量
retweets_count       NUMBER(10)      -- 转发数量
replies_count        NUMBER(10)      -- 回复数量
views_count          NUMBER(15)      -- 浏览量
is_deleted           NUMBER(1)       -- 软删除标记
visibility           VARCHAR2(20)    -- 可见性设置
language             VARCHAR2(10)    -- 语言标识
created_at           TIMESTAMP       -- 创建时间
updated_at           TIMESTAMP       -- 更新时间
deleted_at           TIMESTAMP       -- 删除时间
```

#### t_follows - 用户关注关系表
```sql
follow_id       NUMBER(15)      -- 关注记录ID
follower_id     NUMBER(10)      -- 关注者ID
following_id    NUMBER(10)      -- 被关注者ID
follow_type     VARCHAR2(20)    -- 关系类型 (follow/block/mute)
is_active       NUMBER(1)       -- 关系状态
created_at      TIMESTAMP       -- 创建时间
updated_at      TIMESTAMP       -- 更新时间
```

#### t_likes - 点赞反应表
```sql
like_id     NUMBER(15)      -- 点赞记录ID
user_id     NUMBER(10)      -- 用户ID
tweet_id    NUMBER(15)      -- 推文ID
like_type   VARCHAR2(20)    -- 反应类型 (like/dislike/love/laugh/angry)
created_at  TIMESTAMP       -- 点赞时间
```

#### t_comments - 评论表
```sql
comment_id          NUMBER(15)      -- 评论ID
tweet_id            NUMBER(15)      -- 推文ID
user_id             NUMBER(10)      -- 评论者ID
parent_comment_id   NUMBER(15)      -- 父评论ID（支持嵌套）
content             CLOB            -- 评论内容
likes_count         NUMBER(10)      -- 评论点赞数
replies_count       NUMBER(10)      -- 评论回复数
is_deleted          NUMBER(1)       -- 软删除标记
created_at          TIMESTAMP       -- 创建时间
updated_at          TIMESTAMP       -- 更新时间
deleted_at          TIMESTAMP       -- 删除时间
```

#### t_media - 媒体文件表
```sql
media_id        NUMBER(15)      -- 媒体文件ID
tweet_id        NUMBER(15)      -- 关联推文ID
user_id         NUMBER(10)      -- 上传用户ID
media_type      VARCHAR2(20)    -- 媒体类型 (image/video/audio/gif)
file_name       VARCHAR2(255)   -- 文件名
file_path       VARCHAR2(500)   -- 文件路径
file_size       NUMBER(15)      -- 文件大小
mime_type       VARCHAR2(100)   -- MIME类型
width           NUMBER(6)       -- 宽度（图片/视频）
height          NUMBER(6)       -- 高度（图片/视频）
duration        NUMBER(10)      -- 时长（视频/音频）秒
thumbnail_path  VARCHAR2(500)   -- 缩略图路径
alt_text        VARCHAR2(500)   -- 可访问性描述
is_processed    NUMBER(1)       -- 处理状态
created_at      TIMESTAMP       -- 上传时间
```

#### t_hashtags - 话题标签表
```sql
hashtag_id      NUMBER(10)      -- 标签ID
tag_name        VARCHAR2(100)   -- 标签名称
tag_name_lower  VARCHAR2(100)   -- 小写标签名（用于搜索）
usage_count     NUMBER(15)      -- 使用次数
trending_score  NUMBER(10,2)    -- 趋势分数
is_trending     NUMBER(1)       -- 是否为热门话题
created_at      TIMESTAMP       -- 创建时间
updated_at      TIMESTAMP       -- 更新时间
```

#### t_tweet_hashtags - 推文标签关联表
```sql
tweet_id    NUMBER(15)      -- 推文ID
hashtag_id  NUMBER(10)      -- 标签ID
created_at  TIMESTAMP       -- 关联时间
```

#### t_user_sessions - 用户会话管理表
```sql
session_id          VARCHAR2(128)   -- 会话ID
user_id             NUMBER(10)      -- 用户ID
jwt_token           CLOB            -- JWT令牌
device_info         VARCHAR2(500)   -- 设备信息
ip_address          VARCHAR2(45)    -- IP地址
user_agent          CLOB            -- 用户代理
is_active           NUMBER(1)       -- 会话状态
expires_at          TIMESTAMP       -- 过期时间
created_at          TIMESTAMP       -- 创建时间
last_accessed_at    TIMESTAMP       -- 最后访问时间
```

### 🔧 数据库功能特性

#### 序列（Sequences）
- `seq_user_id` - 用户ID序列，起始值1000
- `seq_tweet_id` - 推文ID序列，起始值10000  
- `seq_comment_id` - 评论ID序列，起始值100000
- `seq_media_id` - 媒体文件ID序列，起始值1000000

#### 视图（Views）
- `v_user_profile` - 用户档案视图，包含活跃度状态
- `v_tweet_details` - 推文详情视图，包含作者信息和互动统计
- `v_user_timeline` - 用户时间线视图，展示个人和关注用户推文
- `v_trending_hashtags` - 热门话题视图，显示趋势标签和增长率
- `v_user_engagement_stats` - 用户互动统计视图，分析活跃度和影响力
- `v_tweet_interactions` - 推文互动详情视图，显示点赞、转发、评论详情

#### 存储过程（Stored Procedures）
- `sp_manage_follow` - 管理用户关注关系（关注/取消关注/屏蔽）
- `sp_create_tweet` - 发布推文，支持标签自动解析和关联
- `sp_calculate_trending_hashtags` - 计算和更新热门话题标签

#### 函数（Functions）
- `fn_get_user_relationship` - 计算两个用户间的关系状态
- `fn_calculate_tweet_engagement` - 计算推文热度分数，考虑时间衰减
- `fn_can_view_tweet` - 检查用户是否有权限查看特定推文

#### 触发器（Triggers）
- 自动更新时间戳触发器
- 软删除处理触发器
- 统计数据同步触发器（点赞数、关注数等）
- 会话清理触发器
- 标签使用统计触发器

#### 定时任务（Scheduled Jobs）
- 清理过期用户会话（每小时执行）
- 计算热门话题标签（每2小时执行）
- 更新推文浏览量统计（每日执行）

#### 物化视图（Materialized Views）
- `mv_user_activity_daily` - 用户每日活跃度统计
- `mv_hashtag_trends_hourly` - 话题标签每小时趋势统计

### 🚀 数据库性能优化

#### 索引策略
- **主键索引**：所有表的主键自动创建唯一索引
- **外键索引**：为所有外键字段创建索引，优化关联查询
- **时间线索引**：为时间线查询创建复合索引 `(author_id, created_at DESC, is_deleted)`
- **搜索索引**：为用户名、邮箱、标签名创建索引
- **状态索引**：为软删除、可见性等状态字段创建索引

#### 分区策略（生产环境推荐）
- 推文表按时间分区（按月或季度）
- 点赞表按时间分区
- 会话表按过期时间分区

#### 查询优化
- 使用统计信息优化查询计划
- 定期收集表统计信息
- 通过物化视图预计算复杂聚合数据

### 🔒 数据安全与备份

#### 安全措施
- 密码使用bcrypt加密存储
- JWT令牌安全管理
- 用户权限分层管理
- 审计字段记录数据变更
- 软删除避免数据丢失

#### 备份策略
- 定时数据库备份
- 归档日志备份
- 跨地域灾备

### 📈 数据统计与分析

数据库设计支持丰富的统计分析功能：
- 用户活跃度分析
- 推文传播效果分析  
- 话题趋势分析
- 用户互动行为分析
- 内容质量评估

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