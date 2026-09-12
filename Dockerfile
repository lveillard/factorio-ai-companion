FROM oven/bun:1.4.2 AS build
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY config ./config
COPY src ./src
COPY scripts ./scripts
COPY factorio-mod ./factorio-mod
COPY tests ./tests
COPY tsconfig.json ./
RUN bun run generate && bun run check && bun run build

FROM oven/bun:1.4.2
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production
COPY --from=build /app/config ./config
COPY --from=build /app/src ./src
COPY --from=build /app/dist ./dist
COPY --from=build /app/factorio-mod ./factorio-mod
ENV COMPANION_HOST=0.0.0.0 COMPANION_PORT=3210 COMPANION_DATA_DIR=/data
RUN mkdir /data && chown bun:bun /data
USER bun
VOLUME ["/data"]
EXPOSE 3210
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s CMD bun -e "const r=await fetch('http://localhost:3210/healthz');process.exit(r.ok?0:1)"
CMD ["bun", "src/dashboard/main.ts"]
