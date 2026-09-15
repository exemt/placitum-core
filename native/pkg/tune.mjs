/*
 * Узел под установку без Docker -- шаг install.sh перед панелью.
 *
 * Поставка заводит порт http-8080: в контейнере узел слушает 8080, а снаружи это
 * PLC_HTTP_PORT. На одной машине узел слушает порты машины сам, а 8080 занят
 * контроллером, поэтому порт становится PLC_HTTP_PORT. Число воркеров nginx --
 * PLC_NGINX_WORKERS, auto или число.
 *
 * Рассылки здесь нет: её делает следующий шаг, панель.
 *
 * stdout -- одна строка итога, ход работы -- stderr.
 */

const API = `http://127.0.0.1:${process.env.CONTROLLER_PORT ?? "8080"}`;
const HTTP_PORT = Number(process.env.PLC_HTTP_PORT ?? "80");
const WORKERS = process.env.PLC_NGINX_WORKERS ?? "auto";

const say = (line) => process.stderr.write(`${line}\n`);

async function api(method, path, body) {
  const res = await fetch(API + path, {
    method,
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();

  if (!res.ok) {
    throw new Error(`${method} ${path} -> ${res.status} ${text.slice(0, 400)}`);
  }

  return text === "" ? null : JSON.parse(text);
}

const rows = (body, key) => (Array.isArray(body) ? body : (body?.[key] ?? []));

const { spaces } = await api("GET", "/api/spaces");
const space = spaces.find((row) => row.name === "default");

if (space === undefined) {
  throw new Error("нет пространства default");
}

const base = `/api/${space.uuid}`;
const wanted = `http-${HTTP_PORT}`;
const ports = rows(await api("GET", `${base}/ports`), "ports");
const shipped = ports.find((row) => row.name === "http-8080" && row.port === 8080);

if (ports.some((row) => row.port === HTTP_PORT)) {
  say(`порт трафика ${HTTP_PORT}: уже есть`);
} else if (shipped !== undefined) {
  await api("PUT", `${base}/ports/${shipped.uuid}`, { name: wanted, port: HTTP_PORT });
  say(`порт трафика: http-8080 -> ${wanted}`);
} else {
  await api("POST", `${base}/ports`, {
    name: wanted,
    address: "0.0.0.0",
    port: HTTP_PORT,
    ssl: false,
    http2: false,
    proxy_protocol: false,
  });
  say(`порт трафика: заведён ${wanted}`);
}

const workers = WORKERS === "auto" ? "auto" : Number(WORKERS);
const http = await api("GET", `${base}/http`);

if (http.nginx_main?.workerProcesses === workers) {
  say(`воркеров nginx: ${WORKERS}, как и было`);
} else {
  // Ручка http принимает настройки только целиком.
  await api("PUT", `${base}/http`, {
    nginx_main: { ...(http.nginx_main ?? {}), workerProcesses: workers },
    nginx: http.nginx,
    waf_http: http.waf_http,
    waf: http.waf,
    raw: http.raw,
    raw_nginx: http.raw_nginx,
  });
  say(`воркеров nginx: ${WORKERS}`);
}

process.stdout.write(`порт ${HTTP_PORT}, воркеров ${WORKERS}\n`);
