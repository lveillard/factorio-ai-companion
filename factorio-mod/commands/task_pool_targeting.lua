-- AI Companion -- task pool step targeting + readiness (2026-07-19 size-refactor
-- split out of task_pool.lua). Verbatim move -- see task_pool.lua's own header
-- comment block for the full step-vocabulary background these two functions
-- serve (distance-priority scheduling in M.tick/pick_next, which stay in
-- task_pool.lua).

local ledger = require("commands.task_pool_ledger")

local M = {}

M.WALK_REACH = 2      -- mirrors MINE_ADJACENT_RANGE-class "close enough" used elsewhere

-- ---- step readiness + target position (for distance-priority scheduling) ----

-- Returns the world position a given step will act at (nil if the step doesn't
-- need a specific position -- e.g. find_patch/verify_tile/pick_orientation run
-- instantly wherever the companion currently stands).
--
-- Absolute x/y (2026-07-07, coal_pair upgrade task): a step MAY specify its own
-- explicit {x=, y=} instead of relying on ctx.px/py or ctx.sx/sy -- lets the
-- PYTHON side precompute a whole multi-entity layout itself (e.g. a drill's
-- known drop_position, queried once and reused for several later steps) rather
-- than needing pick_orientation's primary/secondary/offset model extended to
-- cover more than 2 positions. Checked FIRST so it overrides which= when both
-- are present (they never should be, but explicit coordinates are the more
-- specific/intentional choice if a step somehow carries both).
function M.step_target_pos(t, step)
  if step.x and step.y then return {x = step.x, y = step.y} end
  -- candidates (2026-07-07): use the FIRST candidate as the nominal walking/
  -- scheduling target -- they cluster close together (fallback alternatives
  -- for the SAME intended spot), so any one of them is a fine approximation
  -- for "is the companion roughly there yet" even though run_pick_orientation-
  -- style candidate resolution (which one actually gets placed) only happens
  -- once the "acting" state is reached.
  if step.candidates and step.candidates[1] then
    return {x = step.candidates[1].x, y = step.candidates[1].y}
  end
  -- ref (2026-07-07, coal_pair upgrade task): a step MAY target a position saved
  -- earlier in ctx.saved by a "read_drop_position" step (e.g. a drill's engine-
  -- computed, already-rotated drop_position -- see that step's own comment for
  -- why this is queried live instead of reimplementing vector_to_place_result
  -- rotation math on the Python side).
  if step.ref and t.ctx.saved and t.ctx.saved[step.ref] then return t.ctx.saved[step.ref] end
  -- 2026-07-07, live-caught: "read_drop_position" was missing from this type
  -- list, so its which="primary"/"secondary" never resolved (fell straight
  -- through to `return nil`) -- failed with "no source position resolved" on
  -- its very first live run despite drills placing correctly just before it.
  if step.type == "place" or step.type == "fuel" or step.type == "remove"
     or step.type == "read_drop_position" then
    if step.which == "primary" and t.ctx.px then return {x = t.ctx.px, y = t.ctx.py} end
    if step.which == "secondary" and t.ctx.sx then return {x = t.ctx.sx, y = t.ctx.sy} end
  end
  return nil
end

-- A task's CURRENT step is ready to run if every item consumed by steps UP TO AND
-- INCLUDING the current cursor is already reserved for THIS task (2026-07-10,
-- root-caused via live reproduction: get_diag()/task_status() polling of a
-- deliberately-starved, UNCONTESTED single submission -- scripts/
-- repro_starved_upgrade.py-class test -- showed a task sit at cursor=1
-- ('find_existing', which consumes nothing at all) for 60+ real seconds with
-- active_step=nil and every busy_* flag False: genuinely idle, not blocked by
-- ANY other queue or task -- while t.needs showed {coal=10}, a requirement that
-- belongs ONLY to the task's LAST step, 'fuel'). The PREVIOUS version of this
-- function gated readiness on `next(t.needs) == nil` -- t.needs is the WHOLE
-- TASK's aggregate deficit across EVERY step, so a task whose LAST step needs a
-- still-scarce item could never even attempt its FIRST step, no matter how
-- unrelated that first step's own requirements are. Recomputing the deficit for
-- only steps[1..cursor] and comparing against t.reserved (this task's own
-- cumulative claim, monotonically non-decreasing until release_reservations() at
-- completion/failure -- unaffected by this change) lets a task make every bit of
-- progress it genuinely can right now, and block ONLY once it reaches the
-- specific step that needs the still-missing item -- exactly how a real
-- single-threaded worker would behave. This is a DIFFERENT bug from the
-- concurrent-submission race fixed earlier the same day (spatial_bc.py's
-- task_pool_busy / reactive_expert.py's is_task_pool guard, which stops a SECOND
-- task from being submitted while another is active) -- this one reproduces with
-- exactly ONE task submitted, no competing submission at all.
function M.task_ready(t)
  local needed_so_far = ledger.derive_needs(t.steps, t.cursor)
  for item, count in pairs(needed_so_far) do
    if (t.reserved[item] or 0) < count then
      return false
    end
  end
  return true
end

return M
