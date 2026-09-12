import config from "../../config/agent.json";
import type { WorldSnapshot } from "./game";

type Position = { x: number; y: number };
type Entity = { name: string; type: string; force?: string; position: Position; amount?: number };

/** Compact only the automatic turn context; the dashboard and world_observe keep full detail. */
export function agentObservation(snapshot: WorldSnapshot | null) {
  if (!snapshot) return null;
  const { entities, water, ...rest } = snapshot;
  const groups = new Map<
    string,
    {
      name: string;
      type: string;
      force?: string;
      sampled_entities: number;
      sampled_amount?: number;
      nearest_positions: Position[];
    }
  >();
  const detailed: unknown[] = [];
  const distance = (p: Position) => Math.hypot(p.x - snapshot.center.x, p.y - snapshot.center.y);
  for (const raw of Array.isArray(entities) ? entities : []) {
    const entity = raw as Entity;
    if (!config.observation.groupEntityTypes.includes(entity.type) || entity.force === "enemy") {
      detailed.push(raw);
      continue;
    }
    const key = JSON.stringify([entity.type, entity.name, entity.force]);
    let group = groups.get(key);
    if (!group) {
      group = {
        name: entity.name,
        type: entity.type,
        force: entity.force,
        sampled_entities: 0,
        nearest_positions: [],
      };
      groups.set(key, group);
    }
    group.sampled_entities++;
    if (entity.amount !== undefined)
      group.sampled_amount = (group.sampled_amount || 0) + entity.amount;
    group.nearest_positions.push(entity.position);
    group.nearest_positions.sort((a, b) => distance(a) - distance(b));
    group.nearest_positions.length = Math.min(
      group.nearest_positions.length,
      config.observation.positionsPerGroup,
    );
  }
  return {
    ...rest,
    entities: detailed,
    entity_groups: [...groups.values()],
    water: { sampled_tiles: Array.isArray(water) ? water.length : 0 },
    detail_tool: "world_observe",
  };
}
