-- AI Companion -- task pool needs derivation + reservation ledger (2026-07-12 split
-- out of task_pool.lua, which had grown to 1015 lines). This is the one piece of that
-- file that is genuinely self-contained: computing what a task's steps need, claiming
-- shared inventory stock against those needs, and releasing/finalizing a task once it
-- fails or completes. Everything else (step readiness/target-position, the 9 step
-- executors, the scheduler tick) stays in task_pool.lua, which requires this module
-- and calls into it for the functions below.

local u = require("commands.init")

local M = {}

-- ---- needs derivation + reservation ledger ----

-- "remove" steps (2026-07-07, coal_pair upgrade task) SUPPLY an item the task's
-- OWN later "place" steps then consume (e.g. picking up the 2 existing coal_pair
-- drills before repositioning them) -- netted against place/fuel demand here so
-- a task that fully supplies its own materials doesn't show a needs deficit for
-- items it was never actually short on. Without this, such a task would never
-- become "ready" (task_ready() gates on needs being empty) and its own remove
-- steps -- the very thing that would supply what it "needs" -- could never run:
-- a real catch-22, not just an inefficiency.
--
-- upto (2026-07-10, root-caused via live get_diag()/task_status() polling,
-- "upgrade_iron_furnace task-pool stall" -- NOT the earlier, already-fixed
-- concurrent-submission race): defaults to the WHOLE step list (unchanged caller
-- behavior for submit_task/refresh_needs' own reservation bookkeeping), but
-- task_ready() below passes t.cursor to get only the needs of steps executed SO
-- FAR (1..cursor) -- see that function's own comment for why this distinction is
-- the actual fix.
local function derive_needs(steps, upto)
  local needs = {}
  -- min()'d against #steps (defensive, 2026-07-10): task_ready() passes t.cursor,
  -- which SHOULD never exceed #steps while a task is still "active" (M.tick()
  -- calls complete_task() the moment cursor advances past the last step) -- but
  -- indexing steps[i] out of range would silently return nil and crash the very
  -- next line (s.type) rather than degrade gracefully, so this costs nothing and
  -- removes that risk entirely regardless of whether the invariant ever holds.
  for i = 1, math.min(upto or #steps, #steps) do
    local s = steps[i]
    if s.type == "place" then
      needs[s.entity] = (needs[s.entity] or 0) + 1
    elseif s.type == "fuel" then
      needs[s.item] = (needs[s.item] or 0) + (s.count or 1)
    elseif s.type == "remove" then
      needs[s.entity] = (needs[s.entity] or 0) - 1
    end
  end
  for item, count in pairs(needs) do
    if count <= 0 then needs[item] = nil end
  end
  return needs
end

local function release_reservations(t)
  for item, count in pairs(t.reserved or {}) do
    storage.reserved[item] = math.max(0, (storage.reserved[item] or 0) - count)
  end
  t.reserved = {}
  -- reservation_epoch (2026-07-09, root-caused via careful live log re-analysis, task
  -- pool investigation): refresh_needs() below only re-checks a task's needs when
  -- THAT COMPANION's raw inventory total changes -- it has no way to notice that a
  -- DIFFERENT task's release_reservations() call just freed up stock in the shared
  -- storage.reserved pool. Live-caught: task 1 (coal_pair) held a reservation on
  -- burner-mining-drill while task 2 (iron_drill_upgrade) was submitted concurrently
  -- with an outstanding need for the SAME item; by the time task 1 completed and
  -- released its reservation, the companion's inventory total had ALREADY stopped
  -- changing (a freshly-crafted drill sat idle in inventory, nothing else moved
  -- afterward) -- so refresh_needs() never re-evaluated task 2's needs again, even
  -- though the reservation blocking it had long since cleared, and the task sat
  -- "active" forever with a perfectly available drill sitting unused in inventory
  -- (confirmed live: episode's final inventory dump showed burner-mining-drill=1).
  -- A global epoch counter, bumped on every release, lets refresh_needs() detect
  -- "some reservation freed up, worth re-checking every pending task" independent of
  -- whether inventory itself moved this tick.
  storage.reservation_epoch = (storage.reservation_epoch or 0) + 1
end

local function fail_task(task_id, reason)
  local t = storage.tasks[task_id]
  if not t or t.status ~= "active" then return end
  release_reservations(t)
  t.status = "failed"
  t.error = reason
  u.log_error(string.format("task %d failed: %s", task_id, tostring(reason)), "task_pool")
end

local function complete_task(task_id)
  local t = storage.tasks[task_id]
  if not t or t.status ~= "active" then return end
  release_reservations(t)
  t.status = "done"
end

-- Submit a new task_list under a fresh task_id (2026-07-07 design). `steps` is a
-- plain Lua array (already decoded from the caller's JSON via helpers.json_to_table).
function M.submit_task(cid, steps)
  local c = u.get_companion(cid)
  if not c then return {error = "Invalid companion"} end
  if not steps or #steps == 0 then return {error = "Empty step list"} end

  local needs = derive_needs(steps)
  local inv = c.entity.get_main_inventory()
  local task_reserved = {}
  local remaining_needs = {}
  for item, count in pairs(needs) do
    local have = inv.get_item_count(item)
    local already_reserved = storage.reserved[item] or 0
    -- Only what's genuinely UNCLAIMED by another active task can be reserved here
    -- (Zdendys: "it calculates what it needs... it must not count amounts already
    -- reserved").
    local available = math.max(0, have - already_reserved)
    local take = math.min(available, count)
    if take > 0 then
      storage.reserved[item] = already_reserved + take
      task_reserved[item] = take
    end
    if take < count then
      remaining_needs[item] = count - take
    end
  end

  local task_id = storage.next_task_id
  storage.next_task_id = task_id + 1
  storage.tasks[task_id] = {
    cid = cid,
    steps = steps,
    cursor = 1,
    ctx = {},
    reserved = task_reserved,
    needs = remaining_needs,
    status = "active",
    created_tick = game.tick,
  }
  return {task_id = task_id, needs = remaining_needs}
end

function M.get_task_status(task_id)
  local t = storage.tasks[task_id]
  if not t then return {active = false} end
  return {
    active = t.status == "active",
    status = t.status,
    error = t.error,
    cursor = t.cursor,
    total_steps = #t.steps,
    needs = t.needs,
    ctx = t.ctx,  -- px/py/sx/sy/dir: useful for diagnosing placement failures externally
  }
end

M.derive_needs = derive_needs
M.fail_task = fail_task
M.complete_task = complete_task

return M
