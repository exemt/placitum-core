// Layout step of install.sh, run inside the controller container: inspectors in the catalog, nginx
// processes, traffic ports, the real client address and haproxy in front of several nodes. stdout:
// one line per change.
//
// LAYOUT_INSPECTORS: processes that run. LAYOUT_WORKERS: auto or a number. LAYOUT_NODES:
// "service:name" per node, the first node first. LAYOUT_STEP=catalog stops after the catalog.

import { networkInterfaces } from "node:os";

const API = `http://127.0.0.1:${process.env.CONTROLLER_PORT ?? "8080"}`;
const INSPECTORS = (process.env.LAYOUT_INSPECTORS ?? "").split(" ").filter((name) => name !== "");
const WORKERS = process.env.LAYOUT_WORKERS ?? "auto";
const NODES = (process.env.LAYOUT_NODES ?? "edge:edge-01")
  .split(" ")
  .filter((row) => row !== "")
  .map((row) => {
    const [host, name] = row.split(":");
    return { host, name };
  });

// With more than one node haproxy owns the traffic ports and speaks PROXY protocol to the nodes.
const PROXY = NODES.length > 1;

const TRAFFIC = [
  { name: "http-8080", port: 8080, ssl: false, frontend: "http" },
  { name: "https-8443", port: 8443, ssl: true, frontend: "https" },
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

// The network of this container: only haproxy inside it may tell the nodes a client address.
function ownSubnet() {
  for (const rows of Object.values(networkInterfaces())) {
    for (const row of rows ?? []) {
      if (row.family !== "IPv4" || row.internal || row.cidr === null) {
        continue;
      }

      const [addr, bits] = row.cidr.split("/");
      const mask = Number(bits) === 0 ? 0 : (~0 << (32 - Number(bits))) >>> 0;
      const ip = addr.split(".").reduce((n, part) => n * 256 + Number(part), 0);
      const net = (ip & mask) >>> 0;

      return `${[24, 16, 8, 0].map((shift) => (net >>> shift) & 255).join(".")}/${bits}`;
    }
  }

  throw new Error("no IPv4 address in the controller container");
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
  const from = [ownSubnet()];

  if (nginx.realIpHeader !== "proxy_protocol" || JSON.stringify(nginx.realIpFrom) !== JSON.stringify(from)) {
    nginx.realIpHeader = "proxy_protocol";
    nginx.realIpFrom = from;
    httpChanged = true;
    say(`client address from PROXY protocol, trusted from ${from[0]}`);
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
  const next = {
    ...haproxy,
    frontends: TRAFFIC.map((row) => ({
      name: row.frontend,
      port: row.port,
      mode: "tcp",
      send_proxy: true,
    })),
    backend: { ...(haproxy.backend ?? {}), servers: NODES.map((node) => ({ name: node.name, host: node.host })) },
    docker_dns: true,
  };

  if (JSON.stringify(next.frontends) !== JSON.stringify(haproxy.frontends) ||
    JSON.stringify(next.backend.servers) !== JSON.stringify(haproxy.backend?.servers)) {
    await api("PUT", `${base}/haproxy`, next);
    say(`haproxy: ${NODES.length} nodes behind ports 8080 and 8443`);
  }
} else if (haproxy.frontends !== undefined) {
  const next = { ...haproxy };
  delete next.frontends;

  if (next.backend !== undefined) {
    next.backend = { ...next.backend };
    delete next.backend.servers;
  }

  await api("PUT", `${base}/haproxy`, next);
  say("haproxy: no nodes behind it");
}
