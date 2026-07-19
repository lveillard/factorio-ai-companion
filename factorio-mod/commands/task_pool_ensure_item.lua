-- AI Companion -- task pool ensure_item procurement engine (2026-07-19 size-refactor
-- split out of task_pool.lua). This is the fully self-contained piece of that file:
-- recipe resolution, nearby-container extraction, and the recursive gather/craft/chop
-- resolution loop for a single "ensure_item" step's ctx.ensure_stack. Zero calls to/from
-- the step-handler cluster or the scheduler tick, which both stay in task_pool.lua,
-- which requires this module and calls into it for start_ensure_item_action below.

local u = require("commands.init")
local queues = require("commands.queues")

local M = {}

-- ensure_item (2026-07-17, Zdendys's own architecture correction: procurement was
-- kept OUT of this module by the ORIGINAL v1 task-pool design, back when neither
-- recipe resolution nor a hand-craftable check existed anywhere in this repo --
-- both now do (resolve_recipe/HAND_CRAFTABLE_CATEGORIES below, mirroring
-- companion.py's get_recipe_ingredients; queues.start_gather/start_craft), so
-- there is no longer a reason to keep this Python's job). Recursively resolves
-- missing INGREDIENTS first (bottom-up, exactly like ColdStartOpening.ensure_item,
-- spatial_demo.py) via an explicit stack in ctx.ensure_stack, bounded to depth
-- ENSURE_ITEM_MAX_DEPTH -- a raw/minable resource (no recipe) is gathered via the
-- existing gather_queues machinery, a non-hand-craftable recipe (smelting) fails
-- fast instead of wasting a doomed start_craft attempt, and wood (no
-- gather()-compatible resource-tile path -- trees are type="tree", not
-- type="resource") is chopped via its own small bounded walk+mine sub-state.
-- Should normally be the FIRST step of a task whose later place/fuel steps
-- consume the same item, so the whole task is self-sufficient once submitted.
local HAND_CRAFTABLE_CATEGORIES = {["crafting"] = true, ["hand-crafting"] = true}
local ENSURE_ITEM_MAX_DEPTH = 4     -- mirrors ColdStartOpening.ensure_item's own _depth cap (spatial_demo.py)
local WOOD_CHOP_MAX_TREES = 10      -- mirrors _chop_wood's own max_trees bound (spatial_demo.py)
-- ENSURE_ITEM_GATHER_MAX_ATTEMPTS (2026-07-17, independent-review-caught HIGH-
-- severity gap before this feature ever shipped): the raw-resource gather path
-- had NO bound at all -- a genuinely scarce/partially-unreachable patch (a real,
-- previously-observed scenario for coal specifically, see this project's own
-- memory) would re-issue start_gather forever with no failure signal, stranding
-- the task indefinitely. Mirrors WOOD_CHOP_MAX_TREES's own bounded-attempts
-- shape, applied to the gather path too instead of leaving it as the one
-- ensure_item sub-path with no give-up condition.
local ENSURE_ITEM_GATHER_MAX_ATTEMPTS = 5
-- ENSURE_ITEM_CONTAINER_SEARCH_RADIUS (2026-07-18, Zdendys live-caught:
-- ensure_item_bypasses_nearby_chest bug -- watched the companion hand-mine
-- stone right next to a FULL 800-stone chest): mirrors fac_building_empty's
-- own radius=5 chest-extraction convention (building.lua) -- a proven,
-- already-tuned distance for "container sitting right next to whatever the
-- companion is currently doing", not a new guess.
local ENSURE_ITEM_CONTAINER_SEARCH_RADIUS = 5

-- Real Factorio recipe data for `item`, or nil if `item` has no recipe at all
-- (every raw/minable resource -- ore, coal, stone, wood -- has zero recipe
-- ingredients; nil means "raw resource, gather it, don't craft it"). Mirrors
-- companion.py's get_recipe_ingredients EXACTLY -- same prototypes.recipe[item]
-- access path (NOT game.recipe_prototypes, confirmed via that method's own
-- docstring/ground-truth citation not to exist in Factorio 2.0) -- just native
-- Lua instead of a JSON round-trip over RCON, since this now runs INSIDE the mod.
local function resolve_recipe(item)
  local r = prototypes.recipe[item]
  if not r then return nil end
  local ingredients = {}
  for _, x in ipairs(r.ingredients) do
    ingredients[#ingredients + 1] = {name = x.name, amount = x.amount}
  end
  local yield = 1
  for _, p in ipairs(r.products) do
    if p.name == item then yield = p.amount; break end
  end
  local hand_craftable = false
  for _, cat in ipairs(r.categories or {"crafting"}) do
    if HAND_CRAFTABLE_CATEGORIES[cat] then hand_craftable = true; break end
  end
  return {ingredients = ingredients, yield = yield, hand_craftable = hand_craftable}
end

-- Extracts up to `deficit` of `item` from the NEAREST container (chest) within
-- ENSURE_ITEM_CONTAINER_SEARCH_RADIUS, inserting straight into the companion's
-- own inventory. Returns the amount actually pulled (0 if nothing nearby has
-- any). Mirrors fac_building_empty's own chest-extraction idiom exactly
-- (building.lua's defines.inventory.chest lookup + nearest-not-first tie-
-- break -- a resource tile can sit exactly as close as a real container in a
-- tight layout, same class of bug that fix already closed once elsewhere).
--
-- Fix for ensure_item_bypasses_nearby_chest_2026_07_18 (Zdendys live-caught:
-- watched the companion hand-mine stone right next to a FULL 800-stone
-- chest) -- called from start_ensure_item_action's raw-resource branch below,
-- BEFORE falling back to queues.start_gather's hand-mining path.
local function pull_from_nearby_container(c, item, deficit)
  if deficit <= 0 then return 0 end
  local candidates = c.entity.surface.find_entities_filtered{
    position = c.entity.position, radius = ENSURE_ITEM_CONTAINER_SEARCH_RADIUS,
    type = {"container", "logistic-container"}}
  local target, bd = nil, math.huge
  for _, e in ipairs(candidates) do
    if e.valid then
      local dx, dy = e.position.x - c.entity.position.x, e.position.y - c.entity.position.y
      local d = dx * dx + dy * dy
      if d < bd then bd, target = d, e end
    end
  end
  if not target then return 0 end
  local inv = target.get_inventory(defines.inventory.chest)
  if not inv then return 0 end
  local av = inv.get_item_count(item)
  if av <= 0 then return 0 end
  local rm = inv.remove{name = item, count = math.min(deficit, av)}
  if rm <= 0 then return 0 end
  -- insert()'s own return value MUST be used, not assumed to equal `rm`
  -- (independent-review finding, 2026-07-18): if the companion's own
  -- inventory can't hold the full amount (e.g. genuinely full), insert()
  -- silently places less -- returning `rm` unchecked would both lose the
  -- un-placed remainder (already removed from the chest, never actually
  -- held) AND let the caller's deficit arithmetic report "satisfied" when
  -- the companion doesn't actually have enough on hand yet. Put back
  -- whatever didn't fit instead of losing it.
  local ins = c.entity.insert{name = item, count = rm}
  if ins < rm then
    inv.insert{name = item, count = rm - ins}
  end
  return ins
end

-- Starts exactly ONE concrete action toward satisfying the need at the TOP of
-- t.ctx.ensure_stack (item=, count=) for companion c/cid. Returns a `kind`
-- string describing what was started ("gather"|"craft"|"chop"|"push"|"satisfied")
-- plus an error string on genuine failure (kind=nil). "push" means a NEW, deeper
-- need (a short ingredient) was pushed onto the stack -- no queue was started
-- this cycle, the caller should look at the stack again next "acting" pass.
-- "satisfied" means the top-of-stack need is ALREADY met (checked fresh here,
-- not assumed) -- pop it and reassess without starting anything.
function M.start_ensure_item_action(c, cid, t)
  local stack = t.ctx.ensure_stack
  local need = stack[#stack]
  if type(need.item) ~= "string" or type(need.count) ~= "number" then
    -- Input validation (2026-07-17, independent-review-caught LOW finding):
    -- mirrors run_set_position's own explicit guard -- a caller bug omitting
    -- item/count would otherwise crash on the get_item_count() call below,
    -- silently swallowed tick after tick by guard_tick's pcall (this file's own
    -- documented failure mode elsewhere) instead of failing this ONE task
    -- cleanly with a clear diagnostic.
    return nil, "ensure_item: step.item (string) and step.count (number) required"
  end
  local inv = c.entity.get_main_inventory()
  if inv.get_item_count(need.item) >= need.count then
    return "satisfied"
  end
  if #stack > ENSURE_ITEM_MAX_DEPTH then
    return nil, "ensure_item recursion depth exceeded for " .. need.item ..
      " (likely a recipe-chain or naming problem, not a normal case)"
  end
  if need.item == "wood" then
    -- Wood has NO gather()-compatible resource-tile path (trees are type="tree",
    -- not type="resource" -- mirrors _chop_wood's own docstring in spatial_demo.py,
    -- factorio-ai repo, for the full "gather('wood',...) always returns 0" root
    -- cause this mirrors). Tracks its OWN small exclude set (t.ctx.wood_tried) so
    -- a tree that fails to reach isn't picked again -- same "no exclude" bug class
    -- already fixed once for _chop_wood itself (2026-07-17), applied here from the
    -- start rather than needing a second live-caught fix.
    t.ctx.wood_tried = t.ctx.wood_tried or {}
    t.ctx.wood_chop_count = t.ctx.wood_chop_count or 0
    if t.ctx.wood_chop_count >= WOOD_CHOP_MAX_TREES then
      return nil, "could not chop enough wood after " .. WOOD_CHOP_MAX_TREES .. " trees"
    end
    -- Expanding-radius search (2026-07-17, Zdendys's own follow-up after a live
    -- incident: coal_pair_upgrade's stage1 spent ~63,000 ticks chopping just 4
    -- trees -- a single flat radius=200 scan always considers the FULL 200-tile
    -- box, so on a map where the nearest patch of forest happens to sit right at
    -- the edge of that box (coal-rich areas are often tree-sparse), the
    -- "nearest" candidate found can still require a very long walk every single
    -- time this resolves. Trying progressively LARGER radii first -- starting
    -- close to the companion, only widening if genuinely nothing nearby -- means
    -- the common case (a tree within a normal few dozen tiles) resolves via a
    -- cheap, close search instead of always scanning (and potentially picking
    -- a candidate from) the full 200-tile radius. Does not change WHICH tree
    -- gets picked once a given radius has candidates (still nearest-first
    -- within that radius); it only avoids needlessly extending the SEARCH
    -- (and therefore the walk) beyond what the nearby area can already supply.
    local WOOD_SEARCH_RADII = {20, 50, 100, 200}
    local best, best_d = nil, math.huge
    for _, radius in ipairs(WOOD_SEARCH_RADII) do
      local trees = c.entity.surface.find_entities_filtered{
        type = "tree", position = c.entity.position, radius = radius}
      for _, tr in ipairs(trees) do
        local key = math.floor(tr.position.x) .. "," .. math.floor(tr.position.y)
        if tr.valid and not t.ctx.wood_tried[key] then
          local d = u.distance(c.entity.position, tr.position)
          if d < best_d then best, best_d = tr, d end
        end
      end
      if best then break end
    end
    if not best then return nil, "no reachable tree found for wood" end
    t.ctx.wood_target = {x = best.position.x, y = best.position.y}
    return "chop"
  end
  local recipe = resolve_recipe(need.item)
  if not recipe then
    -- Raw/minable resource (ore/coal/stone) -- delegate to the existing gather
    -- queue. from_task_pool=true bypasses start_gather's own active_step busy-
    -- guard (see that function's own docstring, queues.lua): WE are the
    -- active_step holder calling it here, not an external caller trying to
    -- steal the companion mid-task.
    --
    -- Bounded attempts (2026-07-17, independent-review-caught HIGH finding):
    -- a single start_gather call already retries internally within its own
    -- lifetime (tick_gather_queues' own "find" state re-blacklists and retries
    -- nearby patches before reporting "done"), but nothing previously bounded
    -- the OUTER loop of re-issuing a FRESH start_gather call if one full cycle
    -- still left a shortfall -- a genuinely scarce/partially-unreachable patch
    -- (a real, previously-observed scenario for coal specifically) would retry
    -- forever with no failure signal. Counts per-item so a task needing several
    -- DIFFERENT raw resources tracks each independently.
    local deficit = need.count - inv.get_item_count(need.item)
    -- Check a nearby container FIRST (2026-07-18 fix, see pull_from_nearby_
    -- container's own docstring above) -- only fall back to hand-mining for
    -- whatever a chest didn't already cover.
    local pulled = pull_from_nearby_container(c, need.item, deficit)
    if pulled > 0 then
      deficit = deficit - pulled
    end
    if deficit <= 0 then
      return "satisfied"
    end
    t.ctx.gather_attempts = t.ctx.gather_attempts or {}
    t.ctx.gather_attempts[need.item] = (t.ctx.gather_attempts[need.item] or 0) + 1
    if t.ctx.gather_attempts[need.item] > ENSURE_ITEM_GATHER_MAX_ATTEMPTS then
      return nil, "could not gather enough " .. need.item .. " after " ..
        ENSURE_ITEM_GATHER_MAX_ATTEMPTS .. " attempts (likely scarce/unreachable)"
    end
    local r = queues.start_gather(cid, need.item, deficit, nil, true)
    if r.error then return nil, r.error end
    return "gather"
  end
  if not recipe.hand_craftable then
    -- Fail fast, exactly like ensure_item's own Python-side hand-craftable check
    -- (2026-07-16 adversarial-review finding, spatial_demo.py): a smelting recipe
    -- (iron-plate/copper-plate/...) has ingredients but the character can never
    -- craft it directly no matter how many ingredients it holds -- attempting
    -- start_craft would just fail with "Missing ingredients" via
    -- get_craftable_count, a misleadingly generic error for a call that could
    -- NEVER have succeeded.
    return nil, need.item .. " recipe is not hand-craftable (needs a real machine, e.g. smelting)"
  end
  for _, ing in ipairs(recipe.ingredients) do
    local needed_amount = math.ceil(need.count / recipe.yield) * ing.amount
    if inv.get_item_count(ing.name) < needed_amount then
      stack[#stack + 1] = {item = ing.name, count = needed_amount}
      return "push"
    end
  end
  local craft_count = math.ceil(need.count / recipe.yield)
  local r = queues.start_craft(cid, need.item, craft_count)
  if r.error then return nil, r.error end
  return "craft"
end

return M
