// vlai step of install.sh, run inside the controller container when the vlai compose profile is on:
// adds the classifier to the inspector catalog. stdout: created or exists.

const API = `http://127.0.0.1:${process.env.CONTROLLER_PORT ?? "8080"}`;

const VLAI = {
  name: "vlai",
  subject: "waf.req.vlai",
  phases: ["request"],
  description: "Severity classifier: an ML model scores the description in the body.",
  log_level: "info",
  conf: "# inspector.conf: the local queue of the process\nqueue_max     8;\nqueue_full    drop;\nqueue_expand  off;\n",
};

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
const { inspectors = [] } = await api("GET", `${base}/inspectors`);

if (inspectors.some((row) => row.name === VLAI.name)) {
  process.stdout.write("exists");
} else {
  await api("POST", `${base}/inspectors`, VLAI);
  process.stdout.write("created");
}
