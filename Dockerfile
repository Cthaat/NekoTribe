FROM node:22-alpine AS deps

WORKDIR /app

RUN apk add --no-cache libc6-compat python3 make g++ \
  && corepack enable

COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

FROM node:22-alpine AS build

WORKDIR /app

ARG NODE_MAX_OLD_SPACE_SIZE=6144
ENV NUXT_DISABLE_SOURCEMAP=1

RUN corepack enable

COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN node --max-old-space-size="$NODE_MAX_OLD_SPACE_SIZE" node_modules/nuxt/bin/nuxt.mjs build
RUN node scripts/build-ai-public-terms.mjs

FROM node:22-alpine AS runtime

WORKDIR /app

ENV NODE_ENV=production
ENV HOST=0.0.0.0
ENV PORT=3000
ENV STORAGE_PATH=/app/storage
ENV NEKO_TERMS_PACKAGED=1
ENV FFPROBE_PATH=/usr/bin/ffprobe

RUN apk add --no-cache ffmpeg libc6-compat \
  && mkdir -p /app/storage/temp \
  && chown -R node:node /app/storage

COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

COPY --from=build /app/.output ./.output
COPY scripts/run-nuxt.mjs scripts/runtime-env.mjs ./scripts/
COPY scripts/migrate-db.mjs ./scripts/
COPY scripts/init-db.mjs scripts/check-deployment-endpoints.mjs ./scripts/
COPY data/nekotribe-schema-only.sql ./data/
COPY scripts/ai-public-terms-maintenance.mjs ./scripts/
COPY scripts/ai-skill-config-maintenance.mjs ./scripts/
COPY specifications/requirements/ai-public-terms-catalog.json ./specifications/requirements/
COPY server/database/schema.mjs server/database/schema-definition.mjs ./server/database/

EXPOSE 3000

USER node
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
  CMD node -e "fetch('http://127.0.0.1:' + (process.env.NITRO_PORT || process.env.PORT) + '/api/health').then(async r => process.exit(r.ok && (await r.json()).status === 'ok' ? 0 : 1)).catch(() => process.exit(1))"

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "scripts/run-nuxt.mjs", "start"]
