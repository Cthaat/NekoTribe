FROM node:22-alpine AS deps

WORKDIR /app

RUN apk add --no-cache libc6-compat python3 make g++ \
  && corepack enable

COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

FROM node:22-alpine AS build

WORKDIR /app

ENV NODE_OPTIONS=--max-old-space-size=4096

RUN corepack enable

COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN yarn build
RUN node scripts/build-ai-public-terms.mjs

FROM node:22-alpine AS runtime

WORKDIR /app

ENV NODE_ENV=production
ENV HOST=0.0.0.0
ENV PORT=3000
ENV STORAGE_PATH=/app/storage
ENV NEKO_TERMS_PACKAGED=1

RUN apk add --no-cache ffmpeg libc6-compat \
  && mkdir -p /app/storage/temp

COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

COPY --from=build /app/.output ./.output
COPY scripts/run-nuxt.mjs scripts/runtime-env.mjs ./scripts/
COPY scripts/migrate-db.mjs ./scripts/
COPY scripts/ai-public-terms-maintenance.mjs ./scripts/
COPY specifications/requirements/ai-public-terms-catalog.json ./specifications/requirements/
COPY server/database/schema.mjs server/database/schema-definition.mjs ./server/database/

EXPOSE 3000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "scripts/run-nuxt.mjs", "start"]
