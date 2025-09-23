# --- 阶段 1: 构建阶段 ---
# 选择一个与您开发环境一致的 Node.js 版本
FROM node:22-alpine AS build

# 在容器内设置工作目录
WORKDIR /app

# 复制 package.json 和 lock 文件 (package-lock.json, pnpm-lock.yaml, etc.)
# 使用通配符 * 可以同时匹配 package.json 和 package-lock.json
COPY package*.json ./

# 安装项目依赖
# 如果您使用 pnpm 或 yarn，请将此命令更改为 'pnpm install' 或 'yarn install'
RUN yarn install

# 复制项目中的所有文件到工作目录
# .dockerignore 文件中指定的项将被忽略
COPY . .

# 执行Nuxt的构建命令
# 这会创建包含优化后前后端代码的 .output 目录
RUN yarn run build

# --- 阶段 2: 生产阶段 ---
# 使用一个轻量级的 Node.js 镜像作为最终的运行环境
FROM node:22-alpine

# 设置工作目录
WORKDIR /app

# 从“构建阶段”复制已经构建好的 .output 目录
# 这是运行生产应用所需的唯一目录
COPY --from=build /app/.output .

# 暴露Nuxt应用运行的端口（默认为3000）
# 如果您在 nuxt.config.js 中修改了端口，请在这里也进行相应修改
EXPOSE 3000

# 定义容器启动时执行的命令
# 该命令会启动Nuxt的生产服务器
CMD ["node", "./server/index.mjs"]