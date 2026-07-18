import { z } from "zod";

export const SendMessageSchema = z.object({
  message: z.string(),
});

// Single source of truth for all MCP tools
// Format: toolName -> { desc, rcon (template), params }
export const TOOLS: Record<string, {
  desc: string;
  rcon: string;  // Template with {param} placeholders
  params: Record<string, { type: "number" | "string"; desc?: string; required?: boolean; default?: any }>;
}> = {
  // Chat
  chat_get: {
    desc: "Get unread messages from Factorio chat",
    rcon: "/fac_chat_get {companionId}",
    params: { companionId: { type: "number", desc: "Optional: filter by companion ID" } }
  },
  chat_say: {
    desc: "Send a message to Factorio chat as a companion",
    rcon: "/fac_chat_say {companionId} {message}",
    params: {
      companionId: { type: "number", desc: "Companion ID (0 for orchestrator)", required: true },
      message: { type: "string", desc: "Message to send", required: true }
    }
  },

  // Companion
  companion_list: {
    desc: "List ALL companions with positions and health",
    rcon: "/fac_companion_list",
    params: {}
  },
  companion_spawn: {
    desc: "Spawn a new companion character",
    rcon: "/fac_companion_spawn id={companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  companion_position: {
    desc: "Get companion position and nearby entities",
    rcon: "/fac_companion_position {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  companion_inventory: {
    desc: "Get companion inventory contents",
    rcon: "/fac_companion_inventory {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  companion_health: {
    desc: "Get companion health status",
    rcon: "/fac_companion_health {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  companion_disappear: {
    desc: "Despawn a companion (drops items)",
    rcon: "/fac_companion_disappear {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  companion_stop_all: {
    desc: "Stop all queues for a companion (harvest, craft, build, combat, walk)",
    rcon: "/fac_companion_stop_all {companionId}",
    params: { companionId: { type: "number", required: true } }
  },

  // Movement
  move_to: {
    desc: "Move companion to specific coordinates",
    rcon: "/fac_move_to {companionId} {x} {y}",
    params: {
      companionId: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true }
    }
  },
  move_follow: {
    desc: "Make companion follow a player",
    rcon: "/fac_move_follow {companionId} {playerName}",
    params: {
      companionId: { type: "number", required: true },
      playerName: { type: "string", desc: "Player name to follow", required: true }
    }
  },
  move_stop: {
    desc: "Stop companion movement",
    rcon: "/fac_move_stop {companionId}",
    params: { companionId: { type: "number", required: true } }
  },

  // Resources
  resource_nearest: {
    desc: "Find nearest resource of a type",
    rcon: "/fac_resource_nearest {companionId} {resourceType}",
    params: {
      companionId: { type: "number", required: true },
      resourceType: { type: "string", desc: "Resource: iron-ore, copper-ore, coal, stone", required: true }
    }
  },
  resource_list: {
    desc: "List nearby resources around companion",
    rcon: "/fac_resource_list {companionId} {filter} {radius}",
    params: {
      companionId: { type: "number", required: true },
      filter: { type: "string", desc: "Optional: filter by resource type", default: "" },
      radius: { type: "number", desc: "Search radius", default: 50 }
    }
  },
  resource_mine: {
    desc: "Start mining at coordinates (companion must be within 5 tiles)",
    rcon: "/fac_resource_mine {companionId} {x} {y} {count} {resourceName}",
    params: {
      companionId: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true },
      count: { type: "number", desc: "Number to mine", default: 1 },
      resourceName: { type: "string", desc: "Optional: specific resource", default: "" }
    }
  },
  resource_mine_status: {
    desc: "Check mining queue status",
    rcon: "/fac_resource_mine_status {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  resource_mine_stop: {
    desc: "Stop mining queue (v0.11.0+: uses hybrid native mining)",
    rcon: "/fac_resource_mine_stop {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  // NOTE: mine_real_* removed in v0.11.0 - resource_mine now uses hybrid native mining

  // Items
  item_pick: {
    desc: "Pick up items from ground near companion",
    rcon: "/fac_item_pick {companionId} {itemName} {radius}",
    params: {
      companionId: { type: "number", required: true },
      itemName: { type: "string", required: true },
      radius: { type: "number", default: 10 }
    }
  },
  item_craft: {
    desc: "Craft an item (instant)",
    rcon: "/fac_item_craft {companionId} {recipe} {count}",
    params: {
      companionId: { type: "number", required: true },
      recipe: { type: "string", required: true },
      count: { type: "number", default: 1 }
    }
  },
  item_craft_start: {
    desc: "Start crafting (async, tick-based)",
    rcon: "/fac_item_craft_start {companionId} {recipe} {count}",
    params: {
      companionId: { type: "number", required: true },
      recipe: { type: "string", required: true },
      count: { type: "number", default: 1 }
    }
  },
  item_craft_status: {
    desc: "Check crafting status",
    rcon: "/fac_item_craft_status {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  item_craft_stop: {
    desc: "Stop crafting",
    rcon: "/fac_item_craft_stop {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  item_recipes: {
    desc: "List available recipes for companion",
    rcon: "/fac_item_recipes {companionId}",
    params: { companionId: { type: "number", required: true } }
  },

  // World
  world_scan: {
    desc: "Scan for entities around companion",
    rcon: "/fac_world_scan {companionId} {radius} {entityType}",
    params: {
      companionId: { type: "number", required: true },
      radius: { type: "number", default: 50 },
      entityType: { type: "string", default: "" }
    }
  },
  world_nearest: {
    desc: "Find nearest entity of a type",
    rcon: "/fac_world_nearest {companionId} {entityName}",
    params: {
      companionId: { type: "number", required: true },
      entityName: { type: "string", required: true }
    }
  },
  world_enemies: {
    desc: "Find enemies around companion",
    rcon: "/fac_world_enemies {companionId} {radius}",
    params: {
      companionId: { type: "number", required: true },
      radius: { type: "number", default: 50 }
    }
  },

  // Building
  building_place: {
    desc: "Place a building/entity at coordinates (instant)",
    rcon: "/fac_building_place {companionId} {entityName} {x} {y} {direction}",
    params: {
      companionId: { type: "number", required: true },
      entityName: { type: "string", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true },
      direction: { type: "number", desc: "Direction 0-7", default: 0 }
    }
  },
  building_place_start: {
    desc: "Start placing a building (async, tick-based)",
    rcon: "/fac_building_place_start {companionId} {entityName} {x} {y} {direction}",
    params: {
      companionId: { type: "number", required: true },
      entityName: { type: "string", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true },
      direction: { type: "number", default: 0 }
    }
  },
  building_place_status: {
    desc: "Check building placement status",
    rcon: "/fac_building_place_status {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  building_remove: {
    desc: "Remove a building at coordinates",
    rcon: "/fac_building_remove {companionId} {x} {y}",
    params: {
      companionId: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true }
    }
  },
  building_mine: {
    desc: "Mine (destroy) any entity at coordinates - works on crash site wrecks, decoratives",
    rcon: "/fac_mine_entity {companionId} {x} {y}",
    params: {
      companionId: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true }
    }
  },
  building_can_place: {
    desc: "Check if entity can be placed at coordinates",
    rcon: "/fac_building_can_place {companionId} {entityName} {x} {y}",
    params: {
      companionId: { type: "number", required: true },
      entityName: { type: "string", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true }
    }
  },
  building_info: {
    desc: "Get building info at coordinates",
    rcon: "/fac_building_info {companionId} {x} {y}",
    params: {
      companionId: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true }
    }
  },
  building_rotate: {
    desc: "Rotate a building at coordinates",
    rcon: "/fac_building_rotate {companionId} {x} {y}",
    params: {
      companionId: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true }
    }
  },
  building_recipe: {
    desc: "Get/set recipe for assembling machine",
    rcon: "/fac_building_recipe {companionId} {x} {y} {recipe}",
    params: {
      companionId: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true },
      recipe: { type: "string", default: "" }
    }
  },
  building_fuel: {
    desc: "Add fuel to nearby entity (burner, furnace, etc) - companion must be within 3 tiles",
    rcon: "/fac_building_fuel {companionId} {fuelName} {count}",
    params: {
      companionId: { type: "number", required: true },
      fuelName: { type: "string", required: true },
      count: { type: "number", required: true }
    }
  },
  building_empty: {
    desc: "Extract items from nearby entity into companion inventory (radius 5)",
    rcon: "/fac_building_empty {companionId} {itemName} {count} {x} {y}",
    params: {
      companionId: { type: "number", required: true },
      itemName: { type: "string", required: true },
      count: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true }
    }
  },
  building_fill: {
    desc: "Fill nearby entity with items from companion inventory (radius 3)",
    rcon: "/fac_building_fill {companionId} {itemName} {count} {x} {y}",
    params: {
      companionId: { type: "number", required: true },
      itemName: { type: "string", required: true },
      count: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true }
    }
  },

  // Action/Combat
  action_attack: {
    desc: "Attack an entity at coordinates (instant)",
    rcon: "/fac_action_attack {companionId} {x} {y}",
    params: {
      companionId: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true }
    }
  },
  action_attack_start: {
    desc: "Start attacking (async, tick-based combat)",
    rcon: "/fac_action_attack_start {companionId} {x} {y}",
    params: {
      companionId: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true }
    }
  },
  action_attack_status: {
    desc: "Check attack status",
    rcon: "/fac_action_attack_status {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  action_attack_stop: {
    desc: "Stop attacking",
    rcon: "/fac_action_attack_stop {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  action_defend: {
    desc: "Defend current position (attack nearby enemies)",
    rcon: "/fac_action_defend {companionId} {radius}",
    params: {
      companionId: { type: "number", required: true },
      radius: { type: "number", default: 20 }
    }
  },
  action_flee: {
    desc: "Flee from danger",
    rcon: "/fac_action_flee {companionId} {x} {y} {distance}",
    params: {
      companionId: { type: "number", required: true },
      x: { type: "number", required: true },
      y: { type: "number", required: true },
      distance: { type: "number", required: true }
    }
  },
  action_patrol: {
    desc: "Patrol between points",
    rcon: "/fac_action_patrol {companionId} {points}",
    params: {
      companionId: { type: "number", required: true },
      points: { type: "string", desc: "JSON array of {x,y} points", required: true }
    }
  },
  action_wololo: {
    desc: "Play wololo sound",
    rcon: "/fac_action_wololo {companionId}",
    params: { companionId: { type: "number", required: true } }
  },

  // Research
  research_get: {
    desc: "Get current research status",
    rcon: "/fac_research_get {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  research_set: {
    desc: "Set research target",
    rcon: "/fac_research_set {companionId} {technology}",
    params: {
      companionId: { type: "number", required: true },
      technology: { type: "string", required: true }
    }
  },
  research_progress: {
    desc: "Get research progress",
    rcon: "/fac_research_progress {companionId}",
    params: { companionId: { type: "number", required: true } }
  },

  // Context
  context_clear: {
    desc: "Clear companion context (for thread management)",
    rcon: "/fac_context_clear {companionId}",
    params: { companionId: { type: "number", required: true } }
  },
  context_check: {
    desc: "Check pending context clear requests",
    rcon: "/fac_context_check",
    params: {}
  },

  // Meta
  version: {
    desc: "Get mod version",
    rcon: "/fac_version",
    params: {}
  },
  help: {
    desc: "Get help and list of commands",
    rcon: "/fac_help {category}",
    params: {
      category: { type: "string", desc: "Optional: category to filter (action, building, etc)", default: "" }
    }
  },
};

// High-level skills (run as background processes, not direct RCON)
export const SKILLS: Record<string, {
  desc: string;
  script: string;  // Script path relative to src/
  params: Record<string, { type: "number" | "string"; desc?: string; required?: boolean; default?: any }>;
}> = {
  resource_mine_until: {
    desc: "HIGH-LEVEL: Autonomously mine resource until target amount. Handles walking, mining, repeat. Runs in background.",
    script: "skills/mine-until.ts",
    params: {
      companionId: { type: "number", required: true },
      resource: { type: "string", desc: "Resource: iron, copper, coal, stone, uranium", required: true },
      amount: { type: "number", desc: "Target amount", default: 50 }
    }
  },
  combat_until: {
    desc: "HIGH-LEVEL: Autonomously hunt and kill enemies. Handles scanning, walking, attacking. Runs in background.",
    script: "skills/combat-until.ts",
    params: {
      companionId: { type: "number", required: true },
      targetType: { type: "string", desc: "Target: all, spawner, worm, biter, spitter", default: "all" },
      maxKills: { type: "number", desc: "Max kills before stopping", default: 10 }
    }
  },
};

// Special tools that need TS-side handling (not just RCON passthrough)
const SPECIAL_TOOLS = [
  {
    name: "session_status",
    description: "Get current session state and instructions. Call this FIRST to understand what's running and how to start the reactive loop.",
    inputSchema: {
      type: "object" as const,
      properties: {},
      required: []
    }
  },
  {
    name: "companion_status",
    description: "Get status of ONE companion including running skill (combines Lua position + TS skill tracking).",
    inputSchema: {
      type: "object" as const,
      properties: {
        companionId: { type: "number", description: "Companion ID to check" }
      },
      required: ["companionId"]
    }
  },
  {
    name: "companion_stop",
    description: "Stop a running skill for ONE companion (kills the background process).",
    inputSchema: {
      type: "object" as const,
      properties: {
        companionId: { type: "number", description: "Companion whose skill to stop" }
      },
      required: ["companionId"]
    }
  }
];

// Generate skill schemas (includes SKILLS + skill management tools)
export function generateSkillSchemas() {
  const skillSchemas = Object.entries(SKILLS).map(([name, skill]) => ({
    name,
    description: skill.desc,
    inputSchema: {
      type: "object" as const,
      properties: Object.fromEntries(
        Object.entries(skill.params).map(([pName, p]) => [
          pName,
          { type: p.type, description: p.desc }
        ])
      ),
      required: Object.entries(skill.params)
        .filter(([_, p]) => p.required)
        .map(([name]) => name)
    }
  }));

  return [...skillSchemas, ...SPECIAL_TOOLS];
}

// Generate MCP tool schemas from TOOLS
export function generateToolSchemas() {
  return Object.entries(TOOLS).map(([name, tool]) => ({
    name,
    description: tool.desc,
    inputSchema: {
      type: "object" as const,
      properties: Object.fromEntries(
        Object.entries(tool.params).map(([pName, p]) => [
          pName,
          { type: p.type, description: p.desc }
        ])
      ),
      required: Object.entries(tool.params)
        .filter(([_, p]) => p.required)
        .map(([name]) => name)
    }
  }));
}

// Build RCON command from template and args
export function buildRCONCommand(toolName: string, args: Record<string, any>): string {
  const tool = TOOLS[toolName];
  if (!tool) return ""; // Return empty for unknown tools (handled separately)

  let cmd = tool.rcon;

  // Replace placeholders with args or defaults
  for (const [param, config] of Object.entries(tool.params)) {
    const value = args[param] ?? config.default ?? "";
    cmd = cmd.replace(`{${param}}`, String(value));
  }

  // Clean up extra spaces
  return cmd.replace(/\s+/g, " ").trim();
}
