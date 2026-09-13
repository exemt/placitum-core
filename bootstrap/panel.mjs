/*
 * Панель за калиткой: шаг `panel` установки (install.sh).
 *
 * Людям панель отдаёт узел защиты: сервер panel на порту 8081 контейнера, на
 * нём калитка auth со списком panel_users. Сам контроллер опубликован только на
 * loopback хоста -- для install.sh, e2e и аварийного входа.
 *
 * Скрипт идёт внутри контейнера контроллера: там есть node и API на 127.0.0.1,
 * а машине установки не обещаны ни curl, ни python.
 *
 *     docker compose exec -T controller node --input-type=module \
 *         -e "$(cat bootstrap/panel.mjs)" < secrets/panel-admin.password
 *
 * stdin -- пароль admin: нужен, только если список пользователей пуст.
 * stdout -- одно слово для install.sh: created (admin заведён этим паролем) или
 * kept (пользователи уже были). Ход работы -- в stderr.
 *
 * Заводится то, чего нет; то, что есть, не трогается: повторный запуск ничего
 * не плодит и правок оператора не затирает. Рассылка -- только если что-то
 * заведено: она публикует заодно и черновики оператора в тех же каналах.
 */

const API = `http://127.0.0.1:${process.env.CONTROLLER_PORT ?? "8080"}`;
const EDGE = "http://edge:8081";

const PANEL_PORT = 8081;
const BACKEND_PORT = 18081;
const LOGIN = "/waf/panel-login";
const USERS = "panel_users";
const GATE = "auth-panel";

/* Ошибка, которую ожидание не повторяет: ждать тут нечего. */
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

/* Ручки отвечают то массивом, то объектом с массивом под своим ключом. */
function rows(body, key) {
  return Array.isArray(body) ? body : (body?.[key] ?? []);
}

async function ensure(what, have, same, path, body) {
  const found = have.find(same);

  if (found !== undefined) {
    say(`уже есть: ${what}`);
    return found;
  }

  const row = await api("POST", path, body);
  changed = true;
  say(`заведено: ${what}`);
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
      throw new Error(`${what}: не дождался за ${seconds} с (${last})`);
    }

    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
}

/*
 * Узел ходит в контроллер и форму входа не апстримом, а через свой внутренний
 * сервер на 127.0.0.1:18081, где адрес резолвится на лету. Имя в апстриме
 * резолвится при загрузке конфигурации: пока контейнера controller нет в DNS,
 * `nginx -t` отверг бы поколение целиком -- и без конфигурации остался бы весь
 * трафик узла, а агент упавший `nginx -t` не повторяет. Через resolver
 * лежащий контроллер -- это 502 одной панели.
 */
function passTo(target, extra = []) {
  return [
    "resolver 127.0.0.11 valid=10s ipv6=off;",
    `set $panel_target ${target};`,
    ...extra,
    "proxy_set_header Host $host;",
    // Адрес клиента проставил внешний сервер: передаём как есть, не дописывая.
    "proxy_set_header X-Forwarded-For $http_x_forwarded_for;",
    "proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;",
    "proxy_pass http://$panel_target;",
  ].join("\n");
}

let password = "";

for await (const chunk of process.stdin) {
  password += chunk;
}

password = password.trim();

const { spaces } = await api("GET", "/api/spaces");
const space = spaces.find((row) => row.name === "default");

if (space === undefined) {
  throw new Error("нет пространства default");
}

const base = `/api/${space.uuid}`;

/* --- запись отказа ------------------------------------------------------ */

/*
 * Ответ калитки без сессии. Поставка везёт только auth_forbidden: auth_required
 * заводят вместе с первой калиткой пространства, а у свежей установки первая --
 * панель.
 */
await ensure(
  "запись отказа auth_required (401)",
  rows(await api("GET", `${base}/deny-responses`), "deny_responses"),
  (row) => row.name === "auth_required",
  `${base}/deny-responses`,
  { name: "auth_required", type: "http", spec: { status: 401 } },
);

/* --- пользователи ------------------------------------------------------- */

const datasets = rows(await api("GET", `${base}/datasets`), "datasets");

const users = await ensure(
  `список ${USERS}`,
  datasets,
  (row) => row.name === USERS,
  `${base}/datasets`,
  {
    name: USERS,
    description: "Пользователи панели: калитка auth-panel, провайдер local",
    kind: "list",
    type: "string",
    mode: "internal",
  },
);

/*
 * admin заводится только в пустой список. Список, где уже кто-то есть, --
 * решение оператора, даже если admin в нём нет: вернуть его молча значило бы
 * воскресить учётку, которую удалили.
 */
let admin = "kept";

const entries = rows(
  await api("GET", `${base}/datasets/${users.uuid}/addresses`),
  "addresses",
);

if (entries.length === 0) {
  if (password === "") {
    throw new Error(`список ${USERS} пуст, а пароля admin на stdin нет`);
  }

  const { line } = await api("POST", `${base}/auth/user-line`, {
    login: "admin",
    password,
    groups: [],
  });

  await api("POST", `${base}/datasets/${users.uuid}/addresses`, { address: line });
  changed = true;
  admin = "created";
  say("заведено: пользователь admin");
} else {
  say(`уже есть: пользователи в ${USERS} (${entries.length})`);
}

/* --- апстрим, порты, серверы -------------------------------------------- */

const backend = await ensure(
  `апстрим panel-backend -> 127.0.0.1:${BACKEND_PORT}`,
  rows(await api("GET", `${base}/upstreams`), "upstreams"),
  (row) => row.name === "panel-backend",
  `${base}/upstreams`,
  {
    name: "panel-backend",
    method: "round_robin",
    peers: [{ host: "127.0.0.1", port: BACKEND_PORT, weight: 1 }],
  },
);

const ports = rows(await api("GET", `${base}/ports`), "ports");

function port(name, address, number) {
  return ensure(
    `порт ${name} (${address}:${number})`,
    ports,
    (row) => row.port === number,
    `${base}/ports`,
    { name, address, port: number, ssl: false, http2: false, proxy_protocol: false },
  );
}

const panelPort = await port("panel", "0.0.0.0", PANEL_PORT);
const backendPort = await port("panel-backend", "127.0.0.1", BACKEND_PORT);

const servers = rows(await api("GET", `${base}/servers`), "servers");

/*
 * Порт у каждого сервера свой, и сервер на нём -- default_server: имя, которым
 * пришли (адрес машины, её имя в сети), панели безразлично.
 */
async function server(name, listen, extra = {}) {
  const row = await ensure(
    `сервер ${name}`,
    servers,
    (item) => item.name === name,
    `${base}/servers`,
    { name, server_names: ["_"], enabled: true, ...extra },
  );

  const listens = rows(await api("GET", `${base}/servers/${row.uuid}/ports`), "listens");

  if (!listens.some((item) => item.port_id === listen.uuid)) {
    await api("POST", `${base}/servers/${row.uuid}/ports`, {
      port_id: listen.uuid,
      default_server: true,
    });
    changed = true;
    say(`заведено: ${name} слушает ${listen.address}:${listen.port}`);
  }

  return row;
}

const panel = await server("panel", panelPort);
const inner = await server("panel-backend", backendPort, { waf: { enabled: false } });

async function locations(srv, wanted) {
  const have = rows(await api("GET", `${base}/servers/${srv.uuid}/locations`), "locations");

  for (const loc of wanted) {
    await ensure(
      `путь ${srv.name} ${loc.match === "exact" ? "= " : ""}${loc.path}`,
      have,
      (row) => row.path === loc.path && row.match === loc.match,
      `${base}/servers/${srv.uuid}/locations`,
      {
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
      },
    );
  }
}

/* Внутренний сервер: только проводка до контейнеров, ни калитки, ни модуля. */
await locations(inner, [
  {
    match: "prefix",
    path: LOGIN,
    position: 10,
    handler: "static",
    raw: true,
    raw_nginx: passTo("auth-http:8080"),
  },
  {
    match: "exact",
    path: "/agent_health_socket",
    position: 20,
    handler: "static",
    raw: true,
    raw_nginx: passTo("controller:8080", [
      "proxy_http_version 1.1;",
      "proxy_read_timeout 1h;",
      "proxy_set_header Upgrade $http_upgrade;",
      'proxy_set_header Connection "upgrade";',
    ]),
  },
  {
    match: "prefix",
    path: "/",
    position: 30,
    handler: "static",
    raw: true,
    raw_nginx: passTo("controller:8080", [
      "client_max_body_size 64m;",
      "proxy_request_buffering off;",
    ]),
  },
]);

/*
 * Форма входа -- до источника: источник сверяет свой адрес с путями сервера.
 * Заголовки -- стандартный набор: адрес клиента форма берёт из последнего
 * значения X-Forwarded-For, а его дописывает этот узел.
 */
await locations(panel, [
  {
    match: "prefix",
    path: LOGIN,
    position: 10,
    upstream_id: backend.uuid,
    nginx: { proxyHeaders: "standard" },
    waf: { enabled: false },
  },
]);

/* --- калитка ------------------------------------------------------------ */

const form = datasets.find((row) => row.name === "login_form" && row.kind === "content");

await ensure(
  "источник входа panel",
  rows(await api("GET", `${base}/auth/sources`), "sources"),
  (row) => row.name === "panel",
  `${base}/auth/sources`,
  {
    name: "panel",
    description: "Вход в панель: пользователи panel_users",
    server_id: panel.uuid,
    doc: {
      login: {
        uri: LOGIN,
        title: "Панель Placitum",
        note: "Вход в панель управления контуром",
        page: form?.uuid ?? "",
      },
      provider: "local",
      providers: { local: { users: USERS } },
      session: { ttl_s: 8 * 3600, renew_after_s: 3600 },
    },
  },
);

await ensure(
  "профиль калитки panel",
  rows(await api("GET", `${base}/auth/profiles`), "profiles"),
  (row) => row.name === "panel",
  `${base}/auth/profiles`,
  {
    name: "panel",
    description: "Калитка панели: навигация без сессии -- на форму, API -- 401",
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
    },
  },
);

const http = await api("GET", `${base}/http`);
const declared = { ...(http.waf?.inspectors ?? {}) };

if (declared[GATE] === undefined) {
  declared[GATE] = { process: "auth", profile: "panel" };

  await api("PUT", `${base}/http`, {
    nginx_main: http.nginx_main,
    nginx: http.nginx,
    waf_http: http.waf_http,
    waf: { ...(http.waf ?? {}), inspectors: declared },
    raw: http.raw,
    raw_nginx: http.raw_nginx,
  });
  changed = true;
  say(`заведено: объявление ${GATE} (процесс auth, профиль panel)`);
} else {
  say(`уже есть: объявление ${GATE}`);
}

const gated = {
  enabled: true,
  capture: ["request headers args"],
  localChecks: [],
  requestInspectors: [{ name: GATE, wave: 0 }],
  responseInspectors: "none",
  redirectAllow: [LOGIN],
  /*
   * Нет вердикта -- отказ, по любой причине. Умолчание модуля для шины --
   * pass: лёг бы NATS, и панель открылась бы без пароля.
   */
  exception: ["request deny"],
};

await locations(panel, [
  {
    // Заголовки апгрейда и адрес клиента печатает пресет websocket-пути.
    match: "exact",
    path: "/agent_health_socket",
    position: 20,
    protocol: "websocket",
    upstream_id: backend.uuid,
    waf: gated,
  },
  {
    match: "prefix",
    path: "/",
    position: 30,
    upstream_id: backend.uuid,
    nginx: {
      proxyHeaders: "standard",
      // Потолок выгрузки гео у контроллера -- 64 МБ. Буфер тел узла -- tmpfs
      // на те же 64 МБ, поэтому тело идёт потоком, а не через буфер.
      clientMaxBodySize: "64m",
      proxyRequestBuffering: false,
    },
    waf: gated,
  },
]);

/* --- рассылка и проверка ------------------------------------------------ */

async function publish() {
  await api("POST", `${base}/auth/send`, {});
  const sent = await api("POST", `${base}/config/send`, {});
  say(`разослано: калитка и nginx, поколение ${sent.rev ?? "?"}`);

  await until("узел применил поколение", 120, async () => {
    const { agents = [] } = await api("GET", "/api/fleet");

    if (agents.length === 0) {
      return "нет нод";
    }

    return (
      agents.every((a) => a.health?.config_hash === sent.config_hash && a.apply === "ok") ||
      agents.map((a) => `${a.health?.node_id}: ${a.apply}`).join(", ")
    );
  });
}

/*
 * Проверка тем путём, которым пойдёт браузер: навигация без сессии уводится на
 * форму, форма отвечает, API без сессии -- 401. Последнее главное: панель,
 * открытая без входа, хуже панели, которая не открылась.
 */
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

  const open = await fetch(`${EDGE}/api/spaces`);

  if (open.status === 200) {
    throw new Fatal("панель открыта без входа: /api/spaces через узел ответил 200 без сессии");
  }

  return open.status === 401 || `GET /api/spaces -> ${open.status}`;
}

if (changed) {
  await publish();
}

try {
  await until("панель за калиткой", changed ? 90 : 10, probe);
} catch (err) {
  if (changed || err instanceof Fatal) {
    throw err;
  }

  /*
   * Объекты на месте, а панель не отвечает: прошлый запуск мог упасть до
   * рассылки. Рассылаем и смотрим ещё раз.
   */
  say(`панель не отвечает (${err.message}): рассылаю заново`);
  await publish();
  await until("панель за калиткой", 90, probe);
}

say("панель за калиткой: ok");
process.stdout.write(`${admin}\n`);
