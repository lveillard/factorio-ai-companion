# Factorio AI Companion

A guided second player for Factorio: chat in the game or browser, inspect nearby terrain and machines, and let companions mine, craft and build with carried materials.

Requires **Bun 1.4.2+** and **Factorio 2.0.77+**. The included Codex app-server uses your ChatGPT subscription. Sign in through the dashboard using a browser or device code; Codex handles credential storage and renewal. No API key is required.

## Run locally

```sh
bun install --frozen-lockfile
bun run build
bun run mod:install
bun run start
```

Open **http://127.0.0.1:3210**. Select **Conectar Codex**, finish the login, then **Iniciar compañero**. Send instructions in the browser or with `/fac consigue hierro` and `/fac 1 construye un horno` in Factorio. **Parar todo** interrupts Codex and cancels native companion work. Messages received while paused remain queued; a restart starts paused and does not replay interrupted actions.

Enable RCON in Factorio's `config.ini`, under `[other]`:

```ini
local-rcon-socket=127.0.0.1:34198
local-rcon-password=factorio
```

Restart Factorio and host a multiplayer game. For a headless server, use `--rcon-port 34198 --rcon-password YOUR_PASSWORD`. Copy `.env.example` to `.env` to change the bridge's host, port and matching password. `bun run doctor` locates your game/mod directory and reports configuration without printing secrets.

On a local setup, `bun run game:launch` backs up this config, applies the matching loopback RCON settings and opens Factorio. Close an existing Factorio instance first.

`mod:install` backs up the previous companion mod and mod list under `.local/mod-backups`, then installs a fresh copy. Saves and other mods are preserved. `bun run mod:package` writes the versioned mod ZIP to `dist/`.

## Remote deployment

```sh
# In .env, set COMPANION_ACCESS_TOKEN to a random value of at least 32 characters.
# Set FACTORIO_HOST to the game's hostname/IP, not the container's localhost.
docker compose up --build -d
```

Compose exposes http://localhost:3210 on the host's loopback address. Use **device code login** in Docker: the browser OAuth callback otherwise targets localhost on the server. Credentials, conversation state and rotating logs persist in the `companion-data` volume.

For a game on the Docker host, set `FACTORIO_HOST=host.docker.internal` and make RCON reachable from that container. For cloud hosting, put the dashboard behind HTTPS, set `COMPANION_PUBLIC_URL` to its external origin and route the service through a private network. RCON itself is plaintext; keep it on a trusted network/VPN. The service requires a token when binding outside loopback and checks browser origins.

**MCP:** `/mcp` uses Streamable HTTP with `Authorization: Bearer <COMPANION_ACCESS_TOKEN>`. Locally, an automatically generated token is stored in `.local/server-token`. The web login cookie does not authenticate MCP. The current server implements protocol **2026-07-28** through MCP SDK **2.0.0** and explicitly rejects older protocol handshakes. `bun run mcp` provides the same modern protocol over stdio.

MCP authentication grants access to game tools. The separate Codex/ChatGPT login authorizes the assistant's model usage; neither credential is a replacement for the other.

## Sources of truth

| File | Drives |
| --- | --- |
| `config/commands.json` | Named arguments, bounds, task step schemas, preconditions, MCP/Codex tools, browser forms and generated Lua dispatch contract |
| `config/settings.ts` | Environment defaults, validation and generated `.env.example` |
| `config/gameplay.json` | Queue kinds, observation/retention limits and gameplay tuning |
| `config/mod.json` + `package.json` | Generated mod metadata and the single release version |

Run `bun run generate` after changing configuration. Generated Lua and metadata are checked in so the mod can be packaged independently. Do not edit generated files. Lua handlers own game behavior; the dashboard, Codex host and MCP transport all share one serialized `GameBridge`.

World observations are bounded samples of charted and nearby visible terrain, with machine inventories, research, companion tasks and errors. They are structured telemetry, not a screenshot or a complete simulation of every map chunk. The most recent completed job remains inspectable until replaced/cancelled. Game chat retains a bounded mailbox; the server persists ingested messages and its cursor.

## Development and checks

```sh
bun run dev          # rebuild web/config on edits; restart the HTTP service
bun run check        # TypeScript, generated contract/Lua syntax, RCON/MCP/session tests
bun run test:web     # isolated browser smoke; Chrome on Windows, Chromium elsewhere
bun run codex:smoke  # actual app-server protocol, no model turn or login required
bun run test:game    # disposable headless world, real gameplay assertions
bun run test:docker  # smoke the built image, including volume persistence
```

For browser tests on Linux, install Chromium with `bunx playwright install --with-deps chromium`; `PLAYWRIGHT_CHANNEL` selects another installed browser. Real-game tests require a local Factorio executable (`FACTORIO_BINARY`), use separate config/mods/ports and never load your saves. They intentionally enable Lua fixture commands only inside their disposable world.

The revival incorporates the game engine from [PR #2 by Zdendys79](https://github.com/lveillard/factorio-ai-companion/pull/2), reviewed at `323ce441b078bc0d44d96af81c1b28bec70b2d61`. The old Claude daemons, subprocess skills, positional RCON endpoints, obsolete context commands and automatic publishing hooks have been removed. Historical plans remain available in Git.

Codex integration follows the [official app-server protocol](https://developers.openai.com/codex/app-server/). Dependency upgrades should include the app-server smoke test and the modern MCP client tests.
