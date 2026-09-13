-- AI Companion - Map (re)generation commands.
-- 2026-07-06, Zdendys: "MAPA je stale stejna!!! ... musime zapracovat na zmene mapy!"
-- serve_watch.py (factorio-ai) always replayed the SAME fixed AI-base-clean.zip save --
-- this command lets it give nauvis a genuinely fresh, random layout on every watch
-- session instead, while staying a GUI-client-joinable save (a headless `--create` with
-- a random seed embeds different __level__/control.lua data than a GUI-created save,
-- which a real client refuses to join -- already hit and documented in this project;
-- regenerating the EXISTING surface in place sidesteps that entirely).
--
-- require("crash-site") only works from a proper mod-loading context like this file
-- (confirmed live, 2026-07-06: calling it from an ad-hoc /c RCON command fails --
-- Factorio's console sandbox doesn't expose the same require path a real mod file gets),
-- which is why this needs to be a real command in the mod, not an inline RCON script.
local u = require("commands.init")
local crash_site = require("crash-site")

-- on_chunk_generated tracking (2026-07-08, task #22 6th attempt): every prior attempt
-- relied ENTIRELY on polling is_chunk_generated({chunk_x,chunk_y}) after a single
-- force_generate_chunk_requests() call, which the runtime API docs
-- (doc-html/runtime-api.json, verified directly rather than assumed) confirm is a
-- BLOCKING/synchronous call ("Blocks and generates all chunks that have been requested
-- using all available threads") -- if it's genuinely synchronous, is_chunk_generated
-- should NEVER still read false afterward, let alone "minutes later" as commit 73122bb
-- reported. That symptom is inconsistent with force_generate_chunk_requests() actually
-- running to completion, and delete_chunk's own result was previously discarded inside
-- a bare `pcall` with no logging -- a delete_chunk failure on the spawn-adjacent chunk
-- specifically (e.g. an entity that resists deletion) would have been completely
-- invisible across all 5 prior attempts. Subscribing to the real on_chunk_generated
-- event (not tried before) gives a DEFINITIVE per-chunk completion signal instead of an
-- ambiguous poll, and will show for the first time whether requested chunks ever
-- actually fire this event at all.
local function chunk_key(cx, cy) return cx .. ":" .. cy end

script.on_event(defines.events.on_chunk_generated, function(ev)
  local pending = storage.pending_chunks
  if not pending then return end
  local key = chunk_key(ev.position.x, ev.position.y)
  if pending[key] then
    pending[key] = nil
  end
end)

commands.add_command("fac_regenerate_map", nil, function(cmd)
  u.safe_command(function()
    local surf = game.surfaces[1]
    local mgs = surf.map_gen_settings
    -- Prefer a caller-supplied seed ("seed=12345") over math.random(): Factorio's own
    -- RNG turned out to produce the IDENTICAL value across separate fresh server
    -- restarts (confirmed live, 2026-07-06 -- two independent restarts both produced
    -- seed 1428491079), so it isn't actually varying run-to-run the way a real random
    -- source would. The caller (serve_watch.py) generates a genuinely random seed in
    -- Python instead and passes it explicitly; math.random() stays as a fallback only
    -- for direct/manual invocation.
    local req_seed = cmd.parameter and cmd.parameter:match("seed=(%d+)")
    mgs.seed = req_seed and tonumber(req_seed) or math.random(0, 4000000000)
    surf.map_gen_settings = mgs

    local force = game.forces.player
    local spawn = force.get_spawn_position(surf)
    -- Deleting+re-requesting the spawn chunks in THIS SAME call (right after changing
    -- map_gen_settings.seed above) never completed live no matter the radius or
    -- request granularity (confirmed 2026-07-06: is_chunk_generated at spawn stayed
    -- false for 100+ real seconds) -- yet the IDENTICAL delete+request steps run
    -- STANDALONE against an already-settled surface (i.e. at least one tick after the
    -- seed change) completed instantly every time tested, including the exact spawn
    -- chunk itself. So the delete+request work is deliberately NOT done here -- only
    -- recorded as pending -- and actually performed on fac_regenerate_map_status's
    -- FIRST poll instead, which the caller only calls after at least one RCON
    -- round-trip (>=1 tick) has passed since this command returned.
    storage.pending_crash_site = {surface_index = surf.index, x = spawn.x, y = spawn.y,
                                   requested = false}
    u.json_response({regenerated = true, seed = mgs.seed})
  end)
end)

commands.add_command("fac_regenerate_map_status", nil, function(cmd)
  u.safe_command(function()
    local pending = storage.pending_crash_site
    if not pending then
      u.json_response({done = true, already_done = true})
      return
    end
    local surf = game.surfaces[pending.surface_index]

    if not pending.requested then
      -- FIRST poll after fac_regenerate_map: now do the delete+regenerate-request work
      -- (see the comment in fac_regenerate_map for why it's deferred to here instead of
      -- running immediately after the seed change). R=4 chunks (~128 tiles, 81 chunks
      -- total) -- comfortably covers the opening's IMMEDIATE needs (coal/stone/iron
      -- typically found within 100 tiles); anything beyond this ring keeps using the
      -- OLD seed's terrain, which is fine since decide()'s own resource-search radii
      -- extend further out regardless.
      local ccx, ccy = math.floor(pending.x / 32), math.floor(pending.y / 32)
      local R = 4
      -- 2026-07-08, 6th attempt: delete_chunk's own result was silently discarded by a
      -- bare pcall in every prior attempt -- log any failure instead (u.log_error, same
      -- pattern as queues.lua's gather-queue error path) so a delete failure on the
      -- spawn-adjacent chunk specifically is finally visible rather than indistinguishable
      -- from a clean deletion. Also seed storage.pending_chunks BEFORE requesting, so the
      -- on_chunk_generated handler above can track completion precisely per chunk instead
      -- of relying purely on a single later is_chunk_generated poll.
      -- Each entry stores {cx,cy} (not just `true`) so the completion check below can
      -- retry generation for any SPECIFIC chunk still outstanding, not only the spawn one.
      storage.pending_chunks = {}
      pending.total_chunks = (2 * R + 1) * (2 * R + 1)
      for cx = -R, R do
        for cy = -R, R do
          local ok, err = pcall(function() surf.delete_chunk({ccx + cx, ccy + cy}) end)
          if not ok then
            u.log_error("regenerate_map: delete_chunk(" .. (ccx + cx) .. "," .. (ccy + cy)
              .. ") failed: " .. tostring(err), "regenerate_map")
          end
          storage.pending_chunks[chunk_key(ccx + cx, ccy + cy)] = {cx = ccx + cx, cy = ccy + cy}
        end
      end
      -- Per-chunk requests (radius=0 each), not one bulk request_to_generate_chunks(
      -- pos, R) call -- the bulk form never completed live even standalone, but
      -- individual per-chunk requests did every time tested.
      for cx = -R, R do
        for cy = -R, R do
          surf.request_to_generate_chunks({(ccx + cx) * 32, (ccy + cy) * 32}, 0)
        end
      end
      surf.force_generate_chunk_requests()
      pending.requested = true
      pending.request_tick = game.tick
      u.json_response({done = false, generating = true})
      return
    end

    -- Completion check (2026-07-11: fixed a real bug caught live the same day -- the
    -- previous version only checked the SINGLE spawn chunk was done, then treated the
    -- WHOLE 81-chunk (R=4) request as finished and unconditionally created the crash
    -- site, even though storage.pending_chunks (populated for all 81 chunks above,
    -- cleared per-chunk by the real on_chunk_generated event) could still have OTHER
    -- chunks outstanding. Live-caught: chunk (-2,0) -- inside the R=4 grid, NOT the
    -- spawn chunk -- stayed genuinely ungenerated (is_chunk_generated=false) for
    -- 30000+ ticks after the mod had already declared done=true and spawned the crash
    -- site, and the companion ended up standing exactly there: zero resources of any
    -- kind within 400 tiles, a silent "mine coal: no progress for 12 actions -> abort"
    -- a few actions later with no error anywhere pointing at the real cause. Fix:
    -- require EVERY requested chunk confirmed generated, not just the spawn one.
    --
    -- Keep the original 2026-07-08 spawn-chunk event-vs-poll disagreement check too
    -- (still valuable in isolation: it pinpoints the exact chunk the crash site will
    -- use) alongside the new all-chunks check below.
    local cx, cy = math.floor(pending.x / 32), math.floor(pending.y / 32)
    local spawn_key = chunk_key(cx, cy)
    local event_done = storage.pending_chunks == nil or not storage.pending_chunks[spawn_key]
    local poll_done = surf.is_chunk_generated({cx, cy})
    if event_done ~= poll_done then
      u.log_error(string.format(
        "regenerate_map: is_chunk_generated=%s but on_chunk_generated-tracked done=%s "
        .. "for spawn chunk (%d,%d) at tick %d (requested at tick %d)",
        tostring(poll_done), tostring(event_done), cx, cy, game.tick, pending.request_tick or -1),
        "regenerate_map")
    end

    -- Self-heal against a missed on_chunk_generated event, generalized to EVERY
    -- requested chunk (not just spawn): if the engine already reports a chunk
    -- generated, trust that and clear it rather than retrying it forever.
    local remaining = {}
    for key, chunk in pairs(storage.pending_chunks or {}) do
      if type(chunk) ~= "table" then
        -- Defensive: an older/pre-fix persisted save could still have a bare `true`
        -- here instead of {cx,cy} (this table lives in `storage`, which survives
        -- save/reload). Can't retry a chunk with no known coordinates, so just drop
        -- it rather than crash on chunk.cx below.
        storage.pending_chunks[key] = nil
      elseif surf.is_chunk_generated({chunk.cx, chunk.cy}) then
        storage.pending_chunks[key] = nil
      else
        remaining[#remaining + 1] = chunk
      end
    end

    if #remaining > 0 then
      if pending.request_tick and (game.tick - pending.request_tick) > 600 then
        u.log_error(string.format(
          "regenerate_map: %d/%s chunks still not generated %d ticks after "
          .. "force_generate_chunk_requests() -- that call is documented as blocking, "
          .. "so this stall itself is the anomaly worth investigating next",
          #remaining, tostring(pending.total_chunks), game.tick - pending.request_tick), "regenerate_map")
      end
      -- RETRY (2026-07-08, 6th attempt, root-caused via live isolation testing; now
      -- applied to EVERY chunk still outstanding, not just spawn): confirmed live that
      -- is_chunk_generated() reads TRUE immediately within the SAME command as
      -- force_generate_chunk_requests(), but reverts to FALSE in the very next command
      -- (just 2 ticks later) and stays false even after 2000+ ticks of passive waiting
      -- -- the "generated" signal does not persist on its own. Re-asserting the
      -- request on every poll for every chunk still outstanding, instead of passively
      -- waiting, re-triggers the same transient-success mechanism repeatedly -- if it
      -- eventually sticks, this converges; if it never can stick (a genuine engine
      -- limitation), this at minimum keeps retrying instead of silently doing nothing.
      for _, chunk in ipairs(remaining) do
        surf.request_to_generate_chunks({chunk.cx * 32, chunk.cy * 32}, 0)
      end
      surf.force_generate_chunk_requests()
      -- 2026-07-08 diagnostic (task #22): return the diagnostic fields DIRECTLY in
      -- this response instead of requiring a separate /c query -- discovered live that
      -- raw /c console commands run in a DIFFERENT storage/sandbox than this mod's own
      -- registered commands.add_command handlers (already documented above re:
      -- require("crash-site") failing from /c) -- every earlier /c-based diagnostic
      -- query tonight (pending_chunks count, storage.errors, is_chunk_generated) was
      -- silently reading the WRONG storage table the entire time, making them
      -- worthless for diagnosing this mod's real internal state.
      local errs = storage.errors or {}
      local last_err = #errs > 0 and errs[#errs].error or nil
      u.json_response({done = false, generating = true, pending_chunks = #remaining,
                        total_chunks = pending.total_chunks,
                        event_done = event_done, poll_done = poll_done,
                        ticks_since_request = pending.request_tick and (game.tick - pending.request_tick) or -1,
                        error_count = #errs, last_error = last_err})
      return
    end
    -- Fresh crash site at the (unchanged) spawn point, same function freeplay's own
    -- scenario uses (core/lualib/crash-site.lua) -- not a reimplementation. Minimal
    -- ship_items/part_items (this mod isn't the freeplay scenario, so there's no
    -- storage.crashed_ship_items to reuse) -- the ship's own default wreck loot
    -- (iron-plate etc., scattered by create_crash_site itself) still applies regardless.
    crash_site.create_crash_site(surf, {pending.x, pending.y}, {["firearm-magazine"] = 8},
                                 {}, crash_site.default_ship_parts())
    storage.pending_crash_site = nil
    storage.pending_chunks = nil
    u.json_response({done = true, spawned = true})
  end)
end)
