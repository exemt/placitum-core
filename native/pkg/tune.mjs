// Node step of the installation without Docker: the shipped http-8080 port becomes PLC_HTTP_PORT
// and nginx workers follow PLC_NGINX_WORKERS.

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
  throw new Error("space default not found");
}

const base = `/api/${space.uuid}`;
const wanted = `http-${HTTP_PORT}`;
const ports = rows(await api("GET", `${base}/ports`), "ports");
const shipped = ports.find((row) => row.name === "http-8080" && row.port === 8080);

if (ports.some((row) => row.port === HTTP_PORT)) {
  say(`traffic port ${HTTP_PORT}: exists`);
} else if (shipped !== undefined) {
  await api("PUT", `${base}/ports/${shipped.uuid}`, { name: wanted, port: HTTP_PORT });
  say(`traffic port: http-8080 -> ${wanted}`);
} else {
  await api("POST", `${base}/ports`, {
    name: wanted,
    address: "0.0.0.0",
    port: HTTP_PORT,
    ssl: false,
    http2: false,
    proxy_protocol: false,
  });
  say(`traffic port: created ${wanted}`);
}

const workers = WORKERS === "auto" ? "auto" : Number(WORKERS);
const http = await api("GET", `${base}/http`);

if (http.nginx_main?.workerProcesses === workers) {
  say(`nginx workers: ${WORKERS}, unchanged`);
} else {
  await api("PUT", `${base}/http`, {
    nginx_main: { ...(http.nginx_main ?? {}), workerProcesses: workers },
    nginx: http.nginx,
    waf_http: http.waf_http,
    waf: http.waf,
    raw: http.raw,
    raw_nginx: http.raw_nginx,
  });
  say(`nginx workers: ${WORKERS}`);
}

process.stdout.write(`port ${HTTP_PORT}, nginx workers ${WORKERS}\n`);
