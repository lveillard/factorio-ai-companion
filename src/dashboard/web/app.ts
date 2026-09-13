import type { CompanionSession } from "../../runtime/session";
import type { GameBridge, WorldSnapshot } from "../../runtime/game";
import type { AppEvent } from "../../runtime/events";
import ui from "../../../config/dashboard.json";

type Entity = {
  name: string;
  type: string;
  force?: string;
  position: { x: number; y: number };
  [key: string]: unknown;
};
type State = {
  version: string;
  agent: ReturnType<CompanionSession["status"]>;
  game: ReturnType<GameBridge["status"]>;
  events: AppEvent[];
  tools: GameBridge["schemas"];
  rcon: { host: string; port: number };
  mcp: { url: string; protocol: string };
};
const $ = <T extends HTMLElement = HTMLElement>(id: string): T => document.getElementById(id) as T;
const node = <K extends keyof HTMLElementTagNameMap>(
  tag: K,
  text?: string,
  className?: string,
): HTMLElementTagNameMap[K] => {
  const element = document.createElement(tag);
  if (text !== undefined) element.textContent = text;
  if (className) element.className = className;
  return element;
};
let state: State;
let eventSource: EventSource | null = null;
let loginId = "";
let messageSignature = "";
let companionSignature = "";
const live = new Map<string, string>();

function notice(text: string) {
  $("notice").textContent = text;
  $("notice").hidden = !text;
}
async function api<T = Record<string, unknown>>(path: string, data?: unknown): Promise<T> {
  const response = await fetch(`/api/${path}`, {
    ...(data === undefined
      ? {}
      : {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(data),
        }),
  });
  const result = await response.json();
  if (!response.ok) {
    if (response.status === 401 && !$("unlock-dialog").hasAttribute("open"))
      $<HTMLDialogElement>("unlock-dialog").showModal();
    throw new Error(result.error || `HTTP ${response.status}`);
  }
  return result as T;
}
function action(id: string, callback: () => Promise<unknown>) {
  $(id).addEventListener("click", async () => {
    const button = $<HTMLButtonElement>(id);
    button.disabled = true;
    try {
      notice("");
      await callback();
    } catch (error) {
      notice(String(error));
    } finally {
      button.disabled = false;
      renderState();
    }
  });
}
const array = <T>(value: unknown): T[] => (Array.isArray(value) ? (value as T[]) : []);
const itemName = (name: string) => name.replaceAll("-", " ").replace(/^./, (c) => c.toUpperCase());
let miningCompanion = 0;
let pendingSelection: number | null = null;
async function tool(name: string, args: Record<string, unknown>) {
  notice("");
  const result = await api<{ success: boolean; error?: string; data?: unknown }>("tools/call", {
    name,
    args,
  });
  if (!result.success) throw new Error(result.error || "Action failed");
  return result.data;
}
async function selectCompanion(id: number) {
  $<HTMLSelectElement>("target").value = String(id);
  $<HTMLSelectElement>("focus").value = String(id);
  await api("settings", { focus: id });
  renderCompanions();
  document.querySelector<HTMLButtonElement>('[data-tab="chat"]')?.click();
  $("message").focus();
}
const pretty = (value: unknown) => JSON.stringify(value, null, 2);
const time = (value: string) =>
  new Date(value).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });

function renderMessages() {
  const messages = state.agent.messages;
  const signature = messages
    .map((message) => `${message.id}:${message.status}:${message.gameDelivery}`)
    .join("|");
  if (signature === messageSignature) return;
  messageSignature = signature;
  const container = $("messages");
  const nearBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 100;
  if (!messages.length) return;
  container.replaceChildren();
  for (const message of messages) {
    const item = node("article", undefined, `message ${message.role}`);
    const meta = node("div", undefined, "message-meta");
    meta.append(
      node(
        "strong",
        message.role === "assistant"
          ? array<{ id: number; name: string }>(state.game.snapshot?.companions).find(
              (c) => c.id === message.companionId,
            )?.name || "Codex"
          : message.player || "You",
      ),
      node(
        "span",
        message.source === "game"
          ? "Factorio"
          : message.gameDelivery === "sent"
            ? "Panel · Factorio"
            : "Panel",
      ),
      node("time", time(message.at)),
    );
    item.append(meta, node("div", message.text, "message-text"));
    if (message.phase === "progress") meta.append(node("span", "Progress"));
    if (message.gameDelivery === "pending" || message.gameDelivery === "failed") {
      item.append(
        node(
          "div",
          message.gameDelivery === "pending"
            ? "Waiting for Factorio"
            : `Not delivered to Factorio · ${message.deliveryError || "Connection failed"}`,
          "message-status",
        ),
      );
    }
    if (message.status && message.status !== "completed") {
      const labels = {
        queued: "Queued",
        running: "Running",
        waiting: "Working in game",
        failed: "Failed",
        cancelled: "Cancelled",
      };
      item.append(
        node(
          "div",
          `${labels[message.status]}${message.error ? ` · ${message.error}` : ""}`,
          `message-status ${message.status}`,
        ),
      );
    }
    container.append(item);
  }
  if (nearBottom) container.scrollTop = container.scrollHeight;
}

function renderState() {
  if (!state) return;
  if (!state.agent.busy) {
    live.clear();
    $("live-response").hidden = true;
  }
  $("version").textContent = `v${state.version}`;
  const world = state.game.snapshot;
  const connected = state.game.connected;
  $("connection-notice").hidden = connected;
  $("connection-notice").textContent = `Game connection unavailable. ${
    ["127.0.0.1", "localhost", "::1"].includes(state.rcon.host)
      ? "Open Factorio with the companion launcher, then host a multiplayer game."
      : "Check the remote server's RCON connection."
  } Spawn and the live map will be available when connected.`;
  $("map-empty").hidden = connected && !!world;
  $("map-empty").textContent = world
    ? "Connection lost · last view"
    : "Waiting for game connection";
  $("game-state").textContent = state.game.connected
    ? world?.paused
      ? "Game paused"
      : "Connected"
    : "Disconnected";
  $("game-detail").textContent =
    state.game.error ||
    (world
      ? `Factorio ${world.factorio} · tick ${world.tick.toLocaleString()}`
      : `${state.rcon.host}:${state.rcon.port}`);
  $("account-state").textContent = state.agent.account
    ? `ChatGPT ${state.agent.account.planType || ""}`
    : "Signed out";
  $("account-detail").textContent = state.agent.account?.email || "Sign in with ChatGPT";
  $("auth-button").textContent = "Settings";
  $("agent-state").textContent = state.agent.busy
    ? state.agent.activity === "acting"
      ? "Acting"
      : "Thinking"
    : state.agent.enabled
      ? state.agent.waiting
        ? state.agent.productionReviewAt
          ? "Waiting for production"
          : "Working in game"
        : connected
          ? "Listening"
          : "Waiting for game"
      : "Paused";
  $("agent-detail").textContent =
    state.agent.error ||
    (state.agent.busy && state.agent.activeSince
      ? `${Math.floor((Date.now() - state.agent.activeSince) / 1000)}s · ${state.agent.model || "Default model"}`
      : state.agent.queued
        ? `${state.agent.queued} queued`
        : state.agent.waiting
          ? "Checking when work finishes"
          : "");
  $("resume").textContent = state.agent.enabled ? "Chat active" : "Start chat";
  $<HTMLButtonElement>("resume").disabled = state.agent.enabled;
  $("queue-hint").textContent = state.agent.enabled ? "Enter to send" : "Paused";
  $("send-message").textContent =
    !state.agent.enabled && state.agent.account ? "Send & start" : "Send";
  $<HTMLButtonElement>("spawn").disabled = !state.game.connected;
  $("rcon-address").textContent = `${state.rcon.host}:${state.rcon.port}`;
  $("mcp-address").textContent = state.mcp.url;
  $("observed-at").textContent = state.game.observedAt
    ? time(state.game.observedAt)
    : "No data yet";
  const models = array<{ id: string; model: string; displayName: string }>(state.agent.models);
  const modelSelect = $<HTMLSelectElement>("model");
  if (modelSelect.options.length !== models.length + 1) {
    modelSelect.replaceChildren(
      new Option("Default model", ""),
      ...models.map(
        (model) =>
          new Option(model.displayName || model.model || model.id, model.model || model.id),
      ),
    );
    modelSelect.value = state.agent.model;
  }
  if (world) {
    $("surface").textContent = world.surface;
    $("map-coordinate").textContent =
      `x ${world.center.x.toFixed(1)}  y ${world.center.y.toFixed(1)}  ·  radius ${world.radius}`;
    $("map-note").textContent = world.entities_truncated ? "Partial view" : "";
    const research = world.research as { name: string; progress: number } | undefined;
    $("research-name").textContent = research?.name || "No active research";
    $("research-percent").textContent = research ? `${Math.round(research.progress * 100)}%` : "—";
    $<HTMLProgressElement>("research-progress").value = research?.progress || 0;
    const errors = array<{ error: string; context?: string }>(world.errors);
    $("game-errors").replaceChildren(
      ...errors
        .slice(-3)
        .map((error) => node("p", `${error.context || "Lua"}: ${error.error}`, "muted")),
    );
  }
  renderCompanions();
  renderMessages();
  drawMap();
}

function renderCompanions() {
  const companions = array<{
    id: number;
    name?: string;
    dead?: boolean;
    position?: { x: number; y: number };
    health?: number;
    max_health?: number;
    inventory?: unknown;
    queues?: Record<string, { active?: boolean; state?: string }>;
  }>(state.game.snapshot?.companions);
  const signature = companions.map((c) => `${c.id}:${c.name}`).join("|");
  if (signature !== companionSignature) {
    companionSignature = signature;
    for (const id of ["target", "focus"]) {
      const select = $<HTMLSelectElement>(id);
      const value = select.value;
      select.replaceChildren(
        new Option(id === "target" ? "Everyone" : "Player", "0"),
        ...companions.map((c) => new Option(c.name || `Companion ${c.id}`, String(c.id))),
      );
      select.value = companions.some((c) => String(c.id) === value) ? value : "0";
    }
  }
  const roster = $("companions");
  $("companion-count").textContent = String(companions.length);
  if (pendingSelection !== null && companions.some((c) => c.id === pendingSelection)) {
    const id = pendingSelection;
    pendingSelection = null;
    $<HTMLSelectElement>("target").value = String(id);
    $<HTMLSelectElement>("focus").value = String(id);
    void api("settings", { focus: id }).catch((error) => notice(String(error)));
  }
  const selected = Number($<HTMLSelectElement>("target").value);
  $("chat-title").textContent = selected
    ? `Chat with ${companions.find((c) => c.id === selected)?.name || "companion"}`
    : "Chat";
  if (!companions.length) {
    roster.replaceChildren(
      node(
        "p",
        state.game.connected ? "Add your first companion." : "Connect a game to add companions.",
        "muted",
      ),
    );
    return;
  }
  roster.replaceChildren(
    ...companions.map((c) => {
      const card = node("div", undefined, "companion-card");
      card.classList.toggle("selected", c.id === selected);
      card.dataset.companion = String(c.id);
      const title = node("div", undefined, "companion-title");
      const stop = node("button", "Stop");
      stop.addEventListener("click", () => {
        void tool("companion_stop", { companionId: c.id })
          .then(() => refresh())
          .catch((error) => notice(String(error)));
      });
      const select = node("button", c.name || `Companion ${c.id}`, "companion-select");
      select.setAttribute("aria-label", `Select ${c.name || c.id}`);
      select.setAttribute("aria-pressed", String(c.id === selected));
      select.addEventListener("click", () => {
        void selectCompanion(c.id).catch((error) => notice(String(error)));
      });
      title.append(select);
      const running = Object.entries(c.queues || {})
        .filter(([, queue]) => queue.active)
        .map(([name]) => (ui.jobs as Record<string, string>)[name] || "Working");
      card.append(
        title,
        node(
          "p",
          c.dead
            ? "Dead"
            : `${running.join(", ") || "Idle"}${c.health === undefined ? "" : ` · ${Math.round(c.health)} HP`}`,
        ),
      );
      const inventory = node("div", undefined, "inventory");
      const items = array<{ name: string; count: number }>(c.inventory);
      inventory.append(
        ...items.slice(0, 4).map((item) => node("span", `${itemName(item.name)} ×${item.count}`)),
      );
      if (items.length > 4) inventory.append(node("span", `+${items.length - 4}`));
      card.append(inventory);
      const actions = node("div", undefined, "companion-actions");
      const mine = node("button", "Mine");
      mine.addEventListener("click", () => {
        miningCompanion = c.id;
        $("mine-title").textContent = `${c.name || "Companion"} · Mine`;
        $("mine-error").textContent = "";
        $<HTMLDialogElement>("mine-dialog").showModal();
      });
      const follow = node("button", "Follow me");
      const player = array<{ name: string; connected?: boolean }>(
        state.game.snapshot?.players,
      ).find((p) => p.connected);
      follow.disabled = !player || !state.game.connected || !!c.dead;
      follow.addEventListener("click", () => {
        if (player)
          void tool("move_follow", { companionId: c.id, playerName: player.name })
            .then(() => refresh())
            .catch((error) => notice(String(error)));
      });
      mine.disabled = stop.disabled = !state.game.connected || !!c.dead;
      actions.append(mine, follow, stop);
      card.append(actions);
      return card;
    }),
  );
}

function color(entity: Entity) {
  if (entity.force === "enemy") return "#ee8f81";
  if (entity.type === "resource")
    return (
      { "iron-ore": "#8fbad1", "copper-ore": "#d19467", coal: "#757e80", stone: "#bfb798" }[
        entity.name
      ] || "#a5a877"
    );
  if (entity.type === "tree") return "#476b51";
  if (entity.type === "character") return "#a5e9cb";
  return "#e9b65d";
}
function mapCoordinates(x: number, y: number) {
  const canvas = $<HTMLCanvasElement>("world-map"),
    world = state.game.snapshot!;
  const scale = Math.min(canvas.clientWidth, canvas.clientHeight) / (world.radius * 2 + 8);
  return {
    x: canvas.clientWidth / 2 + (x - world.center.x) * scale,
    y: canvas.clientHeight / 2 + (y - world.center.y) * scale,
    scale,
  };
}
function drawMap() {
  const canvas = $<HTMLCanvasElement>("world-map");
  const rect = canvas.getBoundingClientRect();
  canvas.width = rect.width * devicePixelRatio;
  canvas.height = rect.height * devicePixelRatio;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  ctx.scale(devicePixelRatio, devicePixelRatio);
  ctx.clearRect(0, 0, rect.width, rect.height);
  ctx.strokeStyle = "#213031";
  ctx.lineWidth = 1;
  for (let x = 0; x < rect.width; x += 24) {
    ctx.beginPath();
    ctx.moveTo(x, 0);
    ctx.lineTo(x, rect.height);
    ctx.stroke();
  }
  for (let y = 0; y < rect.height; y += 24) {
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(rect.width, y);
    ctx.stroke();
  }
  const world = state?.game.snapshot;
  if (!world) return;
  ctx.fillStyle = "#2f5363";
  for (const water of array<{ x: number; y: number }>(world.water)) {
    const p = mapCoordinates(water.x, water.y);
    ctx.fillRect(p.x, p.y, Math.ceil(p.scale), Math.ceil(p.scale));
  }
  for (const e of array<Entity>(world.entities).reverse()) {
    const p = mapCoordinates(e.position.x, e.position.y);
    const size = e.type === "character" ? 6 : e.type === "resource" || e.type === "tree" ? 3 : 5;
    ctx.fillStyle = color(e);
    ctx.fillRect(p.x - size / 2, p.y - size / 2, size, size);
  }
  for (const c of array<{ id: number; surface?: string; position?: { x: number; y: number } }>(
    world.companions,
  )) {
    if (!c.position || c.surface !== world.surface) continue;
    const p = mapCoordinates(c.position.x, c.position.y);
    ctx.strokeStyle = "#e9b65d";
    ctx.beginPath();
    ctx.arc(p.x, p.y, 7, 0, Math.PI * 2);
    ctx.stroke();
    ctx.fillStyle = "#fff0c7";
    ctx.font = "12px monospace";
    ctx.fillText(`#${c.id}`, p.x + 10, p.y - 7);
  }
  for (const player of array<{ name: string; surface: string; position: { x: number; y: number } }>(
    world.players,
  )) {
    if (player.surface !== world.surface) continue;
    const p = mapCoordinates(player.position.x, player.position.y);
    ctx.fillStyle = "#9ddabb";
    ctx.beginPath();
    ctx.arc(p.x, p.y, 4, 0, Math.PI * 2);
    ctx.fill();
    ctx.font = "12px monospace";
    ctx.fillText(player.name, p.x + 9, p.y + 14);
  }
}

function renderTools() {
  const select = $<HTMLSelectElement>("tool-select");
  if (!select.options.length)
    select.append(...state.tools.map((tool) => new Option(tool.name, tool.name)));
  const tool = state.tools.find((tool) => tool.name === select.value);
  if (!tool) return;
  $("tool-description").textContent = tool.description;
  const fields = $("tool-fields");
  fields.replaceChildren();
  for (const [name, property] of Object.entries(tool.inputSchema.properties)) {
    const field = node(
      "label",
      undefined,
      `field${property.type === "array" || name === "message" ? " wide" : ""}`,
    );
    field.append(node("span", name + (tool.inputSchema.required?.includes(name) ? " *" : "")));
    const input =
      property.type === "array" || name === "message" ? node("textarea") : node("input");
    input.name = name;
    input.required = tool.inputSchema.required?.includes(name) || false;
    input.value =
      name === "companionId"
        ? $<HTMLSelectElement>("target").value === "0"
          ? String(property.minimum || 0)
          : $<HTMLSelectElement>("target").value
        : property.type === "array"
          ? pretty(property.default ?? array(property.examples)[0] ?? [])
          : property.default !== undefined
            ? String(property.default)
            : "";
    if (input instanceof HTMLInputElement) {
      input.type = property.type === "number" || property.type === "integer" ? "number" : "text";
      input.step = property.type === "integer" ? "1" : "any";
      if (property.minimum !== undefined) input.min = String(property.minimum);
      if (property.maximum !== undefined) input.max = String(property.maximum);
    }
    field.append(input);
    if (property.description) field.append(node("small", String(property.description)));
    fields.append(field);
  }
}
function renderLogs() {
  const filter = $<HTMLInputElement>("log-filter").value.toLowerCase();
  $("log-count").textContent = String(state.events.length);
  const entries = state.events
    .filter((event) => JSON.stringify(event).toLowerCase().includes(filter))
    .slice(-150)
    .reverse();
  $("logs").replaceChildren(
    ...entries.map((event) => {
      const data = event.data as Record<string, unknown>;
      const details = node(
        "details",
        undefined,
        `log-entry${data?.error || data?.success === false ? " error" : ""}`,
      );
      const summary = node("summary");
      summary.append(
        node("time", time(event.at)),
        node("span", `${event.type}${data?.name ? ` · ${data.name}` : ""}`),
      );
      details.append(summary, node("pre", pretty(data)));
      return details;
    }),
  );
}
function connectEvents() {
  eventSource?.close();
  eventSource = new EventSource("/api/events");
  eventSource.onopen = () => {
    $("stream-state").textContent = "Live";
    $("stream-state").classList.add("online");
    void refresh().catch((error) => notice(String(error)));
  };
  eventSource.onerror = () => {
    $("stream-state").textContent = "Reconnecting…";
    $("stream-state").classList.remove("online");
  };
  eventSource.onmessage = ({ data }) => {
    const event = JSON.parse(data) as AppEvent;
    const value = event.data as Record<string, unknown>;
    if (event.type === "world") {
      state.game.snapshot = value.snapshot as WorldSnapshot;
      state.game.observedAt = String(value.observedAt);
      state.game.connected = true;
      state.game.error = null;
      renderState();
    } else if (event.type === "agent.state") {
      state.agent = value as State["agent"];
      renderState();
    } else if (event.type === "chat.delta") {
      const id = String(value.itemId);
      live.set(id, (live.get(id) || "") + String(value.delta));
      $("live-response").hidden = false;
      $("live-response").textContent = [...live.values()].join("\n\n").slice(-8000);
    } else if (event.type === "chat") {
      if (value.role === "assistant") {
        live.clear();
        $("live-response").hidden = true;
      }
      void refresh().catch((error) => notice(String(error)));
    } else if (event.type === "game.disconnected") {
      state.game.connected = false;
      state.game.error = String(value.error);
      renderState();
    } else if (["account", "models", "login.completed"].includes(event.type)) {
      if (event.type === "login.completed") {
        if (value.success) {
          $<HTMLDialogElement>("auth-dialog").close();
          loginId = "";
        } else $("auth-error").textContent = String(value.error || "Sign-in cancelled");
      }
      void refresh().catch((error) => notice(String(error)));
    } else if (
      ["session.error", "stop.failed", "chat.delivery_failed", "codex.disconnected"].includes(
        event.type,
      )
    )
      notice(String(value.error));
    if (
      !["world", "agent.state", "chat.delta", "models", "account", "rateLimits"].includes(
        event.type,
      ) &&
      value.source !== "poll"
    ) {
      if (!state.events.some((existing) => existing.id === event.id)) state.events.push(event);
      state.events = state.events.slice(-500);
      renderLogs();
    }
  };
}
async function refresh() {
  state = await api<State>("state");
  renderState();
  renderLogs();
  if (!$<HTMLSelectElement>("tool-select").options.length) renderTools();
  const resource = $<HTMLSelectElement>("mine-resource");
  if (!resource.options.length) {
    resource.replaceChildren(
      ...ui.mining.resources.map((name) => new Option(itemName(name), name)),
    );
    const count = state.tools.find((t) => t.name === "gather")!.inputSchema.properties.count!;
    const input = $<HTMLInputElement>("mine-count");
    input.min = String(count.minimum);
    input.max = String(count.maximum);
    input.value = String(ui.mining.defaultCount);
  }
}

action("auth-button", async () => {
  $<HTMLDialogElement>("auth-dialog").showModal();
});
action("resume", async () => {
  if (!state.agent.account) {
    $<HTMLDialogElement>("auth-dialog").showModal();
    return;
  }
  await api("agent/resume", {});
  await refresh();
});
action("pause", async () => {
  await api("agent/pause", {});
  live.clear();
  $("live-response").hidden = true;
  await refresh();
});
action("new-chat", async () => {
  await api("agent/new", {});
  await refresh();
  notice("");
});
action("spawn", async () => {
  const count = array(state.game.snapshot?.companions).length;
  const input = $<HTMLInputElement>("companion-name");
  input.value = count ? `${ui.defaultCompanionName} ${count + 1}` : ui.defaultCompanionName;
  input.maxLength = Number(
    state.tools.find((t) => t.name === "companion_spawn")!.inputSchema.properties.name!.maxLength,
  );
  $("spawn-error").textContent = "";
  $<HTMLDialogElement>("spawn-dialog").showModal();
  input.focus();
  input.select();
});
function form(id: string, errorId: string, submit: () => Promise<void>) {
  $(id).addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = $(id).querySelector<HTMLButtonElement>('button[type="submit"]')!;
    button.disabled = true;
    $(errorId).textContent = "";
    try {
      await submit();
    } catch (error) {
      $(errorId).textContent = String(error).replace(/^Error: /, "");
    } finally {
      button.disabled = false;
    }
  });
}
form("spawn-form", "spawn-error", async () => {
  const list = (await tool("companion_list", {})) as { companions?: Array<{ id: number }> };
  const ids = new Set(array<{ id: number }>(list.companions).map((c) => c.id));
  let id = 1;
  while (ids.has(id)) id++;
  const name = $<HTMLInputElement>("companion-name").value.trim();
  const result = (await tool("companion_spawn", { companionId: id, name })) as {
    spawned?: boolean;
  };
  if (!result.spawned) throw new Error("Companion already exists. Try again.");
  pendingSelection = id;
  $<HTMLDialogElement>("spawn-dialog").close();
  await refresh();
});
form("mine-form", "mine-error", async () => {
  await tool("gather", {
    companionId: miningCompanion,
    resource: $<HTMLSelectElement>("mine-resource").value,
    count: Number($<HTMLInputElement>("mine-count").value),
  });
  $<HTMLDialogElement>("mine-dialog").close();
  await refresh();
});
async function login(type: string) {
  $("auth-error").textContent = "";
  try {
    const result = await api<{
      loginId: string;
      userCode?: string;
      verificationUrl?: string;
      authUrl?: string;
    }>("auth/login", { type });
    loginId = result.loginId;
    $("auth-progress").hidden = false;
    $("device-code").textContent = result.userCode || "";
    $("auth-instruction").textContent = result.userCode
      ? "Enter this code on the sign-in page:"
      : "Sign in using this computer’s browser:";
    const url = new URL(result.verificationUrl || result.authUrl || "");
    if (url.protocol !== "https:") throw new Error("Invalid login URL");
    $<HTMLAnchorElement>("auth-link").href = url.href;
  } catch (error) {
    $("auth-error").textContent = String(error);
  }
}
action("device-login", () => login("chatgptDeviceCode"));
action("browser-login", () => login("chatgpt"));
action("cancel-login", async () => {
  if (loginId) await api("auth/cancel", { loginId });
  $("auth-progress").hidden = true;
  loginId = "";
});
action("refresh-auth", async () => {
  await api("auth/refresh", {});
  await refresh();
  if (state.agent.account) $<HTMLDialogElement>("auth-dialog").close();
});
action("logout", async () => {
  await api("auth/logout", {});
  await refresh();
  $<HTMLDialogElement>("auth-dialog").close();
});
$("unlock-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    await api("unlock", { token: $<HTMLInputElement>("access-token").value });
    $<HTMLInputElement>("access-token").value = "";
    $<HTMLDialogElement>("unlock-dialog").close();
    notice("");
    await refresh();
    connectEvents();
  } catch (error) {
    $("unlock-error").textContent = String(error);
  }
});
$("chat-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = $<HTMLTextAreaElement>("message");
  const button = $<HTMLButtonElement>("send-message");
  if (button.disabled || !input.value.trim()) return;
  button.disabled = true;
  try {
    await api("chat", {
      message: input.value,
      companionId: Number($<HTMLSelectElement>("target").value),
    });
    input.value = "";
    if (!state.agent.enabled && state.agent.account) await api("agent/resume", {});
    else if (!state.agent.account) $<HTMLDialogElement>("auth-dialog").showModal();
    await refresh();
    $("messages").scrollTop = $("messages").scrollHeight;
  } catch (error) {
    notice(String(error));
  } finally {
    button.disabled = false;
  }
});
$("message").addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    $<HTMLFormElement>("chat-form").requestSubmit();
  }
});
document.querySelectorAll<HTMLButtonElement>("[data-prompt]").forEach((button) =>
  button.addEventListener("click", () => {
    $<HTMLTextAreaElement>("message").value = button.dataset.prompt || "";
    $("message").focus();
  }),
);
document.querySelectorAll<HTMLButtonElement>("[data-tab]").forEach((button) =>
  button.addEventListener("click", () => {
    document.querySelectorAll<HTMLButtonElement>("[data-tab]").forEach((tab) => {
      const active = tab === button;
      tab.classList.toggle("active", active);
      tab.setAttribute("aria-selected", String(active));
      $(`tab-${tab.dataset.tab}`).hidden = !active;
    });
  }),
);
for (const id of ["model", "focus"])
  $(id).addEventListener("change", () => {
    void api("settings", {
      model: $<HTMLSelectElement>("model").value,
      focus: Number($<HTMLSelectElement>("focus").value),
    }).catch((error) => notice(String(error)));
  });
$("target").addEventListener("change", renderCompanions);
$("tool-select").addEventListener("change", renderTools);
$("tool-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const name = $<HTMLSelectElement>("tool-select").value;
  const tool = state.tools.find((tool) => tool.name === name)!;
  try {
    const args: Record<string, unknown> = {};
    for (const [key, property] of Object.entries(tool.inputSchema.properties)) {
      const input = $<HTMLFormElement>("tool-form").elements.namedItem(key) as HTMLInputElement;
      if (input.value !== "")
        args[key] =
          property.type === "integer" || property.type === "number"
            ? Number(input.value)
            : property.type === "array"
              ? JSON.parse(input.value)
              : input.value;
    }
    $("tool-result").textContent = "Running…";
    $("tool-result").textContent = pretty(await api("tools/call", { name, args }));
  } catch (error) {
    $("tool-result").textContent = String(error);
  }
});
$("log-filter").addEventListener("input", renderLogs);
action("export-logs", async () => {
  const url = URL.createObjectURL(
    new Blob([state.events.map((event) => JSON.stringify(event)).join("\n")], {
      type: "application/x-ndjson",
    }),
  );
  const link = node("a");
  link.href = url;
  link.download = `factorio-companion-${Date.now()}.jsonl`;
  link.click();
  URL.revokeObjectURL(url);
});
$("world-map").addEventListener("click", (event) => {
  const rect = $("world-map").getBoundingClientRect();
  let nearest: Entity | undefined;
  let best = 15;
  for (const entity of array<Entity>(state.game.snapshot?.entities)) {
    const p = mapCoordinates(entity.position.x, entity.position.y);
    const d = Math.hypot(p.x - (event.clientX - rect.left), p.y - (event.clientY - rect.top));
    if (d < best) {
      nearest = entity;
      best = d;
    }
  }
  if (nearest) {
    $("entity-inspector").hidden = false;
    $<HTMLDetailsElement>("entity-inspector").open = true;
    $("entity-data").textContent = pretty(nearest);
  }
});
new ResizeObserver(drawMap).observe($("world-map"));
void refresh()
  .then(connectEvents)
  .catch((error) => notice(String(error)));
