-- AI Companion v0.9.0 - Tick-based queue system
--
-- Pure facade (2026-07-19 size-refactor, completed): this file used to hold every
-- queue type's own implementation directly (2249 lines). Each queue type now lives
-- in its own file (queues_<name>.lua), plus shared infrastructure in
-- queues_core.lua (process_queue/valid_companion/tile_key/TICK_INTERVAL/
-- MINE_ADJACENT_RANGE/the respawn-fn registration indirection). This file only
-- requires them and re-exports their public functions under the SAME M.<name> API
-- every external caller (control.lua, commands/building.lua, commands/combat.lua,
-- commands/resource.lua, commands/companion.lua, commands/item.lua, task_pool.lua,
-- task_pool_ensure_item.lua) already used -- zero external caller needed any change
-- across the whole refactor. See ~/.claude/plans/jaunty-wishing-thimble.md for the
-- full batch-by-batch history.
local gather = require("commands.queues_gather")
local build = require("commands.queues_build")
local fuel = require("commands.queues_fuel")
local harvest = require("commands.queues_harvest")
local belt = require("commands.queues_belt")
local craft = require("commands.queues_craft")
local combat = require("commands.queues_combat")

local M = {}

-- GATHER (see queues_gather.lua)
M.start_gather = gather.start_gather
M.tick_gather_queues = gather.tick_gather_queues
M.get_gather_status = gather.get_gather_status
M.debug_respawn_entity = gather.debug_respawn_entity
M.get_mine_diag = gather.get_mine_diag

-- BUILD (see queues_build.lua)
M.start_build = build.start_build
M.tick_build_queues = build.tick_build_queues
M.get_build_status = build.get_build_status
M.stop_build = build.stop_build

-- FUEL GROUP (see queues_fuel.lua)
M.start_fuel_group = fuel.start_fuel_group
M.tick_fuel_queues = fuel.tick_fuel_queues
M.get_fuel_status = fuel.get_fuel_status

-- HARVEST + ORPHANED MINING SAFETY NET (see queues_harvest.lua)
M.start_harvest = harvest.start_harvest
M.start_mining_next = harvest.start_mining_next
M.tick_harvest_queues = harvest.tick_harvest_queues
M.get_harvest_status = harvest.get_harvest_status
M.stop_harvest = harvest.stop_harvest
M.tick_orphan_mining_cleanup = harvest.tick_orphan_mining_cleanup

-- BELT CONNECT (see queues_belt.lua)
M.start_belt_connect = belt.start_belt_connect
M.tick_belt_queues = belt.tick_belt_queues
M.get_belt_connect_status = belt.get_belt_connect_status
M.stop_belt_connect = belt.stop_belt_connect

-- CRAFT (see queues_craft.lua)
M.start_craft = craft.start_craft
M.tick_craft_queues = craft.tick_craft_queues
M.get_craft_status = craft.get_craft_status
M.stop_craft = craft.stop_craft

-- COMBAT (see queues_combat.lua)
M.start_combat = combat.start_combat
M.tick_combat_queues = combat.tick_combat_queues
M.get_combat_status = combat.get_combat_status
M.stop_combat = combat.stop_combat

function M.init()
  storage.harvest_queues = storage.harvest_queues or {}
  storage.gather_queues = storage.gather_queues or {}
  storage.fuel_queues = storage.fuel_queues or {}
  storage.craft_queues = storage.craft_queues or {}
  storage.build_queues = storage.build_queues or {}
  storage.combat_queues = storage.combat_queues or {}
  storage.belt_queues = storage.belt_queues or {}
  storage.mine_diag = storage.mine_diag or {}   -- diagnostic, see queues_gather.lua's own MINE_DIAG_CAP comment
end

return M
