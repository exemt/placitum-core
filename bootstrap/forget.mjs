// Run inside the controller container by install.sh: the containers the run removed leave the fleet
// at once, so the panel shows no silent members and publishing does not wait for them to expire.
//
// FORGET: node ids and container hostnames separated by spaces. stdout: how many members left.

const API = `http://127.0.0.1:${process.env.CONTROLLER_PORT ?? "8080"}`;
const names = (process.env.FORGET ?? "").split(/\s+/).filter((name) => name !== "");

if (names.length === 0) {
  process.stdout.write("0\n");
  process.exit(0);
}

const res = await fetch(`${API}/api/fleet/forget`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ names }),
});

if (!res.ok) {
  throw new Error(`POST /api/fleet/forget -> ${res.status} ${(await res.text()).slice(0, 200)}`);
}

const body = await res.json();
process.stdout.write(`${body.forgotten ?? 0}\n`);
