local M = {}

local MAX_SEARCH_MARGIN = 60     -- tiles of slack around the from/to bounding box (2026-07-08,
local MAX_NODES = 128000         -- hard cap on A* expansions (bounded, no infinite loop) -- raised

local SHORE_BUFFER = 8
local SHORE_PENALTY = 3

local function tile_key(x, y) return x .. ":" .. y end
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
