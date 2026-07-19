-- AI Companion v0.9.0 - Tick-based queue system
local u = require("commands.init")
local core = require("commands.queues_core")
local craft = require("commands.queues_craft")
local combat = require("commands.queues_combat")
local belt = require("commands.queues_belt")
local harvest = require("commands.queues_harvest")
local fuel = require("commands.queues_fuel")
local build = require("commands.queues_build")
local gather = require("commands.queues_gather")

local M = {}

-- GATHER (2026-07-19 size-refactor split -- see queues_gather.lua) -- re-exported so
-- every existing external caller (control.lua, commands/resource.lua,
-- commands/companion.lua, task_pool.lua/task_pool_ensure_item.lua) keeps working
-- unchanged.
M.start_gather = gather.start_gather
M.tick_gather_queues = gather.tick_gather_queues
M.get_gather_status = gather.get_gather_status
M.debug_respawn_entity = gather.debug_respawn_entity
M.get_mine_diag = gather.get_mine_diag

-- BUILD (2026-07-19 size-refactor split -- see queues_build.lua) -- re-exported so
-- every existing external caller (control.lua, commands/building.lua, task_pool.lua)
-- keeps working unchanged.
M.start_build = build.start_build
M.tick_build_queues = build.tick_build_queues
M.get_build_status = build.get_build_status
M.stop_build = build.stop_build

-- FUEL GROUP (2026-07-19 size-refactor split -- see queues_fuel.lua) -- re-exported so
-- every existing external caller (control.lua) keeps working unchanged.
M.start_fuel_group = fuel.start_fuel_group
M.tick_fuel_queues = fuel.tick_fuel_queues
M.get_fuel_status = fuel.get_fuel_status

-- HARVEST + ORPHANED MINING SAFETY NET (2026-07-19 size-refactor split -- see
-- queues_harvest.lua) -- re-exported so every existing external caller
-- (control.lua, commands/resource.lua) keeps working unchanged.
M.start_harvest = harvest.start_harvest
M.start_mining_next = harvest.start_mining_next
M.tick_harvest_queues = harvest.tick_harvest_queues
M.get_harvest_status = harvest.get_harvest_status
M.stop_harvest = harvest.stop_harvest
M.tick_orphan_mining_cleanup = harvest.tick_orphan_mining_cleanup

-- BELT CONNECT (2026-07-19 size-refactor split -- see queues_belt.lua) -- re-exported
-- so every existing external caller (commands/building.lua) keeps working unchanged.
M.start_belt_connect = belt.start_belt_connect
M.tick_belt_queues = belt.tick_belt_queues
M.get_belt_connect_status = belt.get_belt_connect_status
M.stop_belt_connect = belt.stop_belt_connect

-- CRAFT (2026-07-19 size-refactor split -- see queues_craft.lua) -- re-exported so
-- every existing external caller (commands/item.lua) keeps working unchanged.
M.start_craft = craft.start_craft
M.tick_craft_queues = craft.tick_craft_queues
M.get_craft_status = craft.get_craft_status
M.stop_craft = craft.stop_craft

-- COMBAT (2026-07-19 size-refactor split -- see queues_combat.lua) -- re-exported so
-- every existing external caller (commands/combat.lua) keeps working unchanged.
M.start_combat = combat.start_combat
M.tick_combat_queues = combat.tick_combat_queues
M.get_combat_status = combat.get_combat_status
M.stop_combat = combat.stop_combat

-- Constants
-- TICK_INTERVAL/MINE_ADJACENT_RANGE now live in queues_core.lua (2026-07-19 size-refactor
-- split, shared across harvest/gather/combat -- see that file's own comments for the
-- "why" behind each value); aliased here so every existing bare-name call site below
-- (harvest/gather/fuel/craft/build/belt/combat, not yet split into their own files)
-- keeps working completely unchanged.
local TICK_INTERVAL = core.TICK_INTERVAL
local MINE_ADJACENT_RANGE = core.MINE_ADJACENT_RANGE
-- SELECT_FAIL_TICKS/respawn_companion_entity (forward-declare no longer needed)/
-- MINE_DIAG_CAP/_record_mine_diag all moved to queues_gather.lua (2026-07-19
-- size-refactor split) -- see that file's own comment on why the forward-declare
-- trick was dropped.

-- valid_companion/process_queue/UNIVERSAL_STALE_TICKS now live in queues_core.lua
-- (2026-07-19 size-refactor split -- see that file's own copy for the full body/
-- comments, byte-identical). Aliased here so every existing bare-name call site
-- below (harvest/gather/fuel/craft/build/belt/combat, not yet split into their own
-- files) keeps working completely unchanged.
local valid_companion = core.valid_companion
local process_queue = core.process_queue

function M.init()
  storage.harvest_queues = storage.harvest_queues or {}
  storage.gather_queues = storage.gather_queues or {}
  storage.fuel_queues = storage.fuel_queues or {}
  storage.craft_queues = storage.craft_queues or {}
  storage.build_queues = storage.build_queues or {}
  storage.combat_queues = storage.combat_queues or {}
  storage.belt_queues = storage.belt_queues or {}
  storage.mine_diag = storage.mine_diag or {}   -- diagnostic, see MINE_DIAG_CAP comment above
end

-- get_mine_diag moved to queues_gather.lua (2026-07-19 size-refactor split) --
-- see re-export above.

-- HARVEST + ORPHANED MINING SAFETY NET moved to queues_harvest.lua (2026-07-19
-- size-refactor split) -- see re-exports above.

-- GATHER moved to queues_gather.lua (2026-07-19 size-refactor split) -- see
-- re-exports above.

-- FUEL GROUP moved to queues_fuel.lua (2026-07-19 size-refactor split) -- see
-- re-exports above.

-- CRAFT moved to queues_craft.lua (2026-07-19 size-refactor split) -- see
-- M.start_craft/tick_craft_queues/get_craft_status/stop_craft re-exports above.

-- BUILD moved to queues_build.lua (2026-07-19 size-refactor split) -- see
-- re-exports above.

-- BELT CONNECT moved to queues_belt.lua (2026-07-19 size-refactor split) -- see
-- M.start_belt_connect/tick_belt_queues/get_belt_connect_status/stop_belt_connect
-- re-exports above.

-- COMBAT moved to queues_combat.lua (2026-07-19 size-refactor split) -- see
-- M.start_combat/tick_combat_queues/get_combat_status/stop_combat re-exports above.

return M
