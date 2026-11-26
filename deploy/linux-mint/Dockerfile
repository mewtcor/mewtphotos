FROM node:24-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json vite.config.ts ./
COPY shared ./shared
COPY server ./server
COPY web ./web
COPY scripts/migrate-db-paths.ts ./scripts/migrate-db-paths.ts

RUN npm run build

CMD ["node", "--disable-warning=ExperimentalWarning", "server/main.ts", "--daemon"]
