// Layout step of install.sh, run inside the controller container: inspectors in the catalog, nginx
// processes, the resolver, traffic and panel ports, the real client address and haproxy in front of
// several nodes. stdout: one line per change.
//
// LAYOUT_INSPECTORS: processes that run. LAYOUT_WORKERS: auto or a number. LAYOUT_NODES:
// "service:name:address" per node, the first node first. LAYOUT_NODE: container or host, where the
// single node runs: nginx on the host listens on the traffic and panel ports of the machine itself.
// LAYOUT_RESOLVER: the resolver of nginx. LAYOUT_PANEL: panel address and port on the machine.
// LAYOUT_BALANCER: container or host, where haproxy runs. LAYOUT_TRUST: the only address the nodes
// take PROXY protocol from. LAYOUT_BIND: traffic addresses on the host, empty for all. LAYOUT_PORTS:
// HTTP and HTTPS traffic ports. LAYOUT_STEP=catalog stops after the catalog.

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
const NODE_HOST = process.env.LAYOUT_NODE === "host";
const TRUST = process.env.LAYOUT_TRUST ?? "";
const BIND = (process.env.LAYOUT_BIND ?? "").split(" ").filter((addr) => addr !== "");
const [HTTP_PORT, HTTPS_PORT] = (process.env.LAYOUT_PORTS ?? "80 443").split(" ").map(Number);
const RESOLVER = (process.env.LAYOUT_RESOLVER ?? "127.0.0.11 valid=10s ipv6=off")
  .split(" ")
  .filter((word) => word !== "");
const [PANEL_BIND, PANEL_PORT] = (process.env.LAYOUT_PANEL ?? "0.0.0.0 8081").split(" ");

// With more than one node haproxy owns the traffic ports and speaks PROXY protocol to the nodes.
const PROXY = NODES.length > 1;

// The traffic ports of the node. In a container the node listens on 8080 and 8443, and Docker or
// haproxy maps the traffic ports to them; on the host nginx listens on the traffic ports themselves,
// on the one traffic address or on all of them.
const TRAFFIC = [
  { kind: "http", port: 8080, ssl: false, entry: HTTP_PORT },
  { kind: "https", port: 8443, ssl: true, entry: HTTPS_PORT },
].map((row) => ({
  ...row,
  name: `${row.kind}-${NODE_HOST ? row.entry : row.port}`,
  listen: NODE_HOST ? row.entry : row.port,
  address: NODE_HOST && BIND.length === 1 ? BIND[0] : "0.0.0.0",
}));

// The traffic row of a kind, whatever port it had on the previous run: the shipped http-8080, or
// the one this step renamed to the traffic port before.
function trafficRow(ports, want) {
  const own = ports.filter(
    (row) => Boolean(row.ssl) === want.ssl && new RegExp(`^${want.kind}-\\d+$`).test(row.name ?? ""),
  );

  return (
    own.find((row) => row.port === want.listen) ??
    own.find((row) => row.name === `${want.kind}-${want.port}`) ??
    own.find((row) => row.port === want.port) ??
    own[0]
  );
}

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

    // A controller from before the catalog knows no such call: the check waits for the update, and
    // the full step then refuses an inspector that is still called.
    if (res.status === 404 || (res.status === 400 && body.error === "invalid_uuid")) {
      if (process.env.LAYOUT_STEP === "catalog") {
        say("inspector catalog: the running controller is older than the installer, checked after the update");
        process.exit(0);
      }

      throw new Error(`PUT inspectors/installed -> ${res.status}: the controller is older than the installer`);
    }

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

// Docker DNS in a container; the nameservers of the machine for nginx on it.
if (!same(nginx.resolver ?? [], RESOLVER)) {
  nginx.resolver = RESOLVER;
  httpChanged = true;
  say(`resolver ${RESOLVER.join(" ")}`);
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
const where = NODE_HOST ? "on this machine" : "in the container";

for (const want of TRAFFIC) {
  const found = trafficRow(ports, want);

  if (found === undefined) {
    await api("POST", `${base}/ports`, {
      name: want.name,
      address: want.address,
      port: want.listen,
      ssl: want.ssl,
      http2: false,
      proxy_protocol: PROXY,
    });
    say(`port ${want.name} on ${want.address} ${where}${PROXY ? " with PROXY protocol" : ""}`);
    continue;
  }

  const next = {
    name: want.name,
    address: want.address,
    port: want.listen,
    ssl: found.ssl,
    http2: found.http2,
    proxy_protocol: PROXY,
  };
  const have = { name: found.name, address: found.address, port: found.port, ssl: found.ssl, http2: found.http2, proxy_protocol: found.proxy_protocol };

  if (!same(next, have)) {
    await api("PUT", `${base}/ports/${found.uuid}`, next);
    say(
      `port ${found.name} -> ${want.name} on ${want.address} ${where}` +
        (found.proxy_protocol !== PROXY ? `, PROXY protocol ${PROXY ? "on" : "off"}` : ""),
    );
  }
}

// The panel port: the panel step creates it; here it follows the node between the container, where
// Docker maps the panel address and port to 8081, and the machine, where nginx listens on them.
const panel = ports.find((row) => row.name === "panel");

if (panel !== undefined) {
  const want = NODE_HOST ? { address: PANEL_BIND, port: Number(PANEL_PORT) } : { address: "0.0.0.0", port: 8081 };

  if (panel.address !== want.address || panel.port !== want.port) {
    await api("PUT", `${base}/ports/${panel.uuid}`, {
      name: panel.name,
      address: want.address,
      port: want.port,
      ssl: panel.ssl,
      http2: panel.http2,
      proxy_protocol: panel.proxy_protocol,
    });
    say(`port panel on ${want.address}:${want.port} ${where}`);
  }
}

const haproxy = (await api("GET", `${base}/haproxy`)).settings ?? {};

if (PROXY) {
  // The entry points come from the ports of the panel. On the machine haproxy listens on the
  // traffic addresses and ports in front of the node ports; in a container it listens on the node
  // ports, and Docker maps the traffic ports to them. Nodes by their fixed addresses: haproxy on
  // the host has no Docker DNS, and the container does not need it.
  const entry = {};

  if (HOST && BIND.length > 0) {
    entry.addresses = BIND;
  }

  if (HOST) {
    const mapped = TRAFFIC.filter((row) => row.entry !== row.port).map((row) => [row.port, row.entry]);

    if (mapped.length > 0) {
      entry.ports = Object.fromEntries(mapped);
    }
  }

  const next = {
    ...haproxy,
    backend: { ...(haproxy.backend ?? {}), servers: NODES.map((node) => ({ name: node.name, host: node.address })) },
    docker_dns: false,
  };

  if (Object.keys(entry).length > 0) {
    next.entry = entry;
  } else {
    delete next.entry;
  }

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
} else if (haproxy.entry !== undefined || haproxy.backend?.servers !== undefined) {
  const next = { ...haproxy };
  delete next.entry;

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
