-- AI Companion -- generic task pool (2026-07-07, Zdendys's redesign)
--
-- Replaces Python-orchestrated monolithic macros (which block on ONE goal's whole
-- step sequence at a time, and restart every step from scratch after any failure)
-- with a mod-side pool: Python submits an ORDERED list of generic atomic STEPS
-- under a task_id. The mod derives item NEEDS from those steps, reserves whatever
-- is already on hand, and works through the remaining steps of ALL currently-
-- submitted tasks together -- each time the companion goes idle, the NEXT step
-- executed is whichever ready task's next step is CLOSEST to the companion right
-- now (task_id order as the tiebreak), not necessarily the same task as last time.
-- This is what lets an unrelated-but-nearby task's step get done WHILE a slow/
-- distant task is still working out its own next move, instead of the whole
-- companion sitting idle-but-blocked on one goal (Zdendys: "coal_pair @259k je
-- naprosto nepredstavitelne pomalu").
--
-- Procurement (mining raw ore, crafting intermediate items) is NOT reimplemented
-- here -- a task with unmet needs just stays blocked until enough of the needed
-- item exists in the main inventory; something ELSE (the existing gather_queues/
-- craft_queues macros, or a future task that supplies coal/plates as a side
-- effect) is expected to top that up. This keeps this first version's scope to
-- the mechanism Zdendys actually described tonight (pool/reservation/priority),
-- not a from-scratch reimplementation of every existing procurement macro.
--
-- Step vocabulary (v1 -- exactly what iron_drill/stone_drill/coal_pair/coal_pair
-- upgrade/furnace-upgrade need, not yet a fully general DSL):
--   {type="find_patch", resource=NAME}                 -> ctx.px, ctx.py
--   {type="find_existing", entity=NAME, radius=N}       -> ctx.px, ctx.py
--   {type="set_position", x=, y=}                       -> ctx.px, ctx.py
--   {type="verify_tile", resource=NAME}                -> aborts task if patch gone
--   {type="pick_orientation", primary=ENTITY, secondary=ENTITY, offsets={{dx,dy},...},
--                             opposite_direction=true|nil, primary_exists=true|nil,
--                             secondary_resource=NAME|nil,
--                             ignore_entities_at={{x=,y=},...}|nil}
--                                                       -> ctx.sx, ctx.sy, ctx.dir, ctx.dir2
--   {type="place", which=/x,y/ref/candidates={{x=,y=,dir=},...}, entity=NAME, dir=N,
--                  mirror=true|nil}                       -> horizontal mirror (live-
--                                                             verified: burner-mining-drill's
--                                                             own drop_position flips side)
--   {type="remove", which=/x,y/ref=, entity=NAME}
--   {type="fuel", which=/x,y/ref=, item=NAME, count=N}
--   {type="read_drop_position", which=/x,y/ref=, entity=NAME, save_as=NAME}
--                                                       -> ctx.saved[save_as]
--   {type="ensure_item", item=NAME, count=N}            -> gathers/crafts NAME
--                                                          up to N in inventory
--                                                          BEFORE the next step
--
-- ensure_item (2026-07-17, Zdendys's own architecture correction: procurement was
-- kept OUT of this module by the ORIGINAL v1 design above, back when neither
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
--
-- find_existing (2026-07-07, furnace-upgrade task): locates an ALREADY-PLACED
-- entity by name nearest the companion's CURRENT position (radius search, no
-- ore/resource patch involved) and sets ctx.px/py to it -- for a task that
-- upgrades something already built (e.g. adding a drill next to a lone
-- bootstrap furnace, Zdendys: "it's the same as building a new pair, but the
-- furnace is already there, just add a drill to it") rather than starting from a raw
-- resource tile like find_patch does.
--
-- pick_orientation's primary_exists (2026-07-07, furnace-upgrade task): when
-- true, the primary (at ctx.px/py, e.g. an EXISTING furnace from find_existing)
-- is NOT can_place_entity-checked or re-placed -- it's already there. Only the
-- secondary's (e.g. a NEW drill's) candidate offset is checked/placed. Pairs
-- with secondary_resource=NAME to ALSO require that offset tile actually have
-- that resource underneath (a drill next to an existing furnace still needs
-- REAL ore there, same as run_verify_tile checks for the primary elsewhere) --
-- without this a candidate could pass can_place_entity yet sit on bare ground.
--
-- pick_orientation's ignore_entities_at (2026-07-07, coal_pair v1->v2 upgrade safety
-- fix): for an UPGRADE task that will "remove" existing entities and rebuild wider at
-- the SAME anchor, checking the wider candidates BEFORE removing anything can suffer
-- FALSE rejections (the still-present old entities' collision boxes can overlap a
-- wider candidate's footprint). Pass the old entities' known {x=,y=} positions here --
-- they get teleported far away, checked, and teleported back, all within this single
-- call (no player-visible flicker, no tick where they're actually gone) -- letting the
-- caller verify a rebuild position is valid BEFORE ever issuing a "remove" step, so a
-- failed pick_orientation never leaves a working setup mid-demolished.
--
-- Every place/fuel/remove/read_drop_position step resolves ITS OWN target
-- position the SAME way (step_target_pos), trying in order: explicit {x=,y=}
-- (caller precomputed it) > candidates[1] (nominal walking target only -- see
-- "place"'s own candidates note for actual placement resolution) > {ref=NAME}
-- (a position an earlier read_drop_position step in THIS task saved under that
-- name) > which="primary"|"secondary" (ctx.px/py or ctx.sx/sy, from find_patch/
-- pick_orientation earlier in this task).
--
-- "place"'s candidates (2026-07-07, live-caught TWICE across separate runs: a
-- single precomputed position -- e.g. an inserter placed exactly 1 tile from a
-- chest's read_drop_position -- can intermittently fail with "Cannot place
-- (collision)" from sub-tile snap variance at that specific spot, even though
-- the SAME code succeeds on a different map). An optional list of {x=,y=,dir=}
-- alternatives lets the caller offer a few nearby fallback spots; the FIRST one
-- that passes can_place_entity at "acting" time is used -- mirrors
-- pick_orientation's own try-candidates-in-order robustness, applied to a
-- single free-standing placement instead of a primary/secondary pair.
--
-- read_drop_position (2026-07-07, coal_pair upgrade task) reads an entity's LIVE
-- LuaEntity.drop_position -- the engine's own already-rotated absolute output
-- position -- rather than reimplementing vector_to_place_result rotation math on
-- the Python side (a real, verified-via-doc field; deliberately not guessed).
-- Lets a task place a chest/container exactly where an EXISTING drill's mined
-- output actually lands, whatever direction that drill happens to face.
--
-- "place" also accepts an explicit simple-0-3 `dir` (bypassing ctx.dir/dir2,
-- which only exist when a pick_orientation step ran earlier in this task) --
-- needed when the caller precomputed the whole layout itself with no
-- pick_orientation step at all.

local u = require("commands.init")
local queues = require("commands.queues")
local ledger = require("commands.task_pool_ledger")

local M = {}

local FUEL_REACH = 3      -- mirrors fac_building_fuel's own radius (building.lua)
local WALK_REACH = 2      -- mirrors MINE_ADJACENT_RANGE-class "close enough" used elsewhere

-- ---- ensure_item step (2026-07-17, Zdendys's own architecture correction after
-- watching a Python-side pre-stock fix land: "I thought the pre-stocking would be
-- part of that task-pool job! Why split the task into sub-steps still in Py, when
-- the mod can handle it fully autonomously?" -- this module's own header docstring originally
-- scoped procurement OUT of the mod deliberately, back when neither recipe
-- resolution nor a hand-craftable check existed anywhere in this repo. Both now
-- exist as real, callable Lua (resolve_recipe below, mirroring companion.py's
-- get_recipe_ingredients; queues.start_gather/start_craft) -- there is no longer
-- a genuine reason to keep this Python's job. {type="ensure_item", item=NAME,
-- count=N} lets a submitted task be fully self-sufficient: the mod gathers/
-- crafts whatever it's short, recursively resolving ingredients bottom-up,
-- BEFORE the task's own later place/fuel steps ever run.
local HAND_CRAFTABLE_CATEGORIES = {["crafting"] = true, ["hand-crafting"] = true}
local ENSURE_ITEM_MAX_DEPTH = 4     -- mirrors ColdStartOpening.ensure_item's own _depth cap (spatial_demo.py)
local WOOD_CHOP_REACH = 3           -- mirrors fac_mine_entity's own distance<=15 check loosely; close enough to swing
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
local function start_ensure_item_action(c, cid, t)
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

function M.init()
  storage.tasks = storage.tasks or {}
  storage.next_task_id = storage.next_task_id or 1
  storage.reserved = storage.reserved or {}
  -- storage.active_step[cid] = {task_id=, state="walking"|"acting"} -- at most ONE step
  -- in flight per companion at a time (single physical entity, can only do one thing).
  storage.active_step = storage.active_step or {}
end

-- ---- needs derivation + reservation ledger ----
-- Moved to task_pool_ledger.lua (2026-07-12 size-refactor split): derive_needs,
-- fail_task, complete_task, M.submit_task, M.get_task_status now live there --
-- see that file for the full historical-rationale comments attached to each.
-- Thin re-exports below so external callers (require("commands.task_pool").
-- submit_task/.get_task_status) keep working unchanged.
M.submit_task = ledger.submit_task
M.get_task_status = ledger.get_task_status

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
local function step_target_pos(t, step)
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
local function task_ready(t)
  local needed_so_far = ledger.derive_needs(t.steps, t.cursor)
  for item, count in pairs(needed_so_far) do
    if (t.reserved[item] or 0) < count then
      return false
    end
  end
  return true
end

-- ---- synchronous (non-walking) step execution ----

-- read_drop_position (2026-07-07, coal_pair upgrade task): reads an entity's
-- LIVE, engine-computed LuaEntity.drop_position (the already-rotated absolute
-- world position where it drops mined/crafted output, per its ACTUAL placed
-- direction) rather than reimplementing the prototype's vector_to_place_result
-- rotation math on the Python side -- avoids a whole class of rotation-sign
-- mistakes for a value the engine already computes authoritatively. Looks for
-- the entity at whatever position step_target_pos resolves for THIS step
-- (which=/x,y/ref, same addressing every other step uses), stores the result
-- in ctx.saved[step.save_as] for a LATER step to target via {ref=save_as}.
local function run_read_drop_position(c, t, step)
  local pos = step_target_pos(t, step)
  if not pos then return false, "read_drop_position: no source position resolved" end
  local es = c.entity.surface.find_entities_filtered{
    name = step.entity, position = pos, radius = 1}
  if #es == 0 then return false, "read_drop_position: no " .. tostring(step.entity) .. " found at source" end
  local dp = es[1].drop_position
  if not dp then return false, "read_drop_position: entity has no drop_position" end
  t.ctx.saved = t.ctx.saved or {}
  t.ctx.saved[step.save_as] = {x = dp.x, y = dp.y}
  return true
end

-- find_existing (2026-07-07, furnace-upgrade task): see step vocabulary note
-- above -- locates an already-placed entity (not a resource patch) nearest the
-- companion, for a task that adds to something already built.
local function run_find_existing(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{
    name = step.entity, position = c.entity.position, radius = step.radius or 400}
  local best, best_d = nil, math.huge
  for _, e in ipairs(es) do
    if e.valid then
      local d = u.distance(e.position, c.entity.position)
      if d < best_d then best, best_d = e, d end
    end
  end
  if not best then return false, "no existing " .. step.entity .. " found" end
  t.ctx.px, t.ctx.py = best.position.x, best.position.y
  return true
end

-- set_position (2026-07-07, coal_pair upgrade variant A -- reusing an EXISTING
-- pair's own drills): sets ctx.px/py directly from caller-supplied coordinates,
-- e.g. a task_id's OWN drill1 position (known from an EARLIER task's completed
-- ctx, read back via fac_task_status) as the anchor for a fresh pick_orientation
-- pass AFTER removing both original drills -- there is nothing left to
-- find_existing on once they're gone, and re-running find_patch could land on
-- a DIFFERENT ore tile than the one this pair was already built on.
local function run_set_position(c, t, step)
  if not (step.x and step.y) then return false, "set_position: x/y required" end
  t.ctx.px, t.ctx.py = step.x, step.y
  return true
end

local function run_find_patch(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{name = step.resource, position = c.entity.position, radius = 400}
  table.sort(es, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)
  for _, e in ipairs(es) do
    if e.valid and (e.amount or 1) > 0
       and surf.find_non_colliding_position("character", e.position, WALK_REACH, 0.5) then
      t.ctx.px, t.ctx.py = e.position.x, e.position.y
      return true
    end
  end
  return false, "no reachable " .. step.resource .. " patch found"
end

local function run_verify_tile(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{name = step.resource, position = {x = t.ctx.px, y = t.ctx.py}, radius = 1}
  if #es == 0 then return false, "patch tile no longer present" end
  return true
end

-- Forward-declared (defined below run_pick_orientation) so both stay `local` --
-- Lua resolves the call inside run_pick_orientation at CALL time, by which point
-- this upvalue has been assigned, same pattern as the rest of this module.
local run_pick_orientation_checks

local function run_pick_orientation(c, t, step)
  local surf = c.entity.surface
  -- ignore_entities_at (2026-07-07, coal_pair v1->v2 upgrade safety fix, Zdendys:
  -- "nejdriv oprav bezpecnost, nez se upgrade zapoji do produkce"): the coal_pair
  -- upgrade's step order is remove-both-old-drills THEN pick_orientation+place-wider.
  -- If pick_orientation found no valid wider spot, the old drills would ALREADY be
  -- gone by the time it fails -- turning a working self-fed pair into a broken one
  -- (live-observed collision-fail rate ~2/5 on this exact geometry, task #35).
  -- Reordering pick_orientation BEFORE remove isn't enough on its own: a wider
  -- candidate's collision box can overlap where the STILL-PRESENT old drill sits
  -- (e.g. gap=2 old secondary at distance 2 overlaps a gap=4 new secondary's
  -- footprint at the boundary), causing a FALSE rejection of a spot that would
  -- actually be fine once the old drill is gone.
  --
  -- Fix: temporarily teleport the named entities at these known positions far away,
  -- run the REAL can_place_entity checks (reusing the engine's own authoritative
  -- collision/tile logic instead of reimplementing it), then teleport them back to
  -- their exact original position -- all within this single synchronous call, so
  -- there is no player-visible flicker and no tick where they're actually gone.
  -- This lets the caller verify a rebuild position BEFORE issuing any "remove" step,
  -- eliminating the regression risk entirely (verify-before-destroy, not just
  -- reordered-but-still-racy).
  local moved = {}
  if step.ignore_entities_at then
    for _, p in ipairs(step.ignore_entities_at) do
      local es = surf.find_entities_filtered{position = {x = p.x, y = p.y}, radius = 0.5}
      for _, e in ipairs(es) do
        if e.valid then
          moved[#moved + 1] = {entity = e, pos = {x = e.position.x, y = e.position.y}}
          e.teleport({x = e.position.x + 10000, y = e.position.y + 10000})
        end
      end
    end
  end
  -- Self-collision fix (2026-07-13, universal own-body-blocks-own-build fix, Zdendys:
  -- "the companion must never block her own construction, whatever the building
  -- is"): every
  -- can_place_entity probe inside run_pick_orientation_checks (both the primary and the
  -- secondary candidate, every offset) sees the companion's OWN character body as an
  -- ordinary collision entity -- if she is currently standing on/near the candidate area
  -- (the common case: she just walked to the patch/anchor before pick_orientation ever
  -- runs), EVERY orientation can spuriously fail with "all sides blocked" even though the
  -- area would genuinely be free the instant she steps aside. Exactly the same class of
  -- false rejection ignore_entities_at/clear_natural_obstacles above already fix for OTHER
  -- entities -- extend the SAME teleport-and-restore technique to her own body: teleport
  -- her far away for the duration of the checks only, then restore her EXACT original
  -- position afterward regardless of outcome (success or failure), so there is no
  -- player-visible flicker and no tick where she is actually gone.
  local self_pos = {x = c.entity.position.x, y = c.entity.position.y}
  c.entity.teleport({x = self_pos.x + 10000, y = self_pos.y + 10000})
  local ok, err = run_pick_orientation_checks(c, t, step, surf)
  c.entity.teleport(self_pos)
  for _, m in ipairs(moved) do
    if m.entity.valid then m.entity.teleport(m.pos) end
  end
  return ok, err
end

-- Temporarily remove tree/simple-entity (rock) obstacles from an entity's footprint
-- so a can_place_entity check reflects what queues.lua's clear_build_area will ACTUALLY
-- leave behind at build time, not raw ground-truth right now (2026-07-08, task #47,
-- Zdendys: "During construction nothing may be surrounded by trees, the MOD's job is to
-- clear the area before construction!" -- pick_orientation was rejecting candidates over trees/rocks that
-- the build step removes anyway, live-caught: "no free orientation (all sides
-- blocked)" on an ore patch with a single nearby tree). Mirrors clear_build_area's OWN
-- area computation (queues.lua) exactly, and the existing ignore_entities_at
-- teleport-and-restore pattern above -- reusing the engine's real collision check
-- instead of reimplementing "is this a removable obstacle" logic separately.
local function clear_natural_obstacles(surf, entity_name, position)
  local proto = prototypes.entity[entity_name]
  if not proto or not proto.collision_box then return {} end
  local bb = proto.collision_box
  local area = {
    {x = position.x + bb.left_top.x - 0.5, y = position.y + bb.left_top.y - 0.5},
    {x = position.x + bb.right_bottom.x + 0.5, y = position.y + bb.right_bottom.y + 0.5}
  }
  local moved = {}
  local obstacles = surf.find_entities_filtered{area = area, type = {"tree", "simple-entity"}}
  for _, obs in ipairs(obstacles) do
    if obs.valid then
      moved[#moved + 1] = {entity = obs, pos = {x = obs.position.x, y = obs.position.y}}
      obs.teleport({x = obs.position.x + 10000, y = obs.position.y + 10000})
    end
  end
  return moved
end

local function restore_moved(moved)
  for _, m in ipairs(moved) do
    if m.entity.valid then m.entity.teleport(m.pos) end
  end
end

run_pick_orientation_checks = function(c, t, step, surf)
  -- Per-candidate diagnostic (2026-07-08, task #47, live-caught: "no free orientation
  -- (all sides blocked)" on an ore patch that LOOKED like it had room -- the only
  -- diagnostic available was a dump of entities near the PRIMARY position, not each
  -- of the actual secondary candidates, so it was impossible to tell whether all 4
  -- were genuinely blocked or something else was wrong). Collected regardless of
  -- outcome; only logged if every candidate ultimately fails.
  local candidate_diag = {}
  for _, off in ipairs(step.offsets) do
    local sx, sy = t.ctx.px + off[1], t.ctx.py + off[2]
    -- Compute the REAL defines.direction value BEFORE checking can_place_entity
    -- (2026-07-07, live-caught collision bug): this mod uses TWO different
    -- direction numbering systems -- u.dir_map's "simple" 0-3 (matches the MCP
    -- tools API convention) vs. Factorio's own raw defines.direction enum
    -- (north=0, east=4, south=8, west=12, 16-direction system). The check here
    -- was using NO direction (defaulting to north's footprint), while the actual
    -- placement later passed the SIMPLE 0-3 value straight into queues.start_build
    -- (which expects a raw defines.direction value) -- e.g. simple "2" (meant as
    -- south) was literally interpreted as raw direction 2 (northeast), a
    -- completely different rotation than what was just verified as fitting.
    -- Checking and placing with the SAME correctly-translated direction fixes
    -- both the wrong rotation AND the check/placement mismatch in one go.
    local simple_dir
    if off[1] == 0 and off[2] > 0 then simple_dir = 2
    elseif off[1] == 0 and off[2] < 0 then simple_dir = 0
    elseif off[1] > 0 then simple_dir = 1
    else simple_dir = 3 end
    local real_dir = u.dir_map[simple_dir]
    -- opposite_direction (2026-07-07, coal_pair): two SAME-type entities (e.g. two
    -- burner-mining-drills) facing EACH OTHER so each one's mined output auto-feeds
    -- the other's fuel inventory (real vanilla mechanic, no cheat -- matches the
    -- already-live-verified geometry in spatial_bc.py's _build_coal_drill_pair).
    -- Without this the secondary would default to facing north regardless of which
    -- side it's on, which is wrong for a drill (though harmless for a directionless
    -- chest/furnace) and would also make its OWN can_place_entity check below use
    -- the wrong footprint if that entity's collision box isn't rotation-symmetric.
    local secondary_dir = real_dir
    if step.opposite_direction then
      secondary_dir = u.dir_map[(simple_dir + 2) % 4]
    end
    -- primary_exists (2026-07-07, furnace-upgrade task): the primary is an
    -- ALREADY-PLACED entity (e.g. from find_existing) -- it's not being placed
    -- by this task, so it must NOT be can_place_entity-checked (it already
    -- occupies that spot; checking would always fail against itself).
    local primary_moved = not step.primary_exists and
      clear_natural_obstacles(surf, step.primary, {x = t.ctx.px, y = t.ctx.py}) or {}
    local primary_ok = step.primary_exists or
      surf.can_place_entity{name = step.primary, position = {x = t.ctx.px, y = t.ctx.py}, direction = real_dir, force = c.entity.force}
    restore_moved(primary_moved)
    -- secondary_resource (2026-07-07, furnace-upgrade task): the secondary's
    -- candidate tile must ALSO have this resource underneath (e.g. a new drill
    -- next to an existing furnace still needs REAL ore there) -- otherwise a
    -- tile that merely passes can_place_entity but sits on bare ground would be
    -- silently accepted, matching the same real-ore requirement run_verify_tile
    -- already enforces for a find_patch-derived primary.
    local secondary_resource_ok = true
    if step.secondary_resource then
      local ore = surf.find_entities_filtered{name = step.secondary_resource, position = {x = sx, y = sy}, radius = 1}
      secondary_resource_ok = #ore > 0
    end
    local secondary_moved = clear_natural_obstacles(surf, step.secondary, {x = sx, y = sy})
    local secondary_ok = surf.can_place_entity{name = step.secondary, position = {x = sx, y = sy}, direction = secondary_dir, force = c.entity.force}
    restore_moved(secondary_moved)
    if primary_ok and secondary_resource_ok and secondary_ok then
      t.ctx.sx, t.ctx.sy = sx, sy
      t.ctx.dir = real_dir
      t.ctx.dir2 = secondary_dir
      -- Kept alongside sx/sy so the primary's "place" step can RECOMPUTE the
      -- secondary's position once the primary's REAL (possibly snapped) placed
      -- position is known -- see the note where offset_dx/dy is consumed below.
      -- (Not relevant when primary_exists -- there is no primary "place" step
      -- to recompute anything from, the furnace's position never changes.)
      t.ctx.offset_dx, t.ctx.offset_dy = off[1], off[2]
      return true
    end
    -- Diagnostic: WHY this specific candidate failed, plus what's actually there.
    -- 2026-07-12 (task #46): uses the shared u.dump_context() helper instead of a
    -- hand-rolled find_entities_filtered loop (see queues.lua's collision diagnostic
    -- for the OTHER caller) -- picks up a tile-name check for free, which this
    -- candidate diagnostic never had before (a strict improvement, not a behavior
    -- change to the entity-name part).
    local diag = u.dump_context(surf, {x = sx, y = sy}, {radius = 1.5})
    candidate_diag[#candidate_diag + 1] = string.format(
      "off(%d,%d)@(%.1f,%.1f) primary_ok=%s secondary_resource_ok=%s secondary_ok=%s tile=%s nearby=[%s]",
      off[1], off[2], sx, sy, tostring(primary_ok), tostring(secondary_resource_ok),
      tostring(secondary_ok), diag.tile, table.concat(diag.nearby, ","))
  end
  u.log_error("pick_orientation: no free orientation for " .. step.secondary ..
    " around (" .. t.ctx.px .. "," .. t.ctx.py .. ") -- " .. table.concat(candidate_diag, " | "),
    "pick_orientation")
  return false, "no free orientation (all sides blocked)"
end

-- ---- main scheduler tick ----

-- Picks the single best (task, step) to advance right now: among all ACTIVE, READY
-- tasks whose companion is currently IDLE, prefer the one whose current step's
-- target is CLOSEST to the companion; ties broken by task_id (older task wins --
-- Zdendys: "stari kroku odpovida cca poradi taskID").
local function pick_next(cid, c)
  local best_task_id, best_dist = nil, math.huge
  for task_id, t in pairs(storage.tasks) do
    if t.cid == cid and t.status == "active" and task_ready(t) and t.cursor <= #t.steps then
      local step = t.steps[t.cursor]
      local pos = step_target_pos(t, step)
      local dist = pos and u.distance(c.entity.position, pos) or 0  -- instant steps: distance 0, always win ties by task_id
      if dist < best_dist or (dist == best_dist and (not best_task_id or task_id < best_task_id)) then
        best_task_id, best_dist = task_id, dist
      end
    end
  end
  return best_task_id
end

-- Re-check every active task's outstanding `needs` against CURRENT inventory
-- (2026-07-07, live-caught in scripts/test_task_pool.py: a task submitted before
-- its coal arrived stayed stuck on cursor 1 forever -- `needs` was computed ONCE
-- at submit_task time and nothing ever refreshed it afterward, even though the
-- whole point of submitting ahead of having materials is that something else
-- -- gather_queues, another task's own by-product, a later delivery -- can supply
-- them in the meantime). Iterates tasks in task_id order (oldest first) so an
-- older task claims newly-available stock before a younger one, consistent with
-- the pool's own task_id tiebreak elsewhere.
--
-- ONLY does this work for companions whose inventory actually CHANGED since the
-- last tick (2026-07-07, Zdendys: "Ono neni jakym jinym zpusobem, bez zasahu
-- companiona samotneho, by doslo ke zmene stavu jeho inventare!" -- correct,
-- inventory only ever changes as a result of the companion's OWN actions
-- (mining/crafting/fueling/collecting), so polling get_item_count for every
-- outstanding need on EVERY tick regardless was wasted work on every tick where
-- nothing could possibly have changed. storage.inv_count_cache[cid] tracks the
-- last-seen total item count per companion; a plain sum is enough to detect ANY
-- change cheaply without needing to hook into every individual queue type's own
-- completion point (harvest/gather/craft/fuel/build each add or remove items in
-- their own way -- comparing the total sidesteps enumerating all of them).
local function refresh_needs()
  local ids = {}
  for task_id, t in pairs(storage.tasks) do
    if t.status == "active" and next(t.needs) ~= nil then ids[#ids + 1] = task_id end
  end
  if #ids == 0 then return end
  table.sort(ids)
  storage.inv_count_cache = storage.inv_count_cache or {}
  -- reservation_epoch check (2026-07-09, see release_reservations' own comment for the
  -- full live-caught symptom): a task's needs must be re-evaluated not just when ITS
  -- OWN companion's inventory total changes, but also whenever ANY task anywhere
  -- released a reservation -- that release alone can be exactly what makes previously
  -- unavailable stock available now, with zero accompanying inventory-total change
  -- for THIS companion. epoch_changed is true at most once per actual release (cheap),
  -- and forces the full inv-count-mismatch bypass below for every pending task this
  -- call, exactly once.
  local epoch = storage.reservation_epoch or 0
  local epoch_changed = (storage.last_seen_reservation_epoch or -1) ~= epoch
  storage.last_seen_reservation_epoch = epoch
  for _, task_id in ipairs(ids) do
    local t = storage.tasks[task_id]
    local c = u.get_companion(t.cid)
    if c then
      local inv = c.entity.get_main_inventory()
      local total = inv.get_item_count()
      if storage.inv_count_cache[t.cid] ~= total or epoch_changed then
        storage.inv_count_cache[t.cid] = total
        for item, deficit in pairs(t.needs) do
          local have = inv.get_item_count(item)
          local already_reserved = storage.reserved[item] or 0
          local available = math.max(0, have - already_reserved)
          local take = math.min(available, deficit)
          if take > 0 then
            storage.reserved[item] = already_reserved + take
            t.reserved[item] = (t.reserved[item] or 0) + take
            if take >= deficit then
              t.needs[item] = nil
            else
              t.needs[item] = deficit - take
            end
          end
        end
      end
    end
  end
end

-- 2026-07-08, task #42: true if cid is busy in gather/fuel/build/belt_queues (see the
-- "Extended" comment at this function's call site below for the full rationale).
local function busy_elsewhere(cid)
  return (storage.gather_queues and storage.gather_queues[cid])
      or (storage.fuel_queues and storage.fuel_queues[cid])
      or (storage.build_queues and storage.build_queues[cid])
      or (storage.belt_queues and storage.belt_queues[cid])
end

function M.tick()
  refresh_needs()
  for cid, active in pairs(storage.active_step) do
    local c = u.get_companion(cid)
    if not c then storage.active_step[cid] = nil; goto continue end
    local t = storage.tasks[active.task_id]
    if not t or t.status ~= "active" then storage.active_step[cid] = nil; goto continue end
    local step = t.steps[t.cursor]

    if active.state == "walking" then
      if not storage.walking_queues[cid] then
        -- Arrived (or walking_queue was never set for a non-walk step) -> act.
        active.state = "acting"
      elseif active.approach_deadline and game.tick >= active.approach_deadline then
        -- Bounded give-up (2026-07-08/09, task-pool's OWN walking phase previously had
        -- NO deadline at all -- see the dispatch site's own comment for the live
        -- symptom this caused). Mirrors queues.lua's identical "cannot reach -> fail
        -- and let the caller retry/relocate" pattern instead of spinning forever.
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        ledger.fail_task(active.task_id, "could not reach step target (walking timed out)")
        storage.active_step[cid] = nil
        goto continue
      else
        goto continue  -- still walking, check again next tick
      end
    end

    if active.state == "acting" then
      local ok, err = true, nil
      if step.type == "place" then
        -- Handled entirely inline (not via the generic ok/err fall-through below,
        -- see the bug note there): start_build's OWN failure is reported
        -- immediately (queues.start_build never queues anything in that case, so
        -- there is no later "building" state to catch it) -- fail_task here or the
        -- task would sit stuck in "acting" forever with active_step never cleared.
        local pos = step_target_pos(t, step)
        -- Explicit step.dir (simple 0-3, 2026-07-07 coal_pair upgrade) overrides
        -- ctx.dir/dir2 when the caller precomputed the whole layout itself (no
        -- pick_orientation step at all for this task) -- translated the SAME way
        -- pick_orientation does, so callers use the identical simple convention.
        local place_dir
        if step.dir ~= nil then
          place_dir = u.dir_map[step.dir]
        else
          place_dir = (step.which == "secondary" and t.ctx.dir2) or t.ctx.dir or 0
        end
        -- candidates (2026-07-07, live-caught): a SINGLE precomputed {x,y,dir}
        -- position (e.g. an inserter placed 1 tile from a chest read via
        -- read_drop_position) can intermittently collide -- observed twice
        -- across separate live runs with the EXACT same code on different maps
        -- (sub-tile snap variance at that specific spot, not a logic bug). An
        -- optional list of {x=,y=,dir=} alternatives lets the caller offer a
        -- few nearby fallback spots; the FIRST one that passes can_place_entity
        -- is used, mirroring pick_orientation's own try-candidates-in-order
        -- robustness instead of committing to one fixed spot with no recourse.
        if step.candidates then
          local surf = c.entity.surface
          local chosen = nil
          for _, cand in ipairs(step.candidates) do
            local cdir = u.dir_map[cand.dir or 0]
            if surf.can_place_entity{name = step.entity, position = {x = cand.x, y = cand.y}, direction = cdir, force = c.entity.force, mirror = step.mirror} then
              chosen = {x = cand.x, y = cand.y, dir = cdir}
              break
            end
          end
          if not chosen then
            -- Bounded retry across ticks (2026-07-08, task #35) instead of failing on
            -- the FIRST check: live-observed "no candidate position free" 3x across
            -- separate runs with the exact same code on different maps, leading
            -- hypothesis being a transient/settling-timing collision (sub-tile snap
            -- variance, or a moment where something else briefly occupies the tile)
            -- rather than a genuine permanent block. can_place_entity is re-evaluated
            -- fresh every tick (no caching here), so simply trying again on a LATER
            -- tick gives a transient blocker a real chance to clear before giving up
            -- -- same "bounded deadline, not instant give-up" pattern already used for
            -- approach_deadline elsewhere in this file. 60 ticks is deliberately short
            -- (this is meant to catch a passing moment, not wait out a real block) --
            -- a genuinely permanent collision still correctly fails, just after a
            -- few retries instead of zero.
            active.candidate_retry_deadline = active.candidate_retry_deadline or (game.tick + 60)
            if game.tick < active.candidate_retry_deadline then
              goto continue
            end
            ledger.fail_task(active.task_id, "no candidate position free for " .. step.entity)
            storage.active_step[cid] = nil
            goto continue
          end
          pos, place_dir = {x = chosen.x, y = chosen.y}, chosen.dir
        end
        local r = queues.start_build(cid, step.entity, pos, place_dir, step.mirror)
        if r.error then
          ledger.fail_task(active.task_id, r.error)
          storage.active_step[cid] = nil
        else
          -- Poll build_queues to completion via the SEPARATE "building" state
          -- below (own stale-progress backstop, same as every other queue type).
          active.state = "building"
        end
      elseif step.type == "ensure_item" then
        -- Handled entirely inline, like "place" above (see this step type's own
        -- header comment, near WOOD_CHOP_REACH, for the full design). Genuinely
        -- async (gather/craft/chop can each take many ticks) -- excluded from the
        -- generic ok/err fall-through below the same way "place" is.
        t.ctx.ensure_stack = t.ctx.ensure_stack or {{item = step.item, count = step.count}}
        local kind, err2 = start_ensure_item_action(c, cid, t)
        if kind == "satisfied" then
          table.remove(t.ctx.ensure_stack)
          if #t.ctx.ensure_stack == 0 then
            -- Reset to nil, not just an empty table (2026-07-17, live-caught crash:
            -- "attempt to index local 'need' (a nil value)" at start_ensure_item_action's
            -- own `local need = stack[#stack]`). t.ctx is shared across ALL steps of
            -- this task, and a task can have MULTIPLE ensure_item steps in a row (e.g.
            -- build_ore_drill_row_unit_steps' burner-mining-drill THEN stone-furnace,
            -- coal_pair.py). Leaving ensure_stack as `{}` here made line 866's own
            -- `t.ctx.ensure_stack or {...}` initializer a no-op for the NEXT ensure_item
            -- step -- an empty table is truthy in Lua -- so that step ran
            -- start_ensure_item_action against a permanently empty stack instead of
            -- pushing its own need, crashing every tick forever (active_step never
            -- cleared -> companion deadlocked for the rest of the episode).
            t.ctx.ensure_stack = nil
            t.cursor = t.cursor + 1
            storage.active_step[cid] = nil
            if t.cursor > #t.steps then ledger.complete_task(active.task_id) end
          end
          -- else: stay in "acting" this same tick's next pass (goto continue below
          -- falls through to end-of-loop; re-entering "acting" next tick reassesses
          -- the now-shorter stack) -- no state change needed, active.state is
          -- already "acting".
        elseif kind == "push" then
          -- A deeper ingredient need was pushed -- reassess next tick against the
          -- new top of stack, same as "satisfied"'s implicit re-entry above.
        elseif kind == "gather" or kind == "craft" then
          active.state = "ensuring"
          active.ensuring_kind = kind
        elseif kind == "chop" then
          -- Skip the walk entirely if already close enough (mirrors "place"'s own
          -- distance check in the idle-dispatch loop below) -- go straight to
          -- chop_mine so a tree that happens to be right next to the companion
          -- doesn't pay for a pointless 1-tick walking_queue round trip.
          if u.distance(c.entity.position, t.ctx.wood_target) <= WOOD_CHOP_REACH then
            active.state = "ensuring"
            active.ensuring_kind = "chop_mine"
          else
            storage.walking_queues[cid] = {target = t.ctx.wood_target}
            active.state = "ensuring"
            active.ensuring_kind = "chop_walk"
            active.chop_deadline = u.approach_deadline(c.entity.position, t.ctx.wood_target)
          end
        else
          ledger.fail_task(active.task_id, err2 or "ensure_item failed")
          storage.active_step[cid] = nil
        end
      elseif step.type == "remove" then
        -- Pick up an existing entity (2026-07-07, coal_pair upgrade task: reuses
        -- the 2 ALREADY-BUILT coal_pair drills rather than crafting new ones --
        -- Zdendys: "zvedne obe vrtacky, nemusi je vyrabet"). Uses the SAME
        -- native-mine pattern already proven in commands/building.lua's
        -- fac_mine_entity (target.mine{inventory=...}, success measured by
        -- inventory count actually increasing -- mine{} leaves the entity INTACT
        -- if the inventory can't hold the result, no silent item loss/no cheat).
        local pos = step_target_pos(t, step)
        local es = c.entity.surface.find_entities_filtered{
          name = step.entity, position = pos, radius = 1}
        if #es == 0 then
          ok, err = false, "no " .. step.entity .. " found to remove at target"
        else
          local inv = c.entity.get_main_inventory()
          local before = inv.get_item_count()
          es[1].mine{inventory = inv}
          ok = (inv.get_item_count() - before) > 0
          err = ok and nil or "could not mine (inventory full?)"
        end
      elseif step.type == "fuel" then
        local pos = step_target_pos(t, step)
        local inv = c.entity.get_main_inventory()
        local have = inv.get_item_count(step.item)
        if have == 0 then
          ok, err = false, "no " .. step.item .. " in inventory"
        else
          local es = c.entity.surface.find_entities_filtered{
            position = pos, radius = FUEL_REACH,
            type = {"furnace", "boiler", "burner-inserter", "mining-drill"}}
          if #es == 0 then
            ok, err = false, "no burner near target"
          else
            local remaining = step.count or 1
            for _, e in ipairs(es) do
              if remaining <= 0 then break end
              local fi = e.get_fuel_inventory()
              if fi then
                local n = math.min(remaining, have)
                local inserted = fi.insert({name = step.item, count = n})
                if inserted > 0 then
                  c.entity.remove_item({name = step.item, count = inserted})
                  remaining = remaining - inserted
                  have = have - inserted
                end
              end
            end
          end
        end
      elseif step.type == "find_patch" then
        ok, err = run_find_patch(c, t, step)
      elseif step.type == "find_existing" then
        ok, err = run_find_existing(c, t, step)
      elseif step.type == "set_position" then
        ok, err = run_set_position(c, t, step)
      elseif step.type == "verify_tile" then
        ok, err = run_verify_tile(c, t, step)
      elseif step.type == "pick_orientation" then
        ok, err = run_pick_orientation(c, t, step)
      elseif step.type == "read_drop_position" then
        ok, err = run_read_drop_position(c, t, step)
      else
        ok, err = false, "unknown step type " .. tostring(step.type)
      end

      -- "place"/"ensure_item" are fully handled above (either resolved inline, or
      -- transitioned to their own separate polling state) -- every OTHER step
      -- type completes synchronously within this same tick, so their ok/err is
      -- resolved here.
      if step.type ~= "place" and step.type ~= "ensure_item" then
        if ok then
          t.cursor = t.cursor + 1
          storage.active_step[cid] = nil
          if t.cursor > #t.steps then ledger.complete_task(active.task_id) end
        else
          ledger.fail_task(active.task_id, err)
          storage.active_step[cid] = nil
        end
      end
    end

    if active.state == "building" then
      local st = queues.get_build_status(cid)
      if st.active then
        goto continue  -- still building, check again next tick
      elseif st.placed then
        -- Sync ctx to the REAL placed position (2026-07-07, live-caught): create_entity
        -- can snap a 2x2 entity to a different grid alignment than the 1x1 ore tile
        -- position find_patch recorded (observed: requested (46.5,-185.5), actually
        -- landed at (47,-185)). If this was the PRIMARY and a secondary offset was
        -- already chosen (pick_orientation ran before this), recompute sx/sy from the
        -- REAL px/py so the secondary's own place step doesn't overlap the primary's
        -- true footprint -- fuel steps use step_target_pos too, so this must happen
        -- before either later step's target position is read.
        if step.which == "primary" and st.position then
          t.ctx.px, t.ctx.py = st.position.x, st.position.y
          if t.ctx.offset_dx then
            t.ctx.sx = t.ctx.px + t.ctx.offset_dx
            t.ctx.sy = t.ctx.py + t.ctx.offset_dy
          end
        elseif step.which == "secondary" and st.position then
          t.ctx.sx, t.ctx.sy = st.position.x, st.position.y
        end
        t.cursor = t.cursor + 1
        storage.active_step[cid] = nil
        if t.cursor > #t.steps then ledger.complete_task(active.task_id) end
      else
        ledger.fail_task(active.task_id, st.error or "build failed")
        storage.active_step[cid] = nil
      end
    end

    if active.state == "ensuring" then
      -- Polls whichever underlying queue/walk start_ensure_item_action started,
      -- to completion, then falls back to "acting" so the NEXT "acting" pass
      -- reassesses t.ctx.ensure_stack fresh (real inventory counts, not a
      -- remembered target) -- exactly like ensure_item's own Python recursion,
      -- one incremental step of progress per round trip through this state.
      if active.ensuring_kind == "gather" then
        local st = queues.get_gather_status(cid)
        if st.active then goto continue end
        active.state = "acting"
      elseif active.ensuring_kind == "craft" then
        local st = queues.get_craft_status(cid)
        if st.active then goto continue end
        active.state = "acting"
      elseif active.ensuring_kind == "chop_walk" then
        if not storage.walking_queues[cid] then
          active.ensuring_kind = "chop_mine"  -- arrived -> fall through below, same tick
        elseif active.chop_deadline and game.tick >= active.chop_deadline then
          -- Bounded give-up (mirrors every other approach_deadline in this file):
          -- blacklist this SPECIFIC tree so the next "acting" pass picks a
          -- DIFFERENT one instead of re-selecting the identical unreachable tree
          -- forever (the exact "no exclude" bug class already fixed once for
          -- _chop_wood itself, spatial_demo.py -- applied here from the start).
          storage.walking_queues[cid] = nil
          c.entity.walking_state = {walking = false}
          local key = math.floor(t.ctx.wood_target.x) .. "," .. math.floor(t.ctx.wood_target.y)
          t.ctx.wood_tried[key] = true
          active.state = "acting"
        else
          goto continue
        end
      end
      if active.state == "ensuring" and active.ensuring_kind == "chop_mine" then
        local trees = c.entity.surface.find_entities_filtered{
          type = "tree", position = t.ctx.wood_target, radius = 1}
        if trees[1] and trees[1].valid then
          local inv = c.entity.get_main_inventory()
          local before = inv.get_item_count("wood")
          trees[1].mine{inventory = inv}
          if inv.get_item_count("wood") > before then
            t.ctx.wood_chop_count = (t.ctx.wood_chop_count or 0) + 1
          else
            -- Mined but yielded nothing new (inventory full?) -- blacklist so this
            -- exact tree isn't retried forever; a genuinely full inventory will
            -- surface via the NEXT tree's identical failure, not silently loop.
            local key = math.floor(t.ctx.wood_target.x) .. "," .. math.floor(t.ctx.wood_target.y)
            t.ctx.wood_tried[key] = true
          end
        else
          -- Tree gone (another companion/process claimed it between selection and
          -- arrival) -- blacklist and retry with a fresh selection, don't fail the
          -- whole task over a single vanished tree.
          local key = math.floor(t.ctx.wood_target.x) .. "," .. math.floor(t.ctx.wood_target.y)
          t.ctx.wood_tried[key] = true
        end
        active.state = "acting"
      end
    end
    ::continue::
  end

  -- Companion(s) currently idle -> pick the next (task, step) to start.
  -- MUST also check storage.walking_queues[cid] is empty, not just active_step[cid]
  -- (2026-07-08, Zdendys live-caught via a movement/distance statistics review: "could
  -- not reach furnace" firing even at trivial distances like 12-18 tiles, proving this
  -- was never about map layout). active_step[cid] only tracks whether the TASK POOL
  -- itself is driving this companion -- it says nothing about an UNRELATED walk Python
  -- may have just started via /fac_move_to (e.g. spatial_bc.py's go_to() for furnace
  -- servicing, iron_drill upgrade, etc.), which sets storage.walking_queues[cid]
  -- directly without ever touching active_step[cid]. Without this guard, THIS loop
  -- runs every tick and, the moment a task-pool task is ready to walk somewhere, freely
  -- overwrites storage.walking_queues[cid] mid-flight -- silently discarding whatever
  -- unrelated destination Python had just set, so the companion walks toward the
  -- task-pool's target instead while Python's wait_arrive() keeps blocking on a
  -- destination she was never actually walking to anymore. Confirmed live: coal_pair's
  -- task-pool build was active in the SAME window as a failed "could not reach furnace"
  -- iron_drill-upgrade go_to(), at a distance (12-18 tiles) trivially walkable otherwise.
  -- Extended (2026-07-08, task #42, same session as the walking_queues fix above):
  -- walking_queues[cid] alone only protects the WALKING phase of gather/fuel/build/
  -- belt_queues -- once one of those arrives and moves on to its own "acting" phase
  -- (mining, fueling, placing), walking_queues[cid] clears (arrival) while the
  -- companion is STILL busy for that subsystem's purposes. Without also checking
  -- these, the task pool could grab a companion mid-mine/mid-fuel/mid-build from a
  -- direct (non-task-pool) command and redirect her walking_queues[cid] to its own
  -- target, corrupting that other queue's in-progress state. None of these are set
  -- by the task pool itself (task_pool.lua never calls start_gather/start_fuel_group/
  -- start_belt_connect, and start_build's task-pool-internal use is guarded
  -- separately at the fac_building_place_start command level, not here), so this
  -- check is one-directional and safe: it only ever holds off task_pool for a
  -- companion genuinely busy elsewhere.
  for cid, c in pairs(storage.companions or {}) do
    if c.entity and c.entity.valid and not storage.active_step[cid]
       and not storage.walking_queues[cid] and not busy_elsewhere(cid) then
      local task_id = pick_next(cid, c)
      if task_id then
        local t = storage.tasks[task_id]
        local step = t.steps[t.cursor]
        local pos = step_target_pos(t, step)
        if pos and u.distance(c.entity.position, pos) > WALK_REACH then
          storage.walking_queues[cid] = {target = pos}
          -- approach_deadline (2026-07-08/09, live-caught: run_reactive's own new
          -- async-pending stale-exemption -- added specifically to stop penalizing
          -- LEGITIMATE in-flight task-pool work -- immediately started firing its
          -- "task-pool work pending for 40 actions with no resolution" backstop
          -- repeatedly, live, meaning this "walking" state genuinely never resolves
          -- on its own sometimes). Root cause: unlike EVERY OTHER queue type in this
          -- codebase (queues.lua's tick_gather_queues/tick_fuel_queues/
          -- tick_build_queues, pathfind.lua's belt_connect walk), this generic
          -- task-pool "walking" state (tick()'s own handler right above) had NO
          -- deadline at all -- if storage.walking_queues[cid] never clears (a
          -- persistently blocked approach, or some other queue silently claiming the
          -- companion mid-walk), active.state just sits at "walking" forever, the
          -- task never transitions to done/failed, and Python's own task_status()
          -- poll waits indefinitely. Distance-scaled exactly like
          -- tick_gather_queues' own q.approach_deadline (25 ticks/tile, floor 1800)
          -- for consistency with the rest of the codebase's convention.
          local walk_deadline = u.approach_deadline(c.entity.position, pos)
          storage.active_step[cid] = {task_id = task_id, state = "walking",
                                       approach_deadline = walk_deadline}
        else
          storage.active_step[cid] = {task_id = task_id, state = "acting"}
        end
      end
    end
  end
end

-- Diagnostic (2026-07-09, task pool investigation): dumps everything relevant to WHY a
-- companion's task-pool work might be stuck -- active_step state/deadline, the task's
-- own status/cursor/needs, walking_queues entry, and the busy_elsewhere flags -- in one
-- call, so a live stall can be root-caused without guessing from static code reading.
-- Read-only, no side effects.
function M.get_diag(cid)
  local active = storage.active_step and storage.active_step[cid]
  local out = {
    active_step = active and {
      task_id = active.task_id, state = active.state,
      approach_deadline = active.approach_deadline,
      ticks_until_deadline = active.approach_deadline and (active.approach_deadline - game.tick) or nil,
      candidate_retry_deadline = active.candidate_retry_deadline,
    } or nil,
    walking_queue = storage.walking_queues and storage.walking_queues[cid] and {
      target = storage.walking_queues[cid].target,
    } or nil,
    busy_gather = (storage.gather_queues and storage.gather_queues[cid]) and true or false,
    busy_fuel = (storage.fuel_queues and storage.fuel_queues[cid]) and true or false,
    busy_build = (storage.build_queues and storage.build_queues[cid]) and true or false,
    busy_belt = (storage.belt_queues and storage.belt_queues[cid]) and true or false,
    -- 3 queue types added 2026-07-09 (task #46, "faster error diagnosis"): get_diag
    -- otherwise silently omitted these 3 of the 7 async queue types that
    -- companion_queue_status (init.lua) already knows about, so a companion stuck
    -- specifically on a harvest/craft/combat queue looked indistinguishable from
    -- "not busy at all" through this diagnostic.
    busy_harvest = (storage.harvest_queues and storage.harvest_queues[cid]) and true or false,
    busy_craft = (storage.craft_queues and storage.craft_queues[cid]) and true or false,
    busy_combat = (storage.combat_queues and storage.combat_queues[cid]) and true or false,
  }
  if active and active.task_id then
    local t = storage.tasks[active.task_id]
    if t then
      out.task = {status = t.status, cursor = t.cursor, total_steps = #t.steps,
                  needs = t.needs, step_type = t.steps[t.cursor] and t.steps[t.cursor].type}
    end
  end
  -- Merge in gather's own richer engine-level diagnostics (state/selected/
  -- mining_state_mining/entity_pos, added 2026-07-09 for the #41 stall investigation)
  -- so a stuck-on-gather companion doesn't need a SEPARATE /fac_gather_status round
  -- trip on top of this call (task #46). peek=true (2026-07-11): this function is
  -- explicitly documented as read-only/no-side-effects -- must NOT consume+clear a
  -- gather queue's terminal "done" state (see get_gather_status's own "peek" comment
  -- for why that would silently discard the final gathered count).
  if out.busy_gather then
    out.gather = queues.get_gather_status(cid, true)
  end
  -- Last few entries of the errors ring buffer (task #46): surfaces recent silent
  -- pcall failures (u.error_response/u.log_error, storage.errors, capped 50 total)
  -- right alongside the queue/task state that was active when they happened, instead
  -- of needing a separate /fac_get_errors call and manually correlating timestamps.
  -- Capped at 5 here (not all 50) to keep this diagnostic response focused on what's
  -- actionable RIGHT NOW rather than dumping the whole history every time.
  local errs = storage.errors or {}
  local recent = {}
  for i = math.max(1, #errs - 4), #errs do recent[#recent + 1] = errs[i] end
  out.recent_errors = recent
  return out
end

return M
