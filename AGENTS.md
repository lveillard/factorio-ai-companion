# Working on this repository

- Use Bun and the checked-in `bun.lock`.
- Add/change tools in `config/commands.json`, then their named-argument Lua handlers. `bun run generate` updates the shared contract. Do not add positional commands or compatibility aliases.
- Environment settings belong in `config/settings.ts`; gameplay tuning belongs in `config/gameplay.json`. Release version comes from `package.json`.
- Keep game actions in Lua, transport serialization in `GameBridge`/RCON, and Codex orchestration in `CompanionSession`. Browser forms and model tools derive from the same schema.
- Run `bun run check` and the relevant integration smoke tests. Game tests must use disposable worlds. Never test against a user's save implicitly.
- Do not commit `.local`, `.env`, credentials, runtime logs, generated bundles or personal `.claude/settings.local.json` changes.
