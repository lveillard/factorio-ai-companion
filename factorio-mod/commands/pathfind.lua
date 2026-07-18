-- AI Companion v0.9.0 - Belt-connection pathfinding (Stage 0.2, 2026-07-04)
-- A* over the tile grid between two points, avoiding resource-entity tiles (a belt
-- corridor must route AROUND an un-mined ore/coal/stone patch, never over it -- Zdendys:
-- "it should avoid all resource patches and water too") and anything else that blocks a
-- transport-belt (water, cliffs, existing buildings/trees/rocks -- delegated to the
-- ENGINE's own surf.can_place_entity check rather than re-implementing collision rules,
-- so it stays correct as the game's placement logic evolves), with a small turn-penalty
-- so the result is a reasonably direct corridor, not a serpentine walk ("not just some
-- zigzagging snake"). Bounded search area + node cap so a genuinely blocked/far target fails
-- fast instead of burning the RCON command's time budget.
local M = {}

-- MAX_SEARCH_MARGIN raised 15->40 (2026-07-05, Zdendys live-caught: a diagnostic sweep of
-- 7 distances/shapes on ONE fresh map found a NON-monotonic success pattern by bounding-box
-- area -- e.g. a 2340-tile-area route failed "no path" while a LARGER 7018-tile-area route
-- on the SAME map succeeded -- inconsistent with a pure node-budget explanation (which would
-- predict smaller-area routes succeed more reliably than larger ones). This points to a real
-- obstacle (most likely a lake, since this mod's map-gen deliberately favors a nearby water
-- body for the power plant) that some specific routes need to detour around by MORE than the
-- old 15-tile margin, independent of how many nodes the search budget allows -- no margin
-- increase can be substituted for by a bigger MAX_NODES, since a blocked tile just outside
-- the bounding box is never even a candidate node regardless of budget. 40 gives real
-- clearance for a sizeable lake without exploding the search area unreasonably (the
-- companion's own tie-break fix, added the same day, already lets the search converge
-- toward the goal instead of fanning out across the whole box, so a wider margin shouldn't
-- by itself blow the existing MAX_NODES budget for the common case).
local MAX_SEARCH_MARGIN = 60     -- tiles of slack around the from/to bounding box (2026-07-08,
-- raised 40->60, Zdendys: "vetsina vody nelze podejit" -- a genuinely wide lake needs real
-- room to route around, not just underground-belt's 5-tile max span (see UNDERGROUND_MAX_
-- DISTANCE below); 40 already got raised once for the same reason (see history above) and
-- live-caught tonight (bc_0708night1) still hit "no path" on a ~93-tile route.
local MAX_NODES = 128000         -- hard cap on A* expansions (bounded, no infinite loop) -- raised
-- 2500->4000 alongside the margin increase so the larger search area doesn't just make the
-- SAME "no path" failure happen after burning more of the budget with no detour room to show
-- for it -- both numbers need to move together.
--
-- Raised 4000->8000 (2026-07-10, task #43, alongside the open-list binary-heap change
-- above -- NOT a standalone "just raise the number again" tweak, this project's own
-- established anti-pattern; done because the heap made a larger cap cheap AND there is
-- real, reproducible offline evidence the bigger cap alone fixes a genuine failure --
-- see the correction below, though, for what this evidence does NOT yet cover). Offline
-- `lua5.3` measurements (scratchpad harness, not committed -- see task report) on the
-- exact worst case this number governs (search must exhaust the ENTIRE node budget,
-- e.g. a genuinely unreachable/heavily-obstacle-laden target): the OLD linear-scan pop
-- cost ~108-119ms at 4000 nodes and would have cost ~227ms at 8000 (measured directly,
-- reproduced independently twice more during adversarial verify) -- doubling the budget
-- under the old algorithm would have meaningfully increased real cost. With the heap,
-- 8000 nodes costs only ~45-51ms -- LESS than the OLD code's own cost at the SMALLER
-- 4000 cap. Separately, a synthetic ~130-tile route over deliberately scattered
-- obstacles (12% blocked terrain) hit "budget-exhausted" at 4000 nodes despite a real
-- 143-tile path existing just beyond that cutoff -- raising to 8000 found it, at no
-- measurable extra cost. This synthetic case is real, reproducible evidence for the cap
-- bump on its own terms.
--
-- CORRECTION (2026-07-10, same day, caught during adversarial verify): an earlier draft
-- of this comment additionally claimed the live scripts/test_belt_connect_dest_diag.py
-- diagnostic "confirmed" this fix by going from 4/8 to 5/8 genuine pathfinds -- that
-- claim was overclaimed and has been removed. The two runs used two DIFFERENT sets of 8
-- fresh random maps; the delta is a single flipped sample, and this project's OWN memory
-- already documents an earlier 1/8->4/8 jump on this same diagnostic with ZERO relevant
-- code change, i.e. within normal map-to-map noise for n=8. All 3 remaining failures in
-- the post-bump run were the diagonal-direction targets (~182-186 tile Manhattan
-- distance, ~45000-tile bounding box at the current MAX_SEARCH_MARGIN=60) -- this
-- failure class is NOT confirmed fixed by this change and remains OPEN. The heap's own
-- ~5x per-node speedup means a much larger cap is now cheap to try (measured: 32000
-- nodes costs only ~192ms, far below the RCON client's 60s socket timeout in
-- src/rcon_client.py) -- but raising it further needs its own real evidence (a
-- larger-sample or fixed-seed diagnostic run), not another guessed number. Left as the
-- concrete next step for task #43. MAX_SEARCH_MARGIN is intentionally NOT touched here
-- (it was raised previously for an unrelated geometric reason, routing room around real
-- obstacles like lakes, not a node-budget concern; nothing measured this session bears
-- on whether it separately needs to change).
--
-- RAISED 8000->16000 (2026-07-10, later same session, task #43 REAL-DATA follow-up): the
-- live diagnostic-delta approach above was explicitly flagged as inconclusive (a single
-- flipped sample, indistinguishable from map-to-map noise). Instead of another live
-- re-roll, this time captured the REAL per-tile is_blocked()/near_water() data (via direct
-- surf.count_entities_filtered/can_place_entity/find_tiles_filtered calls that mirror this
-- file's own logic exactly) for 5 GENUINELY failing (reason=="budget-exhausted") diagonal
-- routes across 2 independent fresh maps (~184-tile Manhattan distance, ~45369-tile
-- bounding box each -- exactly the failure class flagged above as open), then replayed
-- that EXACT captured obstacle geometry OFFLINE (no server) through this real source file
-- (scratchpad harness, MAX_NODES patched via a regex substitution that ASSERTS it actually
-- changed the byte content -- fixes the exact "silently no-ops once the file already
-- matches the target value" bug this project's own memory flagged in the sibling
-- explore_max_nodes.lua/explore_scaling.lua harnesses from earlier the same day) at
-- candidate caps {8000 [then-current], 16000, 32000, 64000} -- a true PAIRED comparison,
-- identical obstacle geometry every run, eliminating the map-to-map noise problem entirely.
-- Result: 0/5 scenarios succeeded at 8000 (matches each one's live "budget-exhausted"
-- origin, confirming the capture faithfully reproduces what the live search actually saw);
-- 5/5 succeeded at 16000, EVERY one finding the exact 185-tile path (184 Manhattan distance
-- + 1 for the start tile itself -- the true zero-detour optimum), with 32000 and 64000
-- finding the IDENTICAL 185-tile path in every scenario, i.e. 16000 is already the exact
-- sufficient cap for everything captured, and this evidence does not support going higher.
-- The optimal path being found comfortably inside the CURRENT MAX_SEARCH_MARGIN=60
-- bounding box also rules OUT the margin as this failure class's bottleneck -- it was
-- purely a node-budget shortfall. Measured real wall-clock cost (lua5.3 os.clock(), Python
-- time.time() around the live-capture RCON calls separately): 219-302ms per scenario at
-- cap=8000 (full exhaustion, all 5 failing cases) and 229-391ms at cap=16000/32000/64000
-- (successful, early-exits on reaching the goal) -- higher than the water-FREE synthetic
-- benchmark quoted above (~45-51ms at 8000) because these are REAL captured maps with real
-- lakes (up to 1918 water tiles each), so near_water's shore-penalty lookups add real cost
-- the synthetic case omitted entirely; still 2-3 orders of magnitude below the RCON
-- client's 60s socket timeout. Caveat, stated plainly rather than overclaimed: this is 5
-- real samples across 2 maps -- a genuine noise-free paired comparison for the EXACT
-- geometry captured, not a guarantee every possible diagonal/long route succeeds at
-- 16000 -- it is simply the smallest of the 4 prescribed candidate values that cleared
-- 100% of what was captured. See scripts/capture_pathfind_diagonal_scenarios.py (live
-- capture, factorio-ai repo) and this session's scratchpad's
-- sweep_max_nodes_real_scenarios.lua (offline replay+sweep) for the full methodology --
-- neither is committed to this repo (the harness lives in factorio-ai's scratchpad and the
-- capture script in the factorio-ai repo's scripts/, not factorio-ai-companion).
--
-- RAISED 16000->128000 (2026-07-10/11, task #43 CONTINUATION, LONG-THIN shape): a live run
-- (test_stage_b_wiring_postcoalanchor.log) hit belt_connect(54,2)->(-94,-14) failing "no
-- path"/"budget-exhausted" 3 separate times -- dx=-148, dy=-16 (~164 Manhattan), a long,
-- THIN bounding box (268x136=~36448 tiles at MAX_SEARCH_MARGIN=60) SMALLER by area than the
-- diagonal routes just confirmed above to succeed at 16000 (~45369 tiles each) -- i.e. a
-- genuinely DIFFERENT failure shape, not just "the same problem in a bigger box." Captured
-- REAL is_blocked()/near_water() data (factorio-ai's scripts/capture_pathfind_longthin_
-- scenarios.py, mirroring the diagonal capture script's method) for 8 GENUINELY failing
-- (reason=="budget-exhausted") long-thin routes (dx~148-150, dy~16-20, matching the real
-- failing route's ratio) across 3 INDEPENDENT fresh maps -- not just 2, since long-thin
-- failures turned out much RARER per-map than the diagonal case: only 3 of 11 distinct maps
-- tried produced ANY long-thin "budget-exhausted" result at all (the other 8 maps' 64
-- long-thin attempts all either pathfound successfully or only hit "Insufficient belt
-- items", i.e. pathfinding itself succeeded). Captured at CAPTURE_MARGIN=120 (double the
-- then-current MAX_SEARCH_MARGIN=60) specifically so the offline sweep could ALSO test
-- MAX_SEARCH_MARGIN independently of MAX_NODES against the exact same real geometry
-- (factorio-ai's scratchpad sweep_longthin_real_scenarios.lua), instrumented to additionally
-- surface, on every failure, the raw (expansions, #open-at-exit) the search already computes
-- internally but never returned before -- distinguishing NODE-CAP-BOUND (expansions==cap,
-- more budget could help) from MARGIN-BOUND (open list emptied before reaching cap, only a
-- wider box could help). Result: at margin=60 (current), swept cap in {16000 [then-current],
-- 32000, 64000, 128000} -- 0/8 scenarios succeed at 16000 (every one hits expansions==16000
-- exactly, matching each one's live "budget-exhausted" origin); 6/8 succeed at 32000; 7/8 at
-- 64000; 8/8 (ALL) succeed at 128000. EVERY failing row across all 8 scenarios showed
-- expansions==cap exactly (never open==0 before reaching cap) -- this shape's failures are
-- ENTIRELY node-cap-bound, NEVER margin-bound, in everything captured. Separately swept
-- MAX_SEARCH_MARGIN in {60, 90, 120} at each cap: the result (found/not-found, ms, and path
-- length when found) was IDENTICAL across all 3 margins for every single scenario/cap
-- combination -- margin measurably had ZERO effect on this shape's outcome. This directly
-- answers this task's own open question (a long-thin box's small vertical slack COULD in
-- principle force a wider detour) with real evidence: it does NOT, for any of the 8 real
-- routes captured -- MAX_SEARCH_MARGIN=60 is left unchanged. Real wall-clock cost (lua5.3
-- os.clock()): 212-253ms at cap=16000 (full exhaustion, all 8 failing, across all 8
-- scenarios x 3 margins), up to ~1249-1261ms for the single hardest scenario at
-- cap=128000 (still ~48x below the RCON client's 60s socket timeout) -- cost scales
-- roughly linearly with cap, no evidence of the heap's per-node cost exploding at this
-- larger size. Raised MAX_NODES to 128000, the smallest of
-- the 4 candidates that cleared 100% of what was captured (same selection rule as the 16000
-- decision above). Caveat, same discipline as above: this is 8 real samples across 3 maps
-- for the EXACT captured geometry, not a guarantee every possible long-thin route succeeds
-- at 128000 -- if a future live run still hits "budget-exhausted" on a route that is neither
-- this long-thin shape nor the earlier diagonal shape, the right next step is to capture
-- THAT case specifically, not guess a bigger number again. Live-verified end-to-end
-- afterward (factorio-ai's scripts/live_verify_longthin_fix.py, mirroring
-- live_verify_diagonal_fix.py's own pattern): reloaded the 3 actual captured maps
-- (AI-pfltcapture1/2/16.zip) with the fixed mod and re-issued the identical belt_connect
-- calls that previously returned "budget-exhausted" -- all 8/8 now return a found path
-- (checked via the same "reason ~= budget-exhausted" criterion the diagonal verify script
-- used; each call actually reported "Insufficient belt items" instead, confirming
-- pathfinding itself succeeded -- expected, this diagnostic never provisions belts). Real
-- live wall-clock cost: 512-2225ms per call (full engine + RCON round-trip, naturally
-- higher than the offline lua5.3-only measurements above) -- still far below the RCON
-- client's 60s socket timeout.

-- Shore buffer (2026-07-08, Zdendys: "go around water at a distance of at least 5-10 from the shore"):
-- a SOFT cost, not a hard block, added to any tile within SHORE_BUFFER of a water tile, so
-- the route PREFERS to stay clear of the coast when a choice exists (leaves room for the
-- power plant's own shore-adjacent structures, and avoids a corridor that hugs the water's
-- edge for its whole length) without making an unavoidable coast-hugging stretch impossible.
local SHORE_BUFFER = 8
local SHORE_PENALTY = 3

local function tile_key(x, y) return x .. ":" .. y end
-- State key for the SEARCH bookkeeping (visited/gscore/came_from) MUST include the arrival
-- direction, not just (x,y): edge cost depends on it via turn_penalty below, so two paths
-- reaching the same tile with equal g but different incoming direction are genuinely
-- different states -- collapsing them onto one (x,y) key lets whichever is expanded FIRST
-- permanently block a later, better-oriented arrival at the same g (or even lower cost
-- overall once its own better-turn continuation is considered), breaking A*'s optimality
-- (cubic dev ai bot, 2026-07-04: worked example with a wall forcing an extra turn).
-- (Corrected 2026-07-10, adversarial verify: path reconstruction below also uses
-- state_key via came_from, not tile_key -- this comment previously claimed otherwise;
-- tile_key is only ever used by the make_is_blocked/make_near_water caches above.)
local function state_key(x, y, dir) return x .. ":" .. y .. ":" .. tostring(dir) end

-- Per-run cache: the same neighbor tile is checked from multiple expanded nodes, and
-- surf.can_place_entity is a real engine call (not a cheap table lookup) -- memoizing
-- avoids redundant checks within one search.
local function make_is_blocked(surf, force)
  local cache = {}
  return function(x, y)
    local key = tile_key(x, y)
    local cached = cache[key]
    if cached ~= nil then return cached end
    local blocked
    if surf.count_entities_filtered{position = {x, y}, radius = 0.3, type = "resource"} > 0 then
      blocked = true
    else
      blocked = not surf.can_place_entity{
        name = "transport-belt", position = {x, y},
        direction = defines.direction.north, force = force
      }
    end
    cache[key] = blocked
    return blocked
  end
end

local DIRS = {
  {dx = 1, dy = 0, dir = defines.direction.east}, {dx = -1, dy = 0, dir = defines.direction.west},
  {dx = 0, dy = 1, dir = defines.direction.south}, {dx = 0, dy = -1, dir = defines.direction.north},
}

-- Memoized "is there water within SHORE_BUFFER tiles" check, same caching pattern as
-- make_is_blocked above (count_tiles_filtered is a real engine call). A single area query
-- per newly-discovered tile, not a hard block -- see SHORE_PENALTY comment above.
local function make_near_water(surf)
  local cache = {}
  return function(x, y)
    local key = tile_key(x, y)
    local cached = cache[key]
    if cached ~= nil then return cached end
    -- Same water-tile name set used elsewhere in this mod (e.g. demonstrator.py's own
    -- terrain surveys) -- shallow-water/mud variants are still unwalkable-for-belts water,
    -- not just "water"/"deepwater".
    local near = surf.count_tiles_filtered{
      area = {{x - SHORE_BUFFER, y - SHORE_BUFFER}, {x + SHORE_BUFFER, y + SHORE_BUFFER}},
      name = {"water", "deepwater", "water-shallow", "water-mud"}
    } > 0
    cache[key] = near
    return near
  end
end

-- Binary min-heap for the A* open list (2026-07-10, task #43 perf follow-up).
-- The OLD code popped the lowest-f node via a LINEAR SCAN over the entire `open`
-- array on every iteration -- with MAX_NODES=4000 and up to 4 pushes per
-- expansion, `open` can grow into the thousands, making every pop O(|open|) and
-- the whole search roughly O(n^2) instead of the O(n log n) a proper priority
-- queue gives. Lua has no built-in decrease-key heap, so this uses the standard
-- "lazy deletion" pattern: a state can be pushed multiple times (once per
-- successful relaxation -- the OLD linear-scan code already relied on this too,
-- since it never removed a stale `open` entry on relaxation either, only ever
-- appended a fresh one), and the existing `visited[state_key]` check (unchanged,
-- right after `heap_pop` at the call site below) discards a stale duplicate the
-- first time it's popped after its state has already been expanded via a
-- fresher, cheaper entry. This is safe BECAUSE edge costs are non-negative: each
-- successive relaxation of the same state produces a STRICTLY smaller g (the
-- `ng < gscore[nk]` guard below enforces this), and since h() depends only on
-- position (not on which relaxation produced the entry), a strictly smaller g
-- means a strictly smaller f too -- so the freshest (cheapest) entry for any
-- given state ALWAYS has the smallest f among all of that state's own entries,
-- and is therefore ALWAYS popped before any of its own staler duplicates,
-- regardless of push order. This is the exact same property the old linear scan
-- already depended on (it too just picked the global-minimum f/g node each
-- iteration, oblivious to which entries were "stale") -- a pure performance
-- change, not a new correctness assumption.
--
-- Comparator: lowest f first; among equal f, prefer LARGER g (2026-07-05
-- tie-break, see the historical comment preserved at the call site below --
-- unchanged, still biases the search to march toward the goal instead of
-- fanning out on a plateau); among equal f AND equal g (a real tie between two
-- distinct nodes), prefer whichever was pushed FIRST (`seq`, a monotonically
-- increasing push counter) -- this exactly reproduces the old linear scan's own
-- de-facto tie-break (it iterated `open` in insertion order and only overwrote
-- its running-best on a STRICT `<`, so among full ties the earliest-inserted
-- entry always won), so the heap's pop order is IDENTICAL to the old scan's pop
-- order at every single step, not just "equally optimal" -- same algorithm
-- trace, same expansions count, same final path, for any given input.
local function heap_less(a, b)
  if a.f ~= b.f then return a.f < b.f end
  if a.g ~= b.g then return a.g > b.g end
  return a.seq < b.seq
end

local function heap_push(heap, node)
  heap[#heap + 1] = node
  local i = #heap
  while i > 1 do
    local parent = math.floor(i / 2)
    if heap_less(heap[i], heap[parent]) then
      heap[i], heap[parent] = heap[parent], heap[i]
      i = parent
    else
      break
    end
  end
end

-- Pops and returns the minimum element (per heap_less above). Caller must only
-- call this on a non-empty heap (the while loop at the call site below already
-- guards on `#open > 0` before calling, matching the old code's own guard).
local function heap_pop(heap)
  local n = #heap
  local top = heap[1]
  heap[1] = heap[n]
  heap[n] = nil
  n = n - 1
  local i = 1
  while true do
    local left, right = i * 2, i * 2 + 1
    local smallest = i
    if left <= n and heap_less(heap[left], heap[smallest]) then smallest = left end
    if right <= n and heap_less(heap[right], heap[smallest]) then smallest = right end
    if smallest == i then break end
    heap[i], heap[smallest] = heap[smallest], heap[i]
    i = smallest
  end
  return top
end

-- 4-directional A* (belts are axis-aligned). Returns an ordered list of
-- {x, y, dir} (dir = the direction of travel INTO that tile, nil for the start tile),
-- or nil if no route was found within the search budget. On nil, a second string
-- return value distinguishes WHY (2026-07-10, task #43 diagnostic follow-up):
-- "start-blocked" / "dest-blocked" / "budget-exhausted" -- callers that only capture
-- one return value (`local path = pathfind.find_path(...)`) are unaffected, per Lua's
-- own multi-return semantics (extra return values are simply discarded).
function M.find_path(surf, from, to, force)
  local fx, fy = math.floor(from.x), math.floor(from.y)
  local tx, ty = math.floor(to.x), math.floor(to.y)
  local minx = math.min(fx, tx) - MAX_SEARCH_MARGIN
  local maxx = math.max(fx, tx) + MAX_SEARCH_MARGIN
  local miny = math.min(fy, ty) - MAX_SEARCH_MARGIN
  local maxy = math.max(fy, ty) + MAX_SEARCH_MARGIN
  local is_blocked = make_is_blocked(surf, force)
  local near_water = make_near_water(surf)
  -- The start tile is seeded directly into `open` (never evaluated as a "neighbor"),
  -- so it needs its own explicit check for the same reason the destination tile does.
  if is_blocked(fx, fy) then return nil, "start-blocked" end
  -- Destination-blocked check (2026-07-10, task #43 diagnostic follow-up): without this,
  -- a destination sitting on water/a resource/anything is_blocked rejects can NEVER be
  -- added to `open` (it's only ever validated as a side effect of neighbor-expansion
  -- below), so the search silently exhausts the whole budget before returning nil --
  -- indistinguishable from a genuine "too far/obstacle-heavy" failure. Checking it here
  -- fails fast AND tags the result with a distinguishable reason. `is_blocked` is a
  -- memoized per-call closure (see make_is_blocked above), so this extra call just
  -- seeds the (tx,ty) cache entry early -- no different from it being queried later
  -- during normal expansion, no stale-cache risk.
  if is_blocked(tx, ty) then return nil, "dest-blocked" end

  local function h(x, y) return math.abs(tx - x) + math.abs(ty - y) end

  local open = {}
  local seq = 0                           -- monotonic push counter, see heap_less above
  seq = seq + 1
  heap_push(open, {x = fx, y = fy, dir = nil, g = 0, f = h(fx, fy), seq = seq})
  local came_from = {}                    -- state_key -> predecessor node
  local gscore = {[state_key(fx, fy, nil)] = 0}
  local visited = {}
  local expansions = 0

  while #open > 0 and expansions < MAX_NODES do
    -- Pop lowest-f via the binary min-heap above (O(log n), see heap_pop/heap_less
    -- for the full mechanism + why its pop order is provably identical to the OLD
    -- linear-scan's pop order at every step). Tie-break toward the LARGER g
    -- (2026-07-05, Zdendys live-caught: a 134-tile route reported "no path" despite
    -- there being no water/cliffs in the way -- root cause: with a Manhattan
    -- heuristic and 4-directional movement, every tile inside the from/to bounding
    -- rectangle has the SAME f = g+h (the whole rectangle is one tied plateau), and
    -- the old tie-break ("keep whichever equal-f node was found first") made the
    -- search fan out breadth-first across nearly the ENTIRE rectangle before ever
    -- reaching the goal corner -- for a 121x58 box that's ~7000 tiles against a
    -- 2500-node cap, guaranteeing a false "no path" on a fully open field. Preferring
    -- the larger-g (equivalently smaller-h, i.e. closer to the goal) node among ties
    -- biases expansion to march toward the target instead of radiating outward evenly,
    -- without changing A*'s optimality guarantee at all (ties by definition share the
    -- same f, so picking a different one among them cannot produce a worse-than-optimal
    -- final path -- see the state_key/goal-test comments below, unaffected by this).
    local cur = heap_pop(open)
    local ck = state_key(cur.x, cur.y, cur.dir)
    if not visited[ck] then
      visited[ck] = true
      expansions = expansions + 1
      if cur.x == tx and cur.y == ty then
        -- Any (goal-tile, *) state popped here is guaranteed minimum-cost for the goal
        -- POSITION (not just for this particular direction): h() doesn't depend on dir, so
        -- among all direction-variants of the goal tile the lowest-g one always has the
        -- lowest f and is popped first (edge costs are non-negative, so g only grows along
        -- a path) -- position-only goal test is correct even though the state space isn't.
        local path, node = {}, cur
        while node do
          table.insert(path, 1, {x = node.x, y = node.y, dir = node.dir})
          node = came_from[state_key(node.x, node.y, node.dir)]
        end
        return path
      end
      for _, d in ipairs(DIRS) do
        local nx, ny = cur.x + d.dx, cur.y + d.dy
        if nx >= minx and nx <= maxx and ny >= miny and ny <= maxy then
          -- No endpoint exemption: the destination tile must be a genuinely valid belt
          -- spot too (not ore/water/occupied), same as every other tile on the route --
          -- otherwise a caller-requested endpoint sitting on a resource tile would let
          -- the corridor terminate ON ore, contradicting the avoid-resource-tiles rule.
          if not is_blocked(nx, ny) then
            local turn_penalty = (cur.dir and cur.dir ~= d.dir) and 0.5 or 0
            local shore_penalty = near_water(nx, ny) and SHORE_PENALTY or 0
            local ng = cur.g + 1 + turn_penalty + shore_penalty
            local nk = state_key(nx, ny, d.dir)
            if ng < (gscore[nk] or math.huge) then
              gscore[nk] = ng
              came_from[nk] = cur
              seq = seq + 1
              heap_push(open, {x = nx, y = ny, dir = d.dir, g = ng, f = ng + h(nx, ny), seq = seq})
            end
          end
        end
      end
    end
  end
  return nil, "budget-exhausted"   -- no path found within the search budget
end

return M
