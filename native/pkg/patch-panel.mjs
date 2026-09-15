/*
 * Шаг панели для установки без Docker -- производная bootstrap/panel.mjs.
 *
 * В Docker узел ходит в контроллер и в форму входа по именам контейнеров через
 * resolver Docker. На одной машине это 127.0.0.1 со своими портами: resolver не
 * нужен, resolve у узлов пула -- тоже. Разница только в адресах, поэтому скрипт
 * не копируется, а собирается заменами. Замена, которая не нашла своё место ровно
 * один раз, роняет сборку: расхождение с шагом панели видно здесь, а не в панели.
 *
 *     node native/pkg/patch-panel.mjs bootstrap/panel.mjs > panel.mjs
 *
 * Окружение готового скрипта: PANEL_EDGE, PANEL_RESOLVER=none,
 * PANEL_CONTROLLER_HOST/PORT, PANEL_FORM_HOST/PORT, PANEL_BIND.
 */

import { readFileSync } from "node:fs";

const [source] = process.argv.slice(2);

if (source === undefined) {
  process.stderr.write("patch-panel: путь к bootstrap/panel.mjs\n");
  process.exit(2);
}

let text = readFileSync(source, "utf8");

const swaps = [
  [
    'const EDGE = "http://edge:8081";',
    'const EDGE = process.env.PANEL_EDGE ?? "http://edge:8081";',
  ],
  [
    'const RESOLVER = ["127.0.0.11", "valid=10s", "ipv6=off"];',
    'const RESOLVER = process.env.PANEL_RESOLVER === "none" ? null : ["127.0.0.11", "valid=10s", "ipv6=off"];',
  ],
  [
    'const CONTROLLER = { pool: "panel", host: "controller", port: 8080 };',
    'const CONTROLLER = { pool: "panel", host: process.env.PANEL_CONTROLLER_HOST ?? "controller", port: Number(process.env.PANEL_CONTROLLER_PORT ?? 8080) };',
  ],
  [
    'const FORM = { pool: "panel-login", host: "auth-http", port: 8080 };',
    'const FORM = { pool: "panel-login", host: process.env.PANEL_FORM_HOST ?? "auth-http", port: Number(process.env.PANEL_FORM_PORT ?? 8080) };',
  ],
  [
    "if ((httpNginx?.resolver ?? []).length === 0) {",
    'if (RESOLVER === null) {\n  say("resolver не нужен: узлы пулов панели -- адреса, а не имена");\n} else if ((httpNginx?.resolver ?? []).length === 0) {',
  ],
  [
    "const what = `пул ${target.pool} -> ${target.host}:${target.port} resolve`;",
    'const what = `пул ${target.pool} -> ${target.host}:${target.port}${RESOLVER === null ? "" : " resolve"}`;',
  ],
  [
    "peers: [{ host: target.host, port: target.port, weight: 1, resolve: true }],",
    "peers: [{ host: target.host, port: target.port, weight: 1, resolve: RESOLVER !== null }],",
  ],
  [
    "if (peer.resolve === true) {",
    "if ((peer.resolve === true) === (RESOLVER !== null)) {",
  ],
  [
    "peers: found.peers.map((item) => peerBody(item, item === peer ? true : item.resolve === true)),",
    "peers: found.peers.map((item) => peerBody(item, item === peer ? RESOLVER !== null : item.resolve === true)),",
  ],
  [
    "`порт panel (0.0.0.0:${PANEL_PORT})`",
    '`порт panel (${process.env.PANEL_BIND ?? "0.0.0.0"}:${PANEL_PORT})`',
  ],
  [
    '{ name: "panel", address: "0.0.0.0", port: PANEL_PORT, ssl: false, http2: false, proxy_protocol: false },',
    '{ name: "panel", address: process.env.PANEL_BIND ?? "0.0.0.0", port: PANEL_PORT, ssl: false, http2: false, proxy_protocol: false },',
  ],
];

const missed = [];

for (const [from, to] of swaps) {
  const count = text.split(from).length - 1;

  if (count !== 1) {
    missed.push(`${count} раз: ${from}`);
    continue;
  }

  text = text.replace(from, () => to);
}

if (missed.length > 0) {
  process.stderr.write(`patch-panel: bootstrap/panel.mjs разошёлся с заменами:\n${missed.join("\n")}\n`);
  process.exit(1);
}

process.stdout.write(
  `// Собрано native/pkg/patch-panel.mjs из bootstrap/panel.mjs: адреса без Docker.\n${text}`,
);
