/*
 * Панель за калиткой: шаг `panel` установки (install.sh).
 *
 * Людям панель отдаёт узел защиты: сервер panel на порту 8081 контейнера, на
 * нём калитка auth со списком panel_users. Сам контроллер опубликован только на
 * loopback хоста -- для install.sh, e2e и аварийного входа.
 *
 * Скрипт идёт внутри контейнера контроллера: там есть node, bcrypt и API на
 * 127.0.0.1, а машине установки не обещаны ни curl, ни python.
 *
 *     printf '%s' "$пароль" | docker compose exec -T -e PANEL_ADMIN=ensure controller \
 *         node --input-type=module -e "$(cat bootstrap/panel.mjs)"
 *
 * stdin -- пароль admin, может быть пустым. Нигде не хранится: в список уезжает
 * bcrypt, как у формы пользователя в панели.
 *
 * PANEL_ADMIN=ensure (установка): admin заводится в пустой список -- с
 * введённым паролем или сгенерированным; есть -- пароль меняется, только если
 * ввели другой. PANEL_ADMIN=reset (install.sh panel-password): пароль admin
 * меняется всегда, пустой -- генерируется.
 *
 * stdout -- одна строка для install.sh: created, updated, kept или
 * generated <пароль>. Ход работы -- в stderr.
 *
 * Заводится то, чего нет; то, что есть, не трогается, кроме того, без чего
 * панель не панель: пароля admin по просьбе, метки panel в профиле калитки,
 * журнала на путях, где его не задавали, и resolve у узлов её пулов. Рассылка --
 * только если что-то поменялось: она публикует заодно и черновики оператора в
 * тех же каналах.
 */

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

/*
 * Узел отдаёт панель в контроллер и в форму входа по именам контейнеров. Имена
 * резолвятся на лету -- resolve у узла пула и resolver Docker в http: пока
 * контейнера нет в DNS, `nginx -t` поколение не отвергает, и лежащий контроллер --
 * это 502 одной панели, а не узел без конфигурации. Агент упавший `nginx -t` не
 * повторяет.
 */
const RESOLVER = ["127.0.0.11", "valid=10s", "ipv6=off"];
const CONTROLLER = { pool: "panel", host: "controller", port: 8080 };
const FORM = { pool: "panel-login", host: "auth-http", port: 8080 };

/*
 * Прежняя раскладка шага: узел ходил пулом в свой внутренний сервер на
 * 127.0.0.1:18081, а тот -- в контейнеры. Пути панели переезжают на пулы выше,
 * сервер, его порт и пул снимаются.
 */
const LEGACY_PORT = 18081;

/*
 * Метка всех запросов к панели в аудите. Рядом с пользователем сессии она
 * отвечает на «кто что делал в панели» одним фильтром marker=panel. Ставит её
 * калитка на каждом своём событии: вошёл, аноним, битая сессия, чужая зона.
 */
const MARKER = "panel";
const MARKED = ["authenticated", "anonymous", "invalid", "forbidden"];

/*
 * Журнал панели. В запись аудита -- срез заголовков и аргументов: 8k на объект,
 * 1k на пару. В архив на сутки -- запрос целиком. Тела в capture калитки нет, и
 * в архив оно едет reload -- оригиналом, инспектор его не видит.
 *
 * Кука сессии и Authorization -- хешем, а не значением: живой токен в журнале --
 * ключ к чужой сессии, а хеш по-прежнему связывает запросы одной сессии. Пароль в
 * теле директивой не замаскировать, поэтому тело пути, куда пароль уходит
 * открытым текстом, в журнал не пишется вовсе (user-line ниже).
 */
const MASKS = ["request headers mask=cookie,authorization", "request args mask=password"];
const PREVIEW = ["request headers=8k/1k args=8k/1k", ...MASKS];
const JOURNAL = { preview: PREVIEW, archive: ["request headers args ttl=1d", ...MASKS] };
const JOURNAL_BODY = {
  preview: PREVIEW,
  archive: ["request headers args body ttl=1d", "request reload body", ...MASKS],
};

// Потолок тела на обычных путях панели: PEM и конверты сертификатов влезают
// (store -- до 2 МБ ciphertext, в JSON это около 2,8 МБ). Выгрузке гео -- свой путь.
const BODY = "4m";

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

if (MODE !== "ensure" && MODE !== "reset") {
  throw new Error(`PANEL_ADMIN: ждал ensure или reset, пришло ${JSON.stringify(MODE)}`);
}

let password = "";

for await (const chunk of process.stdin) {
  password += chunk;
}

// Пароль как есть: пробелы по краям -- тоже пароль. Срезается только перевод
// строки, если его дописал тот, кто подавал stdin.
password = password.replace(/\r?\n$/, "");

const { spaces } = await api("GET", "/api/spaces");
const space = spaces.find((row) => row.name === "default");

if (space === undefined) {
  throw new Error("нет пространства default");
}

const base = `/api/${space.uuid}`;

/* Настройки http: ручка принимает их только целиком. */
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

const entries = rows(
  await api("GET", `${base}/datasets/${users.uuid}/addresses`),
  "addresses",
);

// Строка пользователя: login:bcrypt[:группы[:store-uuid секрета TOTP]].
const current = entries.find((row) => row.address.split(":")[0].toLowerCase() === ADMIN);

/*
 * Хеш считает контроллер (/auth/user-line) -- та же цена и тот же формат, что у
 * формы пользователя в панели. Группы и ссылка на секрет TOTP прежней строки
 * переезжают в новую: смена пароля не должна снимать второй фактор.
 */
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
    /*
     * Список, где уже кто-то есть, -- решение оператора, даже если admin в нём
     * нет: вернуть его молча значило бы воскресить учётку, которую удалили.
     */
    say(`admin в ${USERS} нет, но список не пуст: решение оператора, не трогаю`);
  } else {
    admin = secret === "" ? "generated" : "created";
    secret = secret === "" ? generate() : secret;

    await api("POST", `${base}/datasets/${users.uuid}/addresses`, {
      address: await userLine(secret, null),
    });
    changed = true;
    say("заведено: пользователь admin");
  }
} else {
  const [, hash = ""] = current.address.split(":");
  const same = password !== "" && (await bcrypt.compare(password, hash));

  if (MODE === "reset" || (password !== "" && !same)) {
    admin = secret === "" ? "generated" : "updated";
    secret = secret === "" ? generate() : secret;

    // Сначала новая строка, потом удаление старой: сорвавшаяся смена не должна
    // оставить список без admin.
    await api("POST", `${base}/datasets/${users.uuid}/addresses`, {
      address: await userLine(secret, current.address),
    });
    await api("DELETE", `${base}/addresses/${current.uuid}`);
    changed = true;
    say("сменён: пароль admin");
  } else {
    say(password === "" ? "уже есть: admin, пароль прежний" : "уже есть: admin с этим паролем");
  }
}

/* --- resolver, пулы, порт, сервер --------------------------------------- */

const { nginx: httpNginx } = await api("GET", `${base}/http`);

if ((httpNginx?.resolver ?? []).length === 0) {
  await patchHttp((http) => ({ nginx: { ...(http.nginx ?? {}), resolver: RESOLVER } }));
  changed = true;
  say(`заведено: resolver ${RESOLVER.join(" ")} (DNS Docker)`);
} else {
  say(`уже есть: resolver ${httpNginx.resolver.join(" ")}`);
}

const pools = rows(await api("GET", `${base}/upstreams`), "upstreams");

const peerOf = (row, target) =>
  (row.peers ?? []).find((peer) => peer.host === target.host && peer.port === target.port);

/* Узел пула в теле PUT: ручка принимает пул узлов только целиком. */
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

/*
 * Пул узнаётся по узлу, а не по имени: имя правят в панели. Узлу без resolve
 * (пул заведён руками) он дописывается: без него поколение падает на `nginx -t`,
 * пока контейнера нет в DNS.
 */
async function pool(target) {
  const found = pools.find((row) => peerOf(row, target) !== undefined);
  const what = `пул ${target.pool} -> ${target.host}:${target.port} resolve`;

  if (found === undefined) {
    const row = await api("POST", `${base}/upstreams`, {
      name: target.pool,
      method: "round_robin",
      peers: [{ host: target.host, port: target.port, weight: 1, resolve: true }],
    });
    changed = true;
    say(`заведено: ${what}`);
    return row;
  }

  const peer = peerOf(found, target);

  if (peer.resolve === true) {
    say(`уже есть: ${what}`);
    return found;
  }

  const row = await api("PUT", `${base}/upstreams/${found.uuid}`, {
    peers: found.peers.map((item) => peerBody(item, item === peer ? true : item.resolve === true)),
  });
  changed = true;
  say(`обновлено: пул ${found.name} (resolve у ${target.host}:${target.port})`);
  return row;
}

const controllerPool = await pool(CONTROLLER);
const formPool = await pool(FORM);

// Пулы прежней раскладки: узел на внутренний сервер 127.0.0.1:18081.
const legacyPools = new Set(
  pools
    .filter((row) =>
      (row.peers ?? []).some((peer) => peer.host === "127.0.0.1" && peer.port === LEGACY_PORT),
    )
    .map((row) => row.uuid),
);

const ports = rows(await api("GET", `${base}/ports`), "ports");

const panelPort = await ensure(
  `порт panel (0.0.0.0:${PANEL_PORT})`,
  ports,
  (row) => row.port === PANEL_PORT,
  `${base}/ports`,
  { name: "panel", address: "0.0.0.0", port: PANEL_PORT, ssl: false, http2: false, proxy_protocol: false },
);

const servers = rows(await api("GET", `${base}/servers`), "servers");

// Кто какой порт слушает: сервер панели узнаётся по своему порту, а не по
// имени -- имя правят в панели.
const bound = new Map();

for (const row of servers) {
  for (const item of rows(await api("GET", `${base}/servers/${row.uuid}/ports`), "listens")) {
    if (!bound.has(item.port_id)) {
      bound.set(item.port_id, row);
    }
  }
}

/*
 * Сервер на своём порту -- default_server: имя, которым пришли (адрес машины,
 * её имя в сети), панели безразлично. server_name -- имя сервера, а не `_`:
 * карточка в панели берёт имя из него.
 */
async function server(name, listen) {
  const held = bound.get(listen.uuid);

  if (held !== undefined) {
    say(`уже есть: сервер ${name} (слушает ${listen.address}:${listen.port}, в панели «${held.name}»)`);
    return held;
  }

  const row = await ensure(
    `сервер ${name}`,
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
  say(`заведено: ${name} слушает ${listen.address}:${listen.port}`);

  return row;
}

const panel = await server("panel", panelPort);

/*
 * Корень `/` сервер получает сам, вместе с собой: builtin, return 404, удалить
 * и переадресовать его нельзя. Такой корень -- ещё не решение оператора, и шаг
 * его настраивает; корень, который уже правили, остаётся как есть.
 */
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

/*
 * Путь, у которого журнала нет вовсе, получает журнал панели: заведён он до
 * журнала, а не оператором без журнала -- оператор, снявший журнал, оставляет
 * `none`, а не пустоту.
 */
const unjournaled = (row) => row.waf?.archive === undefined && row.waf?.preview === undefined;

async function locations(srv, wanted) {
  const have = rows(await api("GET", `${base}/servers/${srv.uuid}/locations`), "locations");

  for (const { upgrade, ...loc } of wanted) {
    const what = `путь ${srv.name} ${loc.match === "exact" ? "= " : loc.match === "regex" ? "~ " : ""}${loc.path}`;
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
      say(`настроено: ${what} (корень сервера)`);
      continue;
    }

    let patch = found !== undefined && upgrade !== undefined ? upgrade(found) : null;

    // Путь прежней раскладки смотрит в пул внутреннего сервера: переезжает на свой.
    if (found !== undefined && legacyPools.has(found.upstream_id)) {
      patch = { ...(patch ?? {}), upstream_id: loc.upstream_id };
    }

    if (patch !== null) {
      await api("PUT", `${base}/locations/${found.uuid}`, {
        ...patch,
        uuid: found.uuid,
        server_id: srv.uuid,
      });
      changed = true;
      say(`обновлено: ${what} (${Object.keys(patch).join(", ")})`);
      continue;
    }

    await ensure(what, have, same, `${base}/servers/${srv.uuid}/locations`, body);
  }
}

/*
 * Форма входа -- до источника: источник сверяет свой адрес с путями сервера.
 * Заголовки -- стандартный набор: адрес клиента форма берёт из последнего
 * значения X-Forwarded-For, а его дописывает этот узел. Модуль на форме выключен:
 * пароль из формы не попадает ни в журнал, ни в архив.
 */
await locations(panel, [
  {
    match: "prefix",
    path: LOGIN,
    position: 10,
    upstream_id: formPool.uuid,
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

const marks = MARKED.map((on) => ({ on, do: "mark", marker: MARKER }));

const profile = await ensure(
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
      rules: marks,
    },
  },
);

/*
 * Метка обязательна: профилю, заведённому до неё, недостающие правила
 * дописываются. Свои правила оператора остаются на месте.
 */
const rules = profile.doc?.rules ?? [];
const missing = marks.filter(
  (mark) => !rules.some((rule) => rule.on === mark.on && rule.do === "mark" && rule.marker === MARKER),
);

if (missing.length > 0 && profile.doc !== undefined) {
  await api("PUT", `${base}/auth/profiles/${profile.uuid}`, {
    doc: { ...profile.doc, rules: [...rules, ...missing] },
  });
  changed = true;
  say(`дописано: метка ${MARKER} на событиях ${missing.map((mark) => mark.on).join(", ")}`);
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
    upstream_id: controllerPool.uuid,
    waf: { ...gated, ...JOURNAL },
    upgrade: (row) => (unjournaled(row) ? { waf: { ...row.waf, ...JOURNAL } } : null),
  },
  {
    /*
     * Выгрузка гео (POST /api/<пространство>/geo/import/<вид>): файлы до 64 МБ.
     * Модуль тело не читает (pass) и в журнал его не пишет, узел отдаёт его
     * потоком: буфер тел узла -- tmpfs на те же 64 МБ.
     */
    match: "regex",
    path: "^/api/[^/]+/geo/import/",
    position: 25,
    upstream_id: controllerPool.uuid,
    nginx: { proxyHeaders: "standard", clientMaxBodySize: "64m", proxyRequestBuffering: false },
    waf: { ...gated, ...JOURNAL, bodyLimit: "request 64m", bodyLimitPolicy: "pass" },
  },
  {
    // Пользователь панели заводится паролем в открытом виде: тело этого пути в журнал не пишется.
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
    upgrade: (row) => {
      const patch = {};

      if (unjournaled(row)) {
        patch.waf = { ...row.waf, ...JOURNAL_BODY, bodyLimit: `request ${BODY}` };
      }

      // Прежнее умолчание шага: поток до 64 МБ ради выгрузки гео. У неё теперь свой путь.
      if (row.nginx?.clientMaxBodySize === "64m" && row.nginx?.proxyRequestBuffering === false) {
        const { proxyRequestBuffering: _, ...nginx } = row.nginx;
        patch.nginx = { ...nginx, clientMaxBodySize: BODY };
      }

      return Object.keys(patch).length === 0 ? null : patch;
    },
  },
]);

/* --- прежняя раскладка -------------------------------------------------- */

/*
 * Внутренний сервер, его порт и пул больше не нужны. Снять их не удалось --
 * панель работает и без этого, поэтому это предупреждение, а не сорванная
 * установка.
 */
async function drop(what, path) {
  try {
    await api("DELETE", path);
    changed = true;
    say(`снято: ${what}`);
  } catch (err) {
    say(`оставлено: ${what} (${err.message})`);
  }
}

const legacyPort = ports.find((row) => row.port === LEGACY_PORT);
const legacyServer = legacyPort === undefined ? undefined : bound.get(legacyPort.uuid);

if (legacyServer !== undefined) {
  await drop(`внутренний сервер ${legacyServer.name}`, `${base}/servers/${legacyServer.uuid}`);
}

if (legacyPort !== undefined) {
  await drop(`порт ${legacyPort.name} (127.0.0.1:${LEGACY_PORT})`, `${base}/ports/${legacyPort.uuid}`);
}

for (const row of pools.filter((item) => legacyPools.has(item.uuid))) {
  await drop(`пул ${row.name}`, `${base}/upstreams/${row.uuid}`);
}

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

  // Пароль и метка работают, когда их применила калитка, а не когда их издали.
  await until("калитка применила профили и пользователей", 60, async () => {
    const { channels = [] } = await api("GET", `${base}/convergence`);
    const auth = channels.find((row) => row.id === "auth");

    return auth?.state === "ok" || `канал auth: ${auth?.state ?? "нет"}`;
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

  /*
   * redirect: manual обязателен: fetch по умолчанию идёт за 303 на форму и
   * получает её 200 -- открытой панель от этого не становится. Accept JSON --
   * ветка API: калитка отвечает на неё 401, а не уводит на форму.
   */
  const open = await fetch(`${EDGE}/api/spaces`, {
    redirect: "manual",
    headers: { accept: "application/json" },
  });

  if (open.status >= 200 && open.status < 300) {
    throw new Fatal(`панель открыта без входа: /api/spaces через узел ответил ${open.status} без сессии`);
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
process.stdout.write(admin === "generated" ? `generated ${secret}\n` : `${admin}\n`);
