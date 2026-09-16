// Publish step of install.sh, run inside the controller container: sends every channel that has not
// converged and waits for the reports. stdout: one summary line; exits 1 on timeout.

const API = `http://127.0.0.1:${process.env.CONTROLLER_PORT ?? "8080"}`;
const WAIT_S = 120;
const QUIET = new Set(["ok", "nobody"]);

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

const { spaces } = await api("GET", "/api/spaces");
const space = spaces.find((row) => row.name === "default");

if (space === undefined) {
  throw new Error("space default not found");
}

const base = `/api/${space.uuid}`;
const { channels = [] } = await api("GET", `${base}/convergence`);

for (const channel of channels) {
  if (QUIET.has(channel.state)) {
    say(`already converged: ${channel.id} (${channel.state})`);
    continue;
  }

  await api("POST", `${base}/${channel.send}`, {});
  say(`published: ${channel.id} (was ${channel.state})`);
}

const deadline = Date.now() + WAIT_S * 1000;

for (;;) {
  const { channels: now = [] } = await api("GET", `${base}/convergence`);
  const pending = now.filter((channel) => !QUIET.has(channel.state));

  if (pending.length === 0) {
    const silent = now.filter((channel) => channel.state === "nobody").map((channel) => channel.id);
    const tail = silent.length > 0 ? `; no receiver: ${silent.join(", ")}` : "";
    process.stdout.write(`channels: ${now.length}, all converged${tail}\n`);
    break;
  }

  if (Date.now() > deadline) {
    say(`not converged in ${WAIT_S} s: ${pending.map((channel) => `${channel.id}=${channel.state}`).join(", ")}`);
    process.exit(1);
  }

  await new Promise((resolve) => setTimeout(resolve, 3000));
}
