// Builds the panel step for the installation without Docker from bootstrap/panel.mjs by exact swaps.
// A swap that does not match exactly once fails the build.
//
//     node native/pkg/patch-panel.mjs bootstrap/panel.mjs > panel.mjs

import { readFileSync } from "node:fs";

const [source] = process.argv.slice(2);

if (source === undefined) {
  process.stderr.write("usage: node native/pkg/patch-panel.mjs bootstrap/panel.mjs\n");
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
    'if (RESOLVER === null) {\n  say("resolver not needed: panel pool peers are addresses, not names");\n} else if ((httpNginx?.resolver ?? []).length === 0) {',
  ],
  [
    "const what = `pool ${target.pool} -> ${target.host}:${target.port} resolve`;",
    'const what = `pool ${target.pool} -> ${target.host}:${target.port}${RESOLVER === null ? "" : " resolve"}`;',
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
    "`port panel (0.0.0.0:${PANEL_PORT})`",
    '`port panel (${process.env.PANEL_BIND ?? "0.0.0.0"}:${PANEL_PORT})`',
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
    missed.push(`${count} times: ${from}`);
    continue;
  }

  text = text.replace(from, () => to);
}

if (missed.length > 0) {
  process.stderr.write(`patch-panel: bootstrap/panel.mjs does not match the swaps:\n${missed.join("\n")}\n`);
  process.exit(1);
}

process.stdout.write(
  `// Built by native/pkg/patch-panel.mjs from bootstrap/panel.mjs.\n${text}`,
);
