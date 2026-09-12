import { test, expect } from "bun:test";
import { agentObservation } from "../src/runtime/observation";
import type { WorldSnapshot } from "../src/runtime/game";
import config from "../config/agent.json";

test("compact context preserves actionable state and marks sampled terrain without mutating the map", () => {
  const machine = {
    name: "stone-furnace",
    type: "furnace",
    position: { x: 1, y: 2 },
    fuel: [],
    output: [{ name: "iron-plate", count: 4 }],
  };
  const enemy = { name: "small-biter", type: "unit", force: "enemy", position: { x: 4, y: 2 } };
  const snapshot: WorldSnapshot = {
    version: "test",
    factorio: "2.0",
    session_id: "test",
    tick: 20,
    paused: false,
    center: { x: 0, y: 0 },
    radius: 48,
    surface: "nauvis",
    companions: [
      {
        id: 1,
        inventory: [{ name: "iron-ore", count: 12 }],
        queues: { gather: { active: false, error: "unreachable" } },
        last_jobs: { gather: { state: "failed", gathered: 12 } },
      },
    ],
    players: [{ name: "Player", connected: true }],
    tasks: [{ companionId: 1, status: "active" }],
    research: { name: "automation", progress: 0.4 },
    errors: [{ error: "stuck" }],
    entities: [
      machine,
      enemy,
      ...Array.from({ length: 230 }, (_, i) => ({
        name: "iron-ore",
        type: "resource",
        force: "neutral",
        amount: 100,
        position: { x: 230 - i, y: 0 },
      })),
    ],
    water: Array.from({ length: 512 }, (_, i) => ({ x: i, y: 1 })),
    entities_total: 500,
    entities_truncated: true,
    water_truncated: true,
  };
  const original = JSON.stringify(snapshot);
  const compact = agentObservation(snapshot)!;
  expect(compact.entities).toEqual([machine, enemy]);
  for (const field of [
    "companions",
    "players",
    "tasks",
    "research",
    "errors",
    "entities_truncated",
    "water_truncated",
  ])
    expect<unknown>(compact[field as keyof typeof compact]).toEqual(snapshot[field]);
  expect(compact.entity_groups[0]).toMatchObject({ sampled_entities: 230, sampled_amount: 23000 });
  expect(compact.entity_groups[0]!.nearest_positions).toEqual(
    Array.from({ length: config.observation.positionsPerGroup }, (_, i) => ({ x: i + 1, y: 0 })),
  );
  expect(compact.water.sampled_tiles).toBe(512);
  expect(compact.detail_tool).toBe("world_observe");
  expect(JSON.stringify(compact).length).toBeLessThan(original.length * 0.15);
  expect(JSON.stringify(snapshot)).toBe(original);
  snapshot.entities = {} as unknown as unknown[];
  snapshot.water = {};
  expect(agentObservation(snapshot)).toMatchObject({
    entities: [],
    entity_groups: [],
    water: { sampled_tiles: 0 },
  });
});
