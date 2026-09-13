/*
 * Рассылка: шаг установки после панели (install.sh).
 *
 * Свежая установка -- это база контроллера и пустой KV: ни одного поколения ни
 * в одном канале, кроме тех, что только что разослал шаг панели. Процессы при
 * этом живут на умолчаниях своих образов, и панель честно показывает каналы как
 * «не издавался» и «чужое». Шаг издаёт каждый несошедшийся канал пространства
 * default и ждёт отчётов получателей. Сошёлся -- ok; nobody -- канал без
 * получателя в этой установке (haproxy, vlai), ждать его нечего.
 *
 * Скрипт идёт внутри контейнера контроллера, как и шаг панели:
 *
 *     docker compose exec -T controller node --input-type=module -e "$(cat bootstrap/publish.mjs)"
 *
 * stdout -- одна строка итога для install.sh. Ход работы -- в stderr. Не
 * сошлось за отведённое время -- код выхода 1 и список того, что не сошлось.
 */

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
  throw new Error("нет пространства default");
}

const base = `/api/${space.uuid}`;
const { channels = [] } = await api("GET", `${base}/convergence`);

for (const channel of channels) {
  if (QUIET.has(channel.state)) {
    say(`уже сошёлся: ${channel.id} (${channel.state})`);
    continue;
  }

  await api("POST", `${base}/${channel.send}`, {});
  say(`разослан: ${channel.id} (был ${channel.state})`);
}

const deadline = Date.now() + WAIT_S * 1000;

for (;;) {
  const { channels: now = [] } = await api("GET", `${base}/convergence`);
  const pending = now.filter((channel) => !QUIET.has(channel.state));

  if (pending.length === 0) {
    const silent = now.filter((channel) => channel.state === "nobody").map((channel) => channel.id);
    const tail = silent.length > 0 ? `; без получателя: ${silent.join(", ")}` : "";
    process.stdout.write(`каналов ${now.length}, сошлись все${tail}\n`);
    break;
  }

  if (Date.now() > deadline) {
    say(`не сошлись за ${WAIT_S} с: ${pending.map((channel) => `${channel.id}=${channel.state}`).join(", ")}`);
    process.exit(1);
  }

  await new Promise((resolve) => setTimeout(resolve, 3000));
}
