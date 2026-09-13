local handlers={}
defines.events={on_gui_click=2,on_gui_confirmed=3,on_gui_closed=4,on_gui_text_changed=5,
  on_gui_location_changed=6,on_player_created=7,on_player_joined_game=8,
  on_player_display_resolution_changed=9,on_player_display_scale_changed=10,on_gui_selection_state_changed=11}
script={on_event=function(id,fn)
  if type(id)=="table" then for _,key in pairs(id) do handlers[key]=fn end else handlers[id]=fn end
end}
commands={add_command=function() end}
helpers={table_to_json=function() error("GUI must not serialize RCON output") end}
rcon={print=function() error("GUI must not write to RCON") end}
local function element(args,parent)
  local e={valid=true,name=args.name or "",type=args.type,parent=parent,children={},style={},tags=args.tags or {},
    caption=args.caption,text=args.text or "",items=args.items,selected_index=args.selected_index}
  e.add=function(a)
    local c=element(a,e);e.children[#e.children+1]=c
    if a.name then assert(not e[a.name],"Duplicate GUI child");e[a.name]=c end
    return c
  end
  e.destroy=function() e.valid=false;if parent and e.name~="" then parent[e.name]=nil end end
  e.clear=function() for _,c in ipairs(e.children) do c.destroy() end;e.children={} end
  e.focus=function() end;e.bring_to_front=function() end
  return e
end
player={index=1,name="Player",force=entity.force,display_resolution={width=1920,height=1080},display_scale=1,
  gui={screen=element{type="screen"}}}
game.get_player=function() return player end
game.players={player};game.connected_players={player}
storage.companion_messages={}
local gui=require("commands.gui")
local function click(e) gui.click{element=e,player_index=1} end
local function bar() return player.gui.screen.fac_chat_bar end
local function panel() return player.gui.screen.fac_companion_panel end
