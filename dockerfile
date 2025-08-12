# ---------- 构建阶段 ----------
FROM node:22-bookworm-slim AS builder

ENV NUXT_TELEMETRY_DISABLED=1

WORKDIR /app

# 为原生依赖准备构建工具（sharp、better-sqlite3 等）
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential python3 pkg-config git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# 先装依赖，利用缓存
COPY package*.json ./
RUN npm ci

# 拷贝源码并构建
COPY . .
# 注意：如果构建阶段会连接数据库/Redis，请确保其可达，或在代码中通过环境变量跳过构建期连接
RUN npm run build

# ---------- 运行阶段 ----------
FROM node:22-bookworm-slim AS runner

ENV NODE_ENV=production \
    NUXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    NITRO_PORT=3000

WORKDIR /app

# 使用非 root 用户运行
# node 用户在官方镜像中已存在，这里确保目录归属
RUN mkdir -p /app && chown -R node:node /app

# 仅安装生产依赖
COPY --chown=node:node package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

# 仅复制构建产物，减小镜像体积
COPY --from=builder --chown=node:node /app/.output ./.output

EXPOSE 3000

# 健康检查：检查首页是否 200
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

USER node

# 启动 Nitro 服务
CMD ["node", ".output/server/index.mjs"]