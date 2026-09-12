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

Open **http://127.0.0.1:3210**. Open **Settings** to sign in with ChatGPT. **Add companion** creates a character; **Mine**, **Follow me** and **Stop** run directly without model calls. Send a task with **Send & start**, or use `/fac gather iron` and `/fac 1 build a furnace` in Factorio. **Stop all** interrupts Codex and cancels native companion work. Messages received while paused remain queued; a restart starts paused and does not replay interrupted actions.

Close Factorio completely before editing its configuration: a running game can overwrite external changes when saving its settings. Enable RCON in `config.ini`, under `[other]`:

```ini
local-rcon-socket=127.0.0.1:34198
local-rcon-password=factorio
```

Restart Factorio and host a multiplayer game. For a headless server, use `--rcon-port 34198 --rcon-password YOUR_PASSWORD`. Copy `.env.example` to `.env` to change the bridge's host, port and matching password. `bun run doctor` locates your game/mod directory and reports configuration without printing secrets.

On a local setup, `bun run game:launch` backs up this config, applies the matching loopback RCON settings and opens Factorio. It refuses to change the config while Factorio is running. RCON requires hosting multiplayer; you can host a private local game and play alone with companions. The single-player menu mode does not expose this connection.

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

## Use your own harness

For **Claude Code**, keep the HTTP service running with `bun run start`, then run `bun run claude` from another terminal. The launcher loads the local server token (or `COMPANION_ACCESS_TOKEN` from `.env`) and attaches the HTTP MCP server to your existing Claude Code account. It explicitly selects the modern MCP client; the tested Claude Code version is 2.1.270. The panel stays available for world observation and logs. Leave its Codex agent paused while controlling companions from your harness.

For **Codex CLI**, enable the modern protocol in its configuration:

```toml
[features]
mcp_2026_07_28 = true

[mcp_servers.factorio]
url = "http://127.0.0.1:3210/mcp"
bearer_token_env_var = "COMPANION_ACCESS_TOKEN"
```

Set that environment variable to the service token before starting Codex. Codex uses its own ChatGPT login; no dashboard login is needed for this route. `config/harnesses.json` holds the client feature switches, and `codex:smoke` checks the pinned real client against this server without starting model inference. A custom harness can consume the same MCP endpoint and manage its model separately.

## Sources of truth

| File | Drives |
| --- | --- |
| `config/commands.json` | Named arguments, bounds, task step schemas, preconditions, MCP/Codex tools, browser forms and generated Lua dispatch contract |
| `config/settings.ts` | Environment defaults, validation and generated `.env.example` |
| `config/gameplay.json` | Queue kinds, observation/retention limits and gameplay tuning |
| `config/mod.json` + `package.json` | Generated mod metadata and the single release version |
| `config/harnesses.json` | Modern MCP client switches for the Claude launcher and Codex integration check |
| `config/dashboard.json` | Companion defaults, mining choices and job labels; form bounds come from the tool contract |
| `config/agent.json` | Terrain grouping for compact automatic model observations |

Run `bun run generate` after changing configuration. Generated Lua and metadata are checked in so the mod can be packaged independently. Do not edit generated files. Lua handlers own game behavior; the dashboard, Codex host and MCP transport all share one serialized `GameBridge`.

World observations are bounded samples of charted and nearby visible terrain, with machine inventories, research, companion tasks and errors. They are structured telemetry, not a screenshot or a complete simulation of every map chunk. The most recent completed job remains inspectable until replaced/cancelled. Game chat retains a bounded mailbox; the server persists ingested messages and its cursor.

Automatic model context groups ore and trees and counts water tiles. Machines, enemies, inventories and job results retain their detail; `world_observe` provides individual terrain positions on demand. Dashboard map data stays complete within the configured observation bounds.

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

`bun run check` also executes the production Lua modules in Fengari with deterministic engine doubles: crafting completion/cancellation, partial mining results, inventory formats, reservations and belt routes. It never launches Factorio. These regressions complement the real-engine suite; they do not emulate Factorio physics or other installed mods. Agent continuation limits and job review deadlines are defined in `config/settings.ts`. Navigation callbacks, blocked procurement, drill footprints and furnace output also have offline regressions. Rare-symptom save capture is opt-in via `config/gameplay.json`; diagnostic errors are always recorded.

The revival incorporates the game engine from [PR #2 by Zdendys79](https://github.com/lveillard/factorio-ai-companion/pull/2), integrated through `c1871da37e5d4e1f2c70d175b4b3f5bf97fd36c4`. The old Claude daemons, subprocess skills, positional RCON endpoints, obsolete context commands and automatic publishing hooks have been removed. Historical plans remain available in Git.

Codex integration follows the [official app-server protocol](https://developers.openai.com/codex/app-server/). Dependency upgrades should include the app-server smoke test and the modern MCP client tests.

## Publish a release

Change `package.json` and add the matching entry to `factorio-mod/changelog.txt`, then run `bun run generate`, `bun run check`, `bun run codex:smoke` and the relevant integration checks. `bun run mod:package` creates the uploadable ZIP with its generated metadata.

Upload it from the existing mod's [downloads page](https://mods.factorio.com/mod/ai-companion/downloads), or put a key with **ModPortal: Upload Mods** scope in `.env` as `FACTORIO_MOD_UPLOAD_API_KEY` and run `bun run mod:publish`. This explicit command refuses an existing version and verifies the published file hash. Publish the matching bridge source alongside the mod so users can install the same command contract. The upload key is never required at runtime.
