// Panel step of install.sh, run inside the controller container. stdin: admin password, may be empty.
// PANEL_ADMIN=ensure|reset. stdout: created, updated, kept or generated <password>; progress goes to stderr.

import { randomBytes } from "node:crypto";

import bcrypt from "bcryptjs";

const API = `http://127.0.0.1:${process.env.CONTROLLER_PORT ?? "8080"}`;
const EDGE = "http://edge:8081";
const MODE = process.env.PANEL_ADMIN ?? "ensure";

const PANEL_PORT = 8081;
const LOGIN = "/waf/panel-login";
const USERS = "panel_users";
const GATE = "auth-panel";
const ADMIN = "admin";

const RESOLVER = ["127.0.0.11", "valid=10s", "ipv6=off"];
const CONTROLLER = { pool: "panel", host: "controller", port: 8080 };
const FORM = { pool: "panel-login", host: "auth-http", port: 8080 };

const MARKER = "panel";
const MARKED = ["authenticated", "anonymous", "invalid", "forbidden"];

const MASKS = ["request headers mask=cookie,authorization", "request args mask=password"];
const PREVIEW = ["request headers=8k/1k args=8k/1k", ...MASKS];
const JOURNAL = { preview: PREVIEW, archive: ["request headers args ttl=1d", ...MASKS] };
const JOURNAL_BODY = {
  preview: PREVIEW,
  archive: ["request headers args body ttl=1d", "request reload body", ...MASKS],
};

const BODY = "4m";

class Fatal extends Error {}

const say = (line) => process.stderr.write(`${line}\n`);

let changed = false;

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

function rows(body, key) {
  return Array.isArray(body) ? body : (body?.[key] ?? []);
}

async function ensure(what, have, same, path, body) {
  const found = have.find(same);

  if (found !== undefined) {
    say(`exists: ${what}`);
    return found;
  }

  const row = await api("POST", path, body);
  changed = true;
  say(`created: ${what}`);
  return row;
}

async function until(what, seconds, check) {
  const deadline = Date.now() + seconds * 1000;
  let last = "";

  for (;;) {
    try {
      const result = await check();

      if (result === true) {
        return;
      }

      last = result;
    } catch (err) {
      if (err instanceof Fatal) {
        throw err;
      }

      last = err.message;
    }

    if (Date.now() > deadline) {
      throw new Error(`${what}: timed out after ${seconds} s (${last})`);
    }

    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
}

if (MODE !== "ensure" && MODE !== "reset") {
  throw new Error(`PANEL_ADMIN: expected ensure or reset, got ${JSON.stringify(MODE)}`);
}

let password = "";

for await (const chunk of process.stdin) {
  password += chunk;
}

password = password.replace(/\r?\n$/, "");

const { spaces } = await api("GET", "/api/spaces");
const space = spaces.find((row) => row.name === "default");

if (space === undefined) {
  throw new Error("space default not found");
}

const base = `/api/${space.uuid}`;

async function patchHttp(patch) {
  const http = await api("GET", `${base}/http`);

  await api("PUT", `${base}/http`, {
    nginx_main: http.nginx_main,
    nginx: http.nginx,
    waf_http: http.waf_http,
    waf: http.waf,
    raw: http.raw,
    raw_nginx: http.raw_nginx,
    ...patch(http),
  });
}

await ensure(
  "deny response auth_required (401)",
  rows(await api("GET", `${base}/deny-responses`), "deny_responses"),
  (row) => row.name === "auth_required",
  `${base}/deny-responses`,
  { name: "auth_required", type: "http", spec: { status: 401 } },
);

const datasets = rows(await api("GET", `${base}/datasets`), "datasets");

const users = await ensure(
  `list ${USERS}`,
  datasets,
  (row) => row.name === USERS,
  `${base}/datasets`,
  {
    name: USERS,
    description: "Panel users: login gate auth-panel, provider local",
    kind: "list",
    type: "string",
    mode: "internal",
  },
);

const entries = rows(
  await api("GET", `${base}/datasets/${users.uuid}/addresses`),
  "addresses",
);

const current = entries.find((row) => row.address.split(":")[0].toLowerCase() === ADMIN);

async function userLine(secret, previous) {
  const [, , groups = "", totp = ""] = (previous ?? "").split(":");

  const { line } = await api("POST", `${base}/auth/user-line`, {
    login: ADMIN,
    password: secret,
    groups: groups.split(",").filter((item) => item !== ""),
  });

  const [login, hash] = line.split(":");
  const tail = totp !== "" ? `:${groups}:${totp}` : groups !== "" ? `:${groups}` : "";

  return `${login}:${hash}${tail}`;
}

const generate = () => randomBytes(15).toString("base64url");

let admin = "kept";
let secret = password;

if (current === undefined) {
  if (MODE === "ensure" && entries.length > 0) {
    say(`no admin in ${USERS}, but the list is not empty: left as the operator set it`);
  } else {
    admin = secret === "" ? "generated" : "created";
    secret = secret === "" ? generate() : secret;

    await api("POST", `${base}/datasets/${users.uuid}/addresses`, {
      address: await userLine(secret, null),
    });
    changed = true;
    say("created: user admin");
  }
} else {
  const [, hash = ""] = current.address.split(":");
  const same = password !== "" && (await bcrypt.compare(password, hash));

  if (MODE === "reset" || (password !== "" && !same)) {
    admin = secret === "" ? "generated" : "updated";
    secret = secret === "" ? generate() : secret;

    await api("POST", `${base}/datasets/${users.uuid}/addresses`, {
      address: await userLine(secret, current.address),
    });
    // Delete the old line only after the new one is saved, so a failed change keeps admin.
    await api("DELETE", `${base}/addresses/${current.uuid}`);
    changed = true;
    say("changed: admin password");
  } else {
    say(password === "" ? "exists: admin, password unchanged" : "exists: admin with this password");
  }
}

const { nginx: httpNginx } = await api("GET", `${base}/http`);

if ((httpNginx?.resolver ?? []).length === 0) {
  await patchHttp((http) => ({ nginx: { ...(http.nginx ?? {}), resolver: RESOLVER } }));
  changed = true;
  say(`created: resolver ${RESOLVER.join(" ")} (Docker DNS)`);
} else {
  say(`exists: resolver ${httpNginx.resolver.join(" ")}`);
}

const pools = rows(await api("GET", `${base}/upstreams`), "upstreams");

const peerOf = (row, target) =>
  (row.peers ?? []).find((peer) => peer.host === target.host && peer.port === target.port);

const peerBody = (peer, resolve) => ({
  host: peer.host,
  port: peer.port,
  weight: peer.weight,
  max_fails: peer.max_fails,
  fail_timeout_ms: peer.fail_timeout_ms,
  backup: peer.backup,
  down: peer.down,
  resolve,
});

async function pool(target) {
  const found = pools.find((row) => peerOf(row, target) !== undefined);
  const what = `pool ${target.pool} -> ${target.host}:${target.port} resolve`;

  if (found === undefined) {
    const row = await api("POST", `${base}/upstreams`, {
      name: target.pool,
      method: "round_robin",
      peers: [{ host: target.host, port: target.port, weight: 1, resolve: true }],
    });
    changed = true;
    say(`created: ${what}`);
    return row;
  }

  const peer = peerOf(found, target);

  if (peer.resolve === true) {
    say(`exists: ${what}`);
    return found;
  }

  const row = await api("PUT", `${base}/upstreams/${found.uuid}`, {
    peers: found.peers.map((item) => peerBody(item, item === peer ? true : item.resolve === true)),
  });
  changed = true;
  say(`updated: pool ${found.name} (resolve on ${target.host}:${target.port})`);
  return row;
}

const controllerPool = await pool(CONTROLLER);
const formPool = await pool(FORM);

const ports = rows(await api("GET", `${base}/ports`), "ports");

const panelPort = await ensure(
  `port panel (0.0.0.0:${PANEL_PORT})`,
  ports,
  (row) => row.port === PANEL_PORT,
  `${base}/ports`,
  { name: "panel", address: "0.0.0.0", port: PANEL_PORT, ssl: false, http2: false, proxy_protocol: false },
);

const servers = rows(await api("GET", `${base}/servers`), "servers");

const bound = new Map();

for (const row of servers) {
  for (const item of rows(await api("GET", `${base}/servers/${row.uuid}/ports`), "listens")) {
    if (!bound.has(item.port_id)) {
      bound.set(item.port_id, row);
    }
  }
}

async function server(name, listen) {
  const held = bound.get(listen.uuid);

  if (held !== undefined) {
    say(`exists: server ${name} (listens on ${listen.address}:${listen.port}, named "${held.name}" in the panel)`);
    return held;
  }

  const row = await ensure(
    `server ${name}`,
    servers,
    (item) => item.name === name,
    `${base}/servers`,
    { name, server_names: [name], enabled: true },
  );

  await api("POST", `${base}/servers/${row.uuid}/ports`, {
    port_id: listen.uuid,
    default_server: true,
  });
  changed = true;
  say(`created: ${name} listens on ${listen.address}:${listen.port}`);

  return row;
}

const panel = await server("panel", panelPort);

function untouchedRoot(row) {
  return (
    row.match === "prefix" &&
    row.path === "/" &&
    row.handler === "return" &&
    row.return_status === 404 &&
    !row.upstream_id &&
    !row.raw &&
    Object.keys(row.waf ?? {}).length === 0 &&
    Object.keys(row.nginx ?? {}).length === 0
  );
}

async function locations(srv, wanted) {
  const have = rows(await api("GET", `${base}/servers/${srv.uuid}/locations`), "locations");

  for (const loc of wanted) {
    const what = `location ${srv.name} ${loc.match === "exact" ? "= " : loc.match === "regex" ? "~ " : ""}${loc.path}`;
    const body = {
      enabled: true,
      handler: "proxy",
      protocol: "http",
      upstream_uri: null,
      return_status: null,
      return_page: null,
      return_url: null,
      raw: false,
      raw_nginx: "",
      nginx: {},
      waf: {},
      ...loc,
    };
    const same = (row) => row.path === loc.path && row.match === loc.match;
    const found = have.find(same);

    if (found !== undefined && untouchedRoot(found)) {
      await api("PUT", `${base}/locations/${found.uuid}`, {
        ...body,
        uuid: found.uuid,
        server_id: srv.uuid,
      });
      changed = true;
      say(`configured: ${what} (server root)`);
      continue;
    }

    await ensure(what, have, same, `${base}/servers/${srv.uuid}/locations`, body);
  }
}

await locations(panel, [
  {
    match: "prefix",
    path: LOGIN,
    position: 10,
    upstream_id: formPool.uuid,
    nginx: { proxyHeaders: "standard" },
    waf: { enabled: false },
  },
  {
    match: "prefix",
    path: "/assets/",
    position: 11,
    upstream_id: controllerPool.uuid,
    nginx: { proxyHeaders: "standard" },
    waf: { enabled: false },
  },
  {
    match: "exact",
    path: "/favicon.svg",
    position: 12,
    upstream_id: controllerPool.uuid,
    nginx: { proxyHeaders: "standard" },
    waf: { enabled: false },
  },
  {
    match: "exact",
    path: "/favicon.ico",
    position: 13,
    handler: "return",
    return_status: 204,
    waf: { enabled: false },
  },
]);

const form = datasets.find((row) => row.name === "login_form" && row.kind === "content");

await ensure(
  "login source panel",
  rows(await api("GET", `${base}/auth/sources`), "sources"),
  (row) => row.name === "panel",
  `${base}/auth/sources`,
  {
    name: "panel",
    description: "Panel login: users from panel_users",
    server_id: panel.uuid,
    doc: {
      login: {
        uri: LOGIN,
        title: "Placitum panel",
        note: "Sign in to the Placitum control panel",
        page: form?.uuid ?? "",
      },
      provider: "local",
      providers: { local: { users: USERS } },
      session: { ttl_s: 8 * 3600, renew_after_s: 3600 },
    },
  },
);

const marks = MARKED.map((on) => ({ on, do: "mark", marker: MARKER }));

const profile = await ensure(
  "login gate profile panel",
  rows(await api("GET", `${base}/auth/profiles`), "profiles"),
  (row) => row.name === "panel",
  `${base}/auth/profiles`,
  {
    name: "panel",
    description: "Panel login gate: navigation without a session goes to the login form, API calls get 401",
    doc: {
      source: "panel",
      gate: {
        redirectMethods: ["GET", "HEAD"],
        redirectStatus: 303,
        denyResponse: "auth_required",
        htmlOnly: true,
        groups: [],
        forbiddenResponse: "auth_forbidden",
        inline: false,
      },
      trigger: { prior: [], reauthAfterS: 300 },
      rules: marks,
    },
  },
);

const rules = profile.doc?.rules ?? [];
const missing = marks.filter(
  (mark) => !rules.some((rule) => rule.on === mark.on && rule.do === "mark" && rule.marker === MARKER),
);

if (missing.length > 0 && profile.doc !== undefined) {
  await api("PUT", `${base}/auth/profiles/${profile.uuid}`, {
    doc: { ...profile.doc, rules: [...rules, ...missing] },
  });
  changed = true;
  say(`added: marker ${MARKER} on events ${missing.map((mark) => mark.on).join(", ")}`);
}

const { waf: httpWaf } = await api("GET", `${base}/http`);

if (httpWaf?.inspectors?.[GATE] === undefined) {
  await patchHttp((http) => ({
    waf: {
      ...(http.waf ?? {}),
      inspectors: { ...(http.waf?.inspectors ?? {}), [GATE]: { process: "auth", profile: "panel" } },
    },
  }));
  changed = true;
  say(`created: declaration ${GATE} (process auth, profile panel)`);
} else {
  say(`exists: declaration ${GATE}`);
}

const gated = {
  enabled: true,
  capture: ["request headers args"],
  localChecks: [],
  requestInspectors: [{ name: GATE, wave: 0 }],
  responseInspectors: "none",
  redirectAllow: [LOGIN],
  // No verdict means deny: the bus default is pass, and a NATS outage would open the panel.
  exception: ["request deny"],
};

await locations(panel, [
  {
    match: "exact",
    path: "/agent_health_socket",
    position: 20,
    protocol: "websocket",
    upstream_id: controllerPool.uuid,
    waf: { ...gated, ...JOURNAL },
  },
  {
    match: "regex",
    path: "^/api/[^/]+/geo/import/",
    position: 25,
    upstream_id: controllerPool.uuid,
    nginx: { proxyHeaders: "standard", clientMaxBodySize: "64m", proxyRequestBuffering: false },
    waf: { ...gated, ...JOURNAL, bodyLimit: "request 64m", bodyLimitPolicy: "pass" },
  },
  {
    match: "regex",
    path: "^/api/[^/]+/auth/user-line$",
    position: 26,
    upstream_id: controllerPool.uuid,
    nginx: { proxyHeaders: "standard" },
    waf: { ...gated, ...JOURNAL },
  },
  {
    match: "prefix",
    path: "/",
    position: 30,
    upstream_id: controllerPool.uuid,
    nginx: { proxyHeaders: "standard", clientMaxBodySize: BODY },
    waf: { ...gated, ...JOURNAL_BODY, bodyLimit: `request ${BODY}` },
  },
]);

async function publish() {
  await api("POST", `${base}/auth/send`, {});
  const sent = await api("POST", `${base}/config/send`, {});
  say(`published: login gate and nginx, generation ${sent.rev ?? "?"}`);

  await until("node applied the generation", 120, async () => {
    const { agents = [] } = await api("GET", "/api/fleet");

    if (agents.length === 0) {
      return "no nodes";
    }

    return (
      agents.every((a) => a.health?.config_hash === sent.config_hash && a.apply === "ok") ||
      agents.map((a) => `${a.health?.node_id}: ${a.apply}`).join(", ")
    );
  });

  await until("login gate applied profiles and users", 60, async () => {
    const { channels = [] } = await api("GET", `${base}/convergence`);
    const auth = channels.find((row) => row.id === "auth");

    return auth?.state === "ok" || `channel auth: ${auth?.state ?? "none"}`;
  });
}

async function probe() {
  const nav = await fetch(`${EDGE}/`, { redirect: "manual", headers: { accept: "text/html" } });
  const where = nav.headers.get("location") ?? "";

  if (nav.status !== 303 || !where.startsWith(LOGIN)) {
    return `GET / -> ${nav.status} ${where}`;
  }

  const ticket = nav.headers
    .getSetCookie()
    .map((cookie) => cookie.split(";")[0])
    .join("; ");
  const page = await fetch(new URL(where, EDGE), { headers: { accept: "text/html", cookie: ticket } });

  if (page.status !== 200) {
    return `GET ${where} -> ${page.status}`;
  }

  // redirect: manual, otherwise fetch follows the 303 to the login form and gets 200.
  const open = await fetch(`${EDGE}/api/spaces`, {
    redirect: "manual",
    headers: { accept: "application/json" },
  });

  if (open.status >= 200 && open.status < 300) {
    throw new Fatal(`panel is open without login: /api/spaces through the node returned ${open.status} without a session`);
  }

  return open.status === 401 || `GET /api/spaces -> ${open.status}`;
}

if (changed) {
  await publish();
}

try {
  await until("panel behind the login gate", changed ? 90 : 10, probe);
} catch (err) {
  if (changed || err instanceof Fatal) {
    throw err;
  }

  say(`panel does not respond (${err.message}): publishing again`);
  await publish();
  await until("panel behind the login gate", 90, probe);
}

say("panel behind the login gate: ok");
process.stdout.write(admin === "generated" ? `generated ${secret}\n` : `${admin}\n`);
