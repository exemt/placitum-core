// Чистая установка без Docker глазами пользователя. Мерка та же, что у проверки
// чистой установки в Docker, но процессы здесь -- юниты systemd, а пулы панели
// ходят на 127.0.0.1 без resolve: имён контейнеров нет, и resolver не нужен.
//
//     sudo node check.mjs          на машине установки
//
// Код выхода 1, если хоть что-то не сошлось.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const API = "http://127.0.0.1:8080";

const answers = Object.fromEntries(
  readFileSync("/etc/placitum/placitum.conf", "utf8")
    .split("\n")
    .filter((line) => /^[A-Z_0-9]+=/.test(line))
    .map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)]),
);

const bind = answers.PLC_PANEL_BIND ?? "127.0.0.1";
const EDGE = `http://${bind === "0.0.0.0" ? "127.0.0.1" : bind}:8081`;

let failed = 0;

function check(label, ok, detail = "") {
  console.log(`${ok ? "ok  " : "FAIL"} ${label}${detail ? ` -- ${detail}` : ""}`);
  if (!ok) {
    failed += 1;
  }
}

async function get(path) {
  const res = await fetch(API + path);
  if (!res.ok) {
    throw new Error(`${path} -> ${res.status}`);
  }
  return res.json();
}

const rows = (body, key) => (Array.isArray(body) ? body : (body?.[key] ?? []));

function run(cmd, args) {
  try {
    return execFileSync(cmd, args, { stdio: ["ignore", "pipe", "ignore"] }).toString();
  } catch (err) {
    return err.stdout?.toString() ?? "";
  }
}

const { spaces } = await get("/api/spaces");
check("одно пространство default", spaces.length === 1 && spaces[0].name === "default", spaces.map((s) => s.name).join(", "));
const base = `/api/${spaces[0].uuid}`;

const servers = rows(await get(`${base}/servers`), "servers");
check(
  "один сервер -- панель",
  servers.length === 1 && servers[0].name === "panel",
  servers.map((s) => `${s.name} ${JSON.stringify(s.server_names)}`).join("; "),
);

const upstreams = rows(await get(`${base}/upstreams`), "upstreams");
const peersOf = (name) => upstreams.find((u) => u.name === name)?.peers ?? [];
const only = (name, port) =>
  peersOf(name).length > 0 && peersOf(name).every((p) => p.host === "127.0.0.1" && p.port === port && p.resolve !== true);
check(
  "пулы панели: panel -> 127.0.0.1:8080, panel-login -> 127.0.0.1:8085, без resolve",
  upstreams.map((u) => u.name).sort().join(",") === "panel,panel-login" && only("panel", 8080) && only("panel-login", 8085),
  upstreams
    .map((u) => `${u.name}: ${(u.peers ?? []).map((p) => `${p.host}:${p.port}${p.resolve ? " resolve" : ""}`).join(", ")}`)
    .join("; "),
);

const ports = rows(await get(`${base}/ports`), "ports");
check(
  `порт трафика ${answers.PLC_HTTP_PORT}, внутреннего 18081 нет`,
  ports.some((p) => String(p.port) === answers.PLC_HTTP_PORT) && !ports.some((p) => p.port === 18081),
  ports.map((p) => `${p.name} ${p.address}:${p.port}`).join("; "),
);

const http = await get(`${base}/http`);
check(
  "объявлен только инспектор калитки панели",
  Object.keys(http.waf?.inspectors ?? {}).join(",") === "auth-panel",
  Object.keys(http.waf?.inspectors ?? {}).join(", "),
);

const datasets = rows(await get(`${base}/datasets`), "datasets");
check("нет схемы-примера", !datasets.some((d) => d.name === "example-openapi.json"), `${datasets.length} наборов`);

const PANEL_PATHS = [
  "/",
  "/assets/",
  "/waf/panel-login",
  "= /agent_health_socket",
  "= /favicon.ico",
  "= /favicon.svg",
  "~ ^/api/[^/]+/auth/user-line$",
  "~ ^/api/[^/]+/geo/import/",
];

if (servers.length > 0) {
  const locations = rows(await get(`${base}/servers/${servers[0].uuid}/locations`), "locations");
  const paths = locations.map((l) => `${l.match === "exact" ? "= " : l.match === "regex" ? "~ " : ""}${l.path}`).sort();
  check("пути панели", paths.join("\n") === [...PANEL_PATHS].sort().join("\n"), paths.join("; "));
}

const settled = (list) => list.length > 0 && list.every((c) => c.state === "ok" || c.state === "nobody");
let { channels = [] } = await get(`${base}/convergence`);

for (let waited = 0; !settled(channels) && waited < 60; waited += 3) {
  await new Promise((resolve) => setTimeout(resolve, 3000));
  ({ channels = [] } = await get(`${base}/convergence`));
}

check("каналы сошлись", settled(channels), channels.map((c) => `${c.id}=${c.state}`).join(" "));

const fleet = await get("/api/fleet");
const members = ["agents", "inspectors", "stores", "services"].flatMap((key) =>
  (fleet[key] ?? []).map((m) => ({ key, name: m.name ?? m.health?.node_id ?? m.uuid, status: m.status })),
);
const notUp = members.filter((m) => m.status !== undefined && m.status !== "up");
check(
  "флот: все участники up",
  members.length > 0 && notUp.length === 0,
  `${members.length} участников${notUp.length ? `; не up: ${notUp.map((m) => `${m.key}/${m.name}=${m.status}`).join(", ")}` : ""}`,
);

const failedUnits = run("systemctl", ["list-units", "--state=failed", "--plain", "--no-legend", "placitum*"])
  .trim()
  .split("\n")
  .filter((line) => line !== "")
  .map((line) => line.split(" ")[0]);
const activeUnits = run("systemctl", ["list-units", "--state=active", "--plain", "--no-legend", "placitum*.service"])
  .trim()
  .split("\n")
  .filter((line) => line !== "").length;
check("systemd: упавших юнитов placitum нет", failedUnits.length === 0, `активных ${activeUnits}${failedUnits.length ? `; упали: ${failedUnits.join(", ")}` : ""}`);

const infra = ["nginx", "postgresql", "clickhouse-server", "placitum-nats", "placitum-redis@exchange", "placitum-redis@internal", "placitum-minio", "placitum-controller", "placitum-edge"];
const states = infra.map((unit) => [unit, run("systemctl", ["is-active", unit]).trim()]);
check(
  "systemd: инфраструктура, контроллер и агент узла активны",
  states.every(([, state]) => state === "active"),
  states.filter(([, state]) => state !== "active").map(([unit, state]) => `${unit}=${state}`).join(", "),
);

const conf = run("nginx", ["-T"]);
check("узел: стоит поколение контроллера", conf.includes("load_module modules/ngx_http_waf_module.so"));
check("узел: resolver Docker не печатается", !/resolver 127\.0\.0\.11/.test(conf));
check("узел: пул panel на 127.0.0.1:8080", /upstream panel \{[^}]*server\s+127\.0\.0\.1:8080[\s;]/s.test(conf));
check("узел: пул panel-login на 127.0.0.1:8085", /upstream panel-login \{[^}]*server\s+127\.0\.0\.1:8085[\s;]/s.test(conf));
check("узел: внутреннего сервера 18081 нет", !conf.includes("18081"));
check("узел: сервер panel на 8081", /listen (\S+:)?8081 default_server;\s*server_name panel;/.test(conf));
check("узел: обменник на 127.0.0.1:6379", /waf_store [^;]*url=redis:\/\/127\.0\.0\.1:6379/.test(conf));

const nav = await fetch(`${EDGE}/`, { redirect: "manual", headers: { accept: "text/html" } });
const where = nav.headers.get("location") ?? "";
check("панель: без сессии навигация уводится на форму", nav.status === 303 && where.startsWith("/waf/panel-login"), `${nav.status} ${where}`);

const open = await fetch(`${EDGE}/api/spaces`, { redirect: "manual", headers: { accept: "application/json" } });
check("панель: API без сессии -- 401", open.status === 401, String(open.status));

console.log(failed === 0 ? "\nчистая установка: всё сходится" : `\nчистая установка: не сходится ${failed}`);
process.exitCode = failed === 0 ? 0 : 1;
