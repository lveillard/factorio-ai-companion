import type { CompanionSession } from "../../runtime/session";
import type { GameBridge, WorldSnapshot } from "../../runtime/game";
import type { AppEvent } from "../../runtime/events";

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
    }
  });
}
const array = <T>(value: unknown): T[] => (Array.isArray(value) ? (value as T[]) : []);
const pretty = (value: unknown) => JSON.stringify(value, null, 2);
const time = (value: string) =>
  new Date(value).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });

function renderMessages() {
  const messages = state.agent.messages;
  const signature = messages.map((message) => `${message.id}:${message.status}`).join("|");
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
      node("strong", message.role === "assistant" ? "Codex" : message.player || "Tú"),
      node("span", message.source === "game" ? "Factorio" : "Panel"),
      node("time", time(message.at)),
    );
    item.append(meta, node("div", message.text, "message-text"));
    if (message.status && message.status !== "completed") {
      const labels = {
        queued: "En cola",
        running: "En curso",
        waiting: "Trabajando en el juego · continuará al terminar",
        failed: "No completado",
        cancelled: "Cancelado",
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
  $("version").textContent = `v${state.version} · Centro de control`;
  const world = state.game.snapshot;
  $("game-state").textContent = state.game.connected
    ? world?.paused
      ? "Partida pausada"
      : "Conectado"
    : "Esperando al juego";
  $("game-detail").textContent =
    state.game.error ||
    (world
      ? `Factorio ${world.factorio} · tick ${world.tick.toLocaleString()}`
      : `${state.rcon.host}:${state.rcon.port}`);
  $("account-state").textContent = state.agent.account
    ? `ChatGPT ${state.agent.account.planType || ""}`
    : "Sin sesión";
  $("account-detail").textContent = state.agent.account?.email || "Conecta tu cuenta de ChatGPT";
  $("auth-button").textContent = state.agent.account ? "Cuenta de Codex" : "Conectar Codex";
  $("agent-state").textContent = state.agent.busy
    ? "Trabajando"
    : state.agent.enabled
      ? state.agent.waiting
        ? "Tarea en el juego"
        : "Escuchando"
      : "En pausa";
  $("agent-detail").textContent =
    state.agent.error ||
    (state.agent.queued
      ? `${state.agent.queued} mensaje(s) en cola`
      : state.agent.waiting
        ? "Codex revisará el resultado cuando acabe"
        : state.agent.enabled
          ? "Listo para tus indicaciones"
          : "Inicia Codex para procesar los mensajes");
  $("resume").textContent = state.agent.enabled ? "Codex activo ✓" : "Iniciar Codex ↗";
  $<HTMLButtonElement>("resume").disabled = state.agent.enabled;
  $("queue-hint").textContent = state.agent.enabled
    ? "Enter para enviar"
    : "Codex en pausa · pulsa Iniciar Codex para procesar la cola";
  $("rcon-address").textContent = `${state.rcon.host}:${state.rcon.port}`;
  $("mcp-address").textContent = state.mcp.url;
  $("observed-at").textContent = state.game.observedAt
    ? time(state.game.observedAt)
    : "Todavía no hay datos";
  const models = array<{ id: string; model: string; displayName: string }>(state.agent.models);
  const modelSelect = $<HTMLSelectElement>("model");
  if (modelSelect.options.length !== models.length + 1) {
    modelSelect.replaceChildren(
      new Option("Modelo predeterminado", ""),
      ...models.map(
        (model) =>
          new Option(model.displayName || model.model || model.id, model.model || model.id),
      ),
    );
    modelSelect.value = state.agent.model;
  }
  if (world) {
    $("surface").textContent = world.surface;
    $("map-empty").hidden = true;
    $("map-coordinate").textContent =
      `x ${world.center.x.toFixed(1)}  y ${world.center.y.toFixed(1)}  ·  radio ${world.radius}`;
    $("map-note").textContent =
      `${array(world.entities).length} entidades observadas${world.entities_truncated ? ` de ${world.entities_total} (muestra limitada)` : ""} · entorno cercano y terreno explorado${world.water_truncated ? " · agua parcial" : ""}`;
    const research = world.research as { name: string; progress: number } | undefined;
    $("research-name").textContent = research?.name || "Sin investigación activa";
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
        new Option(id === "target" ? "Coordinador" : "Jugador / inicio", "0"),
        ...companions.map((c) => new Option(`${c.name || "Compañero"} · #${c.id}`, String(c.id))),
      );
      select.value = companions.some((c) => String(c.id) === value) ? value : "0";
    }
  }
  const roster = $("companions");
  if (!companions.length) {
    roster.replaceChildren(node("p", "Aún no hay compañeros en esta partida.", "muted"));
    return;
  }
  roster.replaceChildren(
    ...companions.map((c) => {
      const card = node("div", undefined, "companion-card");
      const title = node("div", undefined, "companion-title");
      const stop = node("button", "Parar");
      stop.addEventListener("click", () => {
        void api("tools/call", { name: "companion_stop", args: { companionId: c.id } }).catch(
          (error) => notice(String(error)),
        );
      });
      title.append(node("strong", c.name || `Compañero #${c.id}`), stop);
      const running = Object.entries(c.queues || {})
        .filter(([, queue]) => queue.active)
        .map(([name, queue]) => `${name}${queue.state ? ` (${queue.state})` : ""}`);
      card.append(
        title,
        node(
          "p",
          c.dead
            ? "Sin vida"
            : `${Math.round(c.health || 0)}/${Math.round(c.max_health || 0)} PV · ${running.join(", ") || "Disponible"}`,
        ),
      );
      const inventory = node("div", undefined, "inventory");
      const items = array<{ name: string; count: number }>(c.inventory);
      inventory.append(
        ...items.slice(0, 10).map((item) => node("span", `${item.name} ×${item.count}`)),
      );
      if (items.length > 10) inventory.append(node("span", `+${items.length - 10} tipos`));
      card.append(inventory);
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
    $("stream-state").textContent = "Panel conectado";
    $("stream-state").classList.add("online");
    void refresh().catch((error) => notice(String(error)));
  };
  eventSource.onerror = () => {
    $("stream-state").textContent = "Reconectando panel…";
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
        } else $("auth-error").textContent = String(value.error || "Login cancelado");
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
  notice("Nueva conversación preparada. Pulsa Iniciar compañero cuando quieras continuar.");
});
action("spawn", async () => {
  const ids = array<{ id: number }>(state.game.snapshot?.companions).map((c) => c.id);
  const id = Math.max(0, ...ids) + 1;
  const result = await api("tools/call", { name: "companion_spawn", args: { companionId: id } });
  if (!result.success) throw new Error(String(result.error));
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
      ? "Abre la página e introduce este código:"
      : "Completa el acceso en el navegador de este ordenador:";
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
  try {
    await api("chat", {
      message: input.value,
      companionId: Number($<HTMLSelectElement>("target").value),
    });
    input.value = "";
    await refresh();
    $("messages").scrollTop = $("messages").scrollHeight;
  } catch (error) {
    notice(String(error));
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
    $("tool-result").textContent = "Ejecutando…";
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
