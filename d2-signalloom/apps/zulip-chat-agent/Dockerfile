FROM oven/bun:alpine AS build
WORKDIR /app
COPY package.json bun.lock* tsconfig.json ./
COPY src/ ./src/
RUN bun install --frozen-lockfile 2>/dev/null || bun install

FROM oven/bun:alpine
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./
COPY --from=build /app/src ./src
USER 1000:1000
ENTRYPOINT ["bun", "run", "src/index.ts"]
