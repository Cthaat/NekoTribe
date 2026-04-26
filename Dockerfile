FROM node:22-alpine AS deps

WORKDIR /app

RUN apk add --no-cache libc6-compat python3 make g++ \
  && corepack enable

COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

FROM node:22-alpine AS build

WORKDIR /app

RUN corepack enable

COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN yarn build

FROM node:22-alpine AS runtime

WORKDIR /app

ENV NODE_ENV=production
ENV HOST=0.0.0.0
ENV PORT=3000

RUN apk add --no-cache ffmpeg libc6-compat

COPY --from=build /app/.output ./

EXPOSE 3000

CMD ["node", "./server/index.mjs"]
