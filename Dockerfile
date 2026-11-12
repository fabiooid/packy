FROM node:26-slim
WORKDIR /app
COPY data ./data
COPY spec ./spec
COPY server/package.json server/package-lock.json ./server/
RUN cd server && npm ci --omit=dev
COPY server/src ./server/src
COPY server/scripts ./server/scripts
WORKDIR /app/server
ENV NODE_ENV=production PACKY_DB=/data/packy.db
CMD ["node", "src/index.ts"]
