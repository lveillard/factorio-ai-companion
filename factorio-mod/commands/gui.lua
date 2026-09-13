local u = require("commands.init")
local input = require("commands.player_input")
local contract = require("commands.contract")
local cfg = u.settings.overlay
local M = {}
local BAR, PANEL = "fac_chat_bar", "fac_companion_panel"

local function preferences(player)
  storage.overlay = storage.overlay or {}
  storage.overlay[player.index] = storage.overlay[player.index] or {}
  return storage.overlay[player.index]
end

local function companions(player)
  local result = {}
  for id, c in pairs(storage.companions or {}) do
    if c.entity and c.entity.valid and c.entity.force == player.force then
      result[#result+1] = {id=id,name=c.name or ("#" .. id),entity=c.entity}
    end
  end
  table.sort(result, function(a,b) return a.id < b.id end)
  return result
end

local function target(bar)
  local select = bar.header.target
  return select.tags.ids[select.selected_index] or 0
end

local function place(player, frame)
  local scale, resolution = player.display_scale, player.display_resolution
  local compact = resolution.width/scale < cfg.compact_below_width
  local saved = preferences(player).location
  local x = saved and saved.x or (compact and cfg.compact_left or cfg.left)*scale
  local y = saved and saved.y or resolution.height-(cfg.height+(compact and cfg.compact_bottom or cfg.bottom))*scale
  frame.location = {x=math.floor(math.max(0,math.min(x,resolution.width-cfg.width*scale))),
    y=math.floor(math.max(0,math.min(y,resolution.height-cfg.height*scale)))}
end

local function button(parent, name, caption, tags, tooltip)
  return parent.add{type="button",name=name,caption=caption,tags=tags or {},tooltip=tooltip}
end

function M.ensure(player)
  local bar = player.gui.screen[BAR]
  if bar then return bar end
  bar = player.gui.screen.add{type="frame",name=BAR,direction="vertical"}
  bar.style.width = cfg.width
  local header = bar.add{type="flow",name="header",direction="horizontal"}
  local handle = header.add{type="label",caption="To",tooltip="Drag to move chat"}
  handle.drag_target = bar
  local select = header.add{type="drop-down",name="target",items={"Codex"},selected_index=1,tags={ids={0}}}
  select.style.width = 160
  button(header,"fac_manage","Companions")
  local body = bar.add{type="flow",name="body",direction="horizontal"}
  local text = body.add{type="text-box",name="fac_message",text=preferences(player).draft or ""}
  text.word_wrap = true
  text.style.width = cfg.width-100
  text.style.height = 52
  button(body,"fac_send","Send")
  local status = bar.add{type="label",name="status",caption="Waiting for connection"}
  status.style.font = "default-small"
  place(player,bar)
  return bar
end

local function activity(id)
  for _, name in ipairs(u.settings.queues) do
    if storage[name .. "_queues"] and storage[name .. "_queues"][id] then
      local q = storage[name .. "_queues"][id]
      local detail = q.resource or q.recipe
      return name .. (detail and (" · " .. detail) or "")
    end
  end
  if storage.active_step and storage.active_step[id] then return storage.active_step[id].state end
  return "Idle"
end

function M.refresh(player)
  local bar = M.ensure(player)
  local list = companions(player)
  local ids, names, signature = {0}, {"Codex"}, {}
  for _, c in ipairs(list) do
    ids[#ids+1], names[#names+1] = c.id, c.name .. " #" .. c.id
    signature[#signature+1] = c.id .. ":" .. c.name
  end
  signature = table.concat(signature,"|")
  local selected = preferences(player).target or target(bar)
  if bar.header.target.tags.signature ~= signature then
    bar.header.target.items = names
    bar.header.target.tags = {ids=ids,signature=signature}
    bar.header.target.selected_index = 1
    for i,id in ipairs(ids) do if id == selected then bar.header.target.selected_index = i end end
    preferences(player).target = target(bar)
  end
  local connected = storage.bridge_last_poll_tick and game.tick-storage.bridge_last_poll_tick <= cfg.connection_timeout_ticks
  bar.status.caption = connected and "Connected" or "Waiting for connection"
  local panel = player.gui.screen[PANEL]
  if not panel then return end
  if panel.roster.tags.signature ~= signature then
    panel.roster.clear()
    panel.roster.tags = {signature=signature}
    if #list == 0 then panel.roster.add{type="label",caption="No companions"} end
    for _, c in ipairs(list) do
      local row = panel.roster.add{type="flow",name="companion_" .. c.id,direction="horizontal"}
      local label = row.add{type="label",caption=c.name .. " #" .. c.id}
      label.style.width = 150
      local state = row.add{type="label",name="state"}
      state.style.width = 150
      for i, action in ipairs(cfg.actions) do
        button(row,"action_" .. i,action.caption,{fac_action=i,cid=c.id},action.tooltip)
      end
    end
  end
  for _, c in ipairs(list) do panel.roster["companion_" .. c.id].state.caption = activity(c.id) end
end

function M.open(player)
  local existing = player.gui.screen[PANEL]
  if existing then existing.bring_to_front();player.opened=existing;return end
  local panel = player.gui.screen.add{type="frame",name=PANEL,direction="vertical",caption="Companions"}
  local create = panel.add{type="flow",name="create",direction="horizontal"}
  create.add{type="textfield",name="fac_name",text="",tooltip="Companion name (optional)"}
  button(create,"fac_spawn","Spawn")
  local roster = panel.add{type="scroll-pane",name="roster",horizontal_scroll_policy="never"}
  roster.style.maximal_height = 340
  panel.add{type="label",name="error",caption=""}
  local footer = panel.add{type="flow",name="footer",direction="horizontal"}
  button(footer,"fac_reset_position","Reset chat position")
  button(footer,"fac_close","Close")
  panel.auto_center = true
  player.opened = panel
  M.refresh(player)
end

function M.send(player)
  local bar = M.ensure(player)
  local message, err = input.send(player,bar.body.fac_message.text,target(bar))
  if not message then bar.status.caption=err;return end
  bar.body.fac_message.text = ""
  preferences(player).draft = ""
  bar.body.fac_send.focus()
  bar.status.caption = "Sent"
end

local function spawn(player)
  local panel = player.gui.screen[PANEL]
  local id, maximum = 1, contract.companion_spawn.inputSchema.properties.companionId.maximum
  while storage.companions[id] and id <= maximum do id=id+1 end
  local name = panel.create.fac_name.text:match("^%s*(.-)%s*$")
  local result = input.control(player,"companion_spawn",{companionId=id,name=name~="" and name or nil})
  panel.error.caption = result.error or ""
  if not result.error then panel.create.fac_name.text="" end
  M.refresh(player)
end

function M.click(event)
  local e = event.element
  if not e or not e.valid then return end
  local owner = e
  while owner and owner.name ~= BAR and owner.name ~= PANEL do owner=owner.parent end
  if not owner then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  if e.name == "fac_send" then M.send(player)
  elseif e.name == "fac_manage" then M.open(player)
  elseif e.name == "fac_close" then player.gui.screen[PANEL].destroy()
  elseif e.name == "fac_spawn" then spawn(player)
  elseif e.name == "fac_reset_position" then preferences(player).location=nil;place(player,M.ensure(player))
  elseif e.tags.fac_action then
    local action, cid = cfg.actions[e.tags.fac_action], e.tags.cid
    local c = u.get_companion(cid)
    if not action or not c or c.entity.force ~= player.force then return end
    local args = {companionId=cid}
    if action.player_argument then args[action.player_argument]=player.name end
    local result = input.control(player,action.tool,args)
    local panel = player.gui.screen[PANEL]
    if panel then panel.error.caption=result.error or "" end
    M.refresh(player)
  end
end

function M.rebuild()
  for _, player in pairs(game.players) do
    local bar = player.gui.screen[BAR]
    if bar then
      preferences(player).draft=bar.body.fac_message.text
      preferences(player).target=target(bar)
      bar.destroy()
    end
    if player.gui.screen[PANEL] then player.gui.screen[PANEL].destroy() end
    M.refresh(player)
  end
end

function M.tick()
  for _, player in pairs(game.connected_players) do M.refresh(player) end
end

script.on_event(defines.events.on_gui_click,M.click)
script.on_event(defines.events.on_gui_confirmed,function(event)
  if event.element.name == "fac_name" then spawn(game.get_player(event.player_index)) end
end)
script.on_event(defines.events.on_gui_closed,function(event)
  if event.element and event.element.valid and event.element.name == PANEL then event.element.destroy() end
end)
script.on_event(defines.events.on_gui_text_changed,function(event)
  if event.element.name == "fac_message" then preferences(game.get_player(event.player_index)).draft=event.element.text end
end)
script.on_event(defines.events.on_gui_selection_state_changed,function(event)
  if event.element.name == "target" and event.element.parent and event.element.parent.parent
      and event.element.parent.parent.name == BAR then
    preferences(game.get_player(event.player_index)).target=target(event.element.parent.parent)
  end
end)
script.on_event(defines.events.on_gui_location_changed,function(event)
  if event.element.name == BAR then preferences(game.get_player(event.player_index)).location=event.element.location end
end)
script.on_event({defines.events.on_player_created,defines.events.on_player_joined_game},function(event)
  M.refresh(game.get_player(event.player_index))
end)
script.on_event({defines.events.on_player_display_resolution_changed,defines.events.on_player_display_scale_changed},function(event)
  local player=game.get_player(event.player_index)
  place(player,M.ensure(player))
end)

return M
