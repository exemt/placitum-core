// Layout step of install.sh, run inside the controller container: inspectors in the catalog, nginx
// processes, traffic ports, the real client address and haproxy in front of several nodes. stdout:
// one line per change.
//
// LAYOUT_INSPECTORS: processes that run. LAYOUT_WORKERS: auto or a number. LAYOUT_NODES:
// "service:name:address" per node, the first node first. LAYOUT_BALANCER: container or host, where
// haproxy runs. LAYOUT_TRUST: the only address the nodes take PROXY protocol from. LAYOUT_BIND:
// traffic addresses of haproxy on the host, empty for all. LAYOUT_PORTS: HTTP and HTTPS traffic
// ports. LAYOUT_STEP=catalog stops after the catalog.

const API = `http://127.0.0.1:${process.env.CONTROLLER_PORT ?? "8080"}`;
const INSPECTORS = (process.env.LAYOUT_INSPECTORS ?? "").split(" ").filter((name) => name !== "");
const WORKERS = process.env.LAYOUT_WORKERS ?? "auto";
const NODES = (process.env.LAYOUT_NODES ?? "edge:edge-01")
  .split(" ")
  .filter((row) => row !== "")
  .map((row) => {
    const [service, name, address] = row.split(":");
    return { service, name, address: address ?? service };
  });
const HOST = process.env.LAYOUT_BALANCER === "host";
const TRUST = process.env.LAYOUT_TRUST ?? "";
const BIND = (process.env.LAYOUT_BIND ?? "").split(" ").filter((addr) => addr !== "");
const [HTTP_PORT, HTTPS_PORT] = (process.env.LAYOUT_PORTS ?? "80 443").split(" ").map(Number);

// With more than one node haproxy owns the traffic ports and speaks PROXY protocol to the nodes.
const PROXY = NODES.length > 1;

// Node ports; haproxy in a container listens on the same ports, haproxy on the host on the traffic
// ports themselves.
const TRAFFIC = [
  { name: "http-8080", port: 8080, ssl: false, frontend: "http", entry: HTTP_PORT },
  { name: "https-8443", port: 8443, ssl: true, frontend: "https", entry: HTTPS_PORT },
];

const say = (line) => process.stdout.write(`${line}\n`);

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

// JSON with sorted keys: the API answers in its own key order.
function canon(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canon).join(",")}]`;
  }

  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .filter((key) => value[key] !== undefined)
      .map((key) => `${JSON.stringify(key)}:${canon(value[key])}`)
      .join(",")}}`;
  }

  return JSON.stringify(value);
}

const same = (a, b) => canon(a) === canon(b);

if (PROXY && TRUST === "") {
  throw new Error("LAYOUT_TRUST is empty: the nodes would take PROXY protocol from nobody");
}

const { spaces } = await api("GET", "/api/spaces");
const space = spaces.find((row) => row.name === "default");

if (space === undefined) {
  throw new Error("space default not found");
}

const base = `/api/${space.uuid}`;

// Catalog first: a process that routes still call is refused before its containers stop.
if (INSPECTORS.length > 0) {
  const running = ((await api("GET", `${base}/inspectors`)).inspectors ?? []).map((row) => row.name);
  const want = [...INSPECTORS].sort();

  if (JSON.stringify([...running].sort()) !== JSON.stringify(want)) {
    const res = await fetch(`${API}${base}/inspectors/installed`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ names: want }),
    });
    const body = await res.json().catch(() => ({}));

    if (res.status === 409) {
      const at = (body.uses ?? []).map((use) => use.at).join(", ");
      throw new Error(`${body.name} is still called from ${at}: remove it there or keep its copies above zero`);
    }

    if (!res.ok) {
      throw new Error(`PUT inspectors/installed -> ${res.status} ${JSON.stringify(body)}`);
    }

    say(`inspectors: ${want.join(" ")}`);
  }
}

if (process.env.LAYOUT_STEP === "catalog") {
  process.exit(0);
}

const http = await api("GET", `${base}/http`);
const workers = WORKERS === "auto" ? "auto" : Number(WORKERS);
const nginxMain = { ...(http.nginx_main ?? {}) };
const nginx = { ...(http.nginx ?? {}) };
let httpChanged = false;

if (nginxMain.workerProcesses !== workers) {
  nginxMain.workerProcesses = workers;
  httpChanged = true;
  say(`nginx processes per node: ${workers}`);
}

if (PROXY) {
  const from = [`${TRUST}/32`];

  if (nginx.realIpHeader !== "proxy_protocol" || !same(nginx.realIpFrom, from)) {
    nginx.realIpHeader = "proxy_protocol";
    nginx.realIpFrom = from;
    httpChanged = true;
    say(`client address from PROXY protocol, trusted from ${TRUST} only`);
  }
} else if (nginx.realIpHeader === "proxy_protocol") {
  delete nginx.realIpHeader;
  delete nginx.realIpFrom;
  httpChanged = true;
  say("client address from the connection");
}

if (httpChanged) {
  await api("PUT", `${base}/http`, {
    nginx_main: nginxMain,
    nginx,
    waf_http: http.waf_http,
    waf: http.waf,
    raw: http.raw,
    raw_nginx: http.raw_nginx,
  });
}

const ports = (await api("GET", `${base}/ports`)).ports ?? [];

for (const want of TRAFFIC) {
  const found = ports.find((row) => row.port === want.port);

  if (found === undefined) {
    await api("POST", `${base}/ports`, {
      name: want.name,
      address: "0.0.0.0",
      port: want.port,
      ssl: want.ssl,
      http2: false,
      proxy_protocol: PROXY,
    });
    say(`port ${want.name}${PROXY ? " with PROXY protocol" : ""}`);
    continue;
  }

  if (found.proxy_protocol !== PROXY) {
    await api("PUT", `${base}/ports/${found.uuid}`, {
      name: found.name,
      address: found.address,
      port: found.port,
      ssl: found.ssl,
      http2: found.http2,
      proxy_protocol: PROXY,
    });
    say(`port ${found.name}: PROXY protocol ${PROXY ? "on" : "off"}`);
  }
}

const haproxy = (await api("GET", `${base}/haproxy`)).settings ?? {};

if (PROXY) {
  // Nodes by their fixed addresses: haproxy on the host has no Docker DNS, and the container does
  // not need it.
  const next = {
    ...haproxy,
    frontends: TRAFFIC.map((row) => ({
      name: row.frontend,
      port: HOST ? row.entry : row.port,
      mode: "tcp",
      ...(HOST ? { server_port: row.port } : {}),
      send_proxy: true,
      ...(HOST && BIND.length > 0 ? { addresses: BIND } : {}),
    })),
    backend: { ...(haproxy.backend ?? {}), servers: NODES.map((node) => ({ name: node.name, host: node.address })) },
    docker_dns: false,
  };

  // The stats page of haproxy on the host would listen on every address of the machine.
  if (HOST) {
    next.stats = { ...(haproxy.stats ?? {}), enabled: false };
  }

  if (!same(next, haproxy)) {
    await api("PUT", `${base}/haproxy`, next);
    say(`haproxy ${HOST ? "on this machine" : "in a container"}: ${NODES.length} nodes behind ports ${
      HOST ? `${HTTP_PORT} and ${HTTPS_PORT}` : "8080 and 8443"
    }`);
  }

  // The controller holds the configuration before haproxy on the host starts and reads it.
  await api("POST", `${base}/haproxy/send`, {});
} else if (haproxy.frontends !== undefined) {
  const next = { ...haproxy };
  delete next.frontends;

  if (next.backend !== undefined) {
    next.backend = { ...next.backend };
    delete next.backend.servers;
  }

  if (next.docker_dns === false) {
    delete next.docker_dns;
  }

  if (next.stats?.enabled === false) {
    next.stats = { ...next.stats };
    delete next.stats.enabled;

    if (Object.keys(next.stats).length === 0) {
      delete next.stats;
    }
  }

  await api("PUT", `${base}/haproxy`, next);
  say("haproxy: no nodes behind it");
}
