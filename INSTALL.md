# Installation

English · [Русский](INSTALL.ru.md)

What the machine needs, how the installation is configured and how to check that everything works.
A quick start and the repository layout are in [README.md](README.md).

## Requirements

| What | How much |
| --- | --- |
| Docker | 24 or newer, with BuildKit |
| Docker Compose | 2.20 or newer: the installation relies on `include` |
| CPU and memory | at least 2 cores and 4 GB, see [the measurements](image/README.md#sizing); 8 cores and 16 GB for heavy traffic; 4 GB more with `vlai` |
| Disk | 20 GB for images, build caches and data; the body archive grows over time |
| Network | during the build: GitHub, Docker Hub, quay.io, proxy.golang.org, npm, PyPI |

Images are built from sources on the same machine; nothing prebuilt is downloaded. The first build
takes several minutes: the nginx module is compiled against the nginx sources and the panel is
built. It is not stuck.

An offline installation is a separate topic: the build needs registry and module mirrors, set
through `GOPROXY` and the source variables.

## Installing

```sh
git clone https://github.com/exemt/placitum-core.git
cd placitum-core
./install.sh check
./install.sh install
```

`install` runs in steps and stops at the first failure:

1. **Checks**: Docker, Compose, `openssl`, disk space, the sources file.
2. **Settings**: on the first run `.env` is created from `.env.example` with new random passwords
   for PostgreSQL, ClickHouse and MinIO, and the installer asks on a terminal: node name, traffic
   ports, panel address and port. One more question opens nodes on this machine, nginx processes
   per node, copies of every inspector and Redis memory. Enter takes the value in brackets. The
   installer shows the plan and applies it after confirmation. CPU caps are lowered to the number
   of cores.
3. **Secrets**: the installation key, archive credentials and four signing keys. The key
   fingerprint goes to `secrets/contour-pin.json`; the controller container mounts it read-only,
   and the panel checks the key from the API against it.
4. **Infrastructure**: NATS, PostgreSQL, ClickHouse, both Redis instances and MinIO; JetStream
   streams and bucket rules are created on start.
5. **Schema**: on an empty database the controller installs the schema and the shipped data.
6. **Components**: images are built from `sources.env` and started.
7. **Panel**: the `panel` server on the node behind the `auth` login gate, and the `admin` user.
   The password is asked right after the settings, before the build (see [Panel](#panel)).
8. **Layout**: running inspectors in the catalog, nginx processes per node, traffic ports and, with
   several nodes, haproxy in front of them.
9. **Delivery**: all configuration channels are published to the processes, and the step waits for
   their reports. Otherwise a fresh installation runs on image defaults and the panel shows a
   mismatch.
10. **Summary**: container health in one line, the panel, API and traffic addresses.

Each step leaves one line with its result and time on screen. The full build and compose output
goes to `install.log` next to `install.sh`; on failure the installer shows its tail.

Without a terminal, or with `--defaults`, nothing is asked: a setting comes from the environment
if it is set there, otherwise from the default.

```sh
PLC_NODE_ID=edge-02 PLC_PANEL_BIND=10.0.0.5 PLC_PANEL_PASSWORD=… ./install.sh install --defaults
```

### Changing the settings

```sh
./install.sh reconfigure
```

The same questions with the current values in brackets. The installer shows the plan and what
changes, and after confirmation runs the installation again: containers whose settings changed are
recreated, nodes and copies beyond the new numbers are removed, and the configuration is published
again. Only images that the new answers need and the machine lacks are built, such as haproxy for
the second node. Data stays.

An inspector that routes or declarations still call is not turned off: the installer names the place
and stops before anything changes. Without confirmation, after a refusal or an interrupt, `.env`
stays as it was. Infrastructure passwords are not asked: they are set when the databases are
created.

### Several nodes on one machine

With `PLC_NODES` above one, nodes `edge-02` and further run next to `edge`; the installer writes their
definitions to `compose/nodes.yml` on every run. `balancer`, haproxy with its agent, takes the
traffic ports and passes TCP connections to every node with PROXY protocol v2. The nodes terminate
TLS themselves and see the real client address.

The installer turns PROXY protocol on for the ports `http-8080` and `https-8443` and trusts the client
address from it only from the installation network. A traffic port created later in the panel needs
PROXY protocol too. The panel stays on the first node. The haproxy configuration is on the panel
page Configuration → haproxy; its entry points belong to the installer.

## Configuration

### `.env`

| Variable | Default | Purpose |
| --- | --- | --- |
| `COMPOSE_PROJECT_NAME` | `placitum` | compose project name; one for both files, otherwise the installer loses track of its own infrastructure |
| `PLC_HTTP_PORT`, `PLC_HTTPS_PORT` | `80`, `443` | node ports on the host |
| `PLC_PANEL_BIND` | `127.0.0.1` | IPv4 address of the machine the node serves the panel on: `127.0.0.1` for the machine only, an internal interface address for its network, `0.0.0.0` for all addresses |
| `PLC_PANEL_PORT` | `8081` | panel port on that address |
| `PLC_CONTROLLER_PORT` | `8080` | controller API without login, on `127.0.0.1` only |
| `PLC_NODE_ID` | `edge-01` | node name in the panel, heartbeat and audit |
| `PLC_COOKIE_SECURE` | `off` | `on` sends login gate and captcha cookies over TLS only; keep `off` while the node serves plain HTTP |
| `POSTGRES_*`, `CLICKHOUSE_*`, `MINIO_ROOT_*` | user `waf`, random passwords | infrastructure credentials, written when `.env` is created; for external databases also change the addresses in `compose/waf.yml` |
| `PLC_REDIS_EXCHANGE_MB`, `PLC_REDIS_INTERNAL_MB` | `2560`, `512`; on 8 GB or less `640`, `320` | memory of the exchange Redis (request objects waiting for a verdict) and of the internal Redis (configuration, inspector state), MB; Redis keeps 80% for data |
| `PLC_NODES` | `1` | protection nodes on this machine; more than one puts haproxy in front of them |
| `PLC_NGINX_WORKERS` | `auto` | nginx processes per node, set in the panel by the installer |
| `PLC_COPIES_<INSPECTOR>` | `1`, `0` for `VLAI` | copies of each inspector; 0 turns it off, `AUTH` needs at least one for the panel login |
| `PLC_CPUS`, `PLC_CPUS_NATS`, `PLC_CPUS_KEEPER` | `2`, `6`, `4` | CPU cap per service, for NATS and for keeper; the installer lowers them to the number of cores |
| `PLC_CPUS_EDGE` | nginx processes | CPU cap of a node |
| `NGINX_VERSION` | `1.28.0` | nginx version for the module and the base image; change both together |

### `sources.env`

Where each component comes from: a git URL with a branch or tag, or a path on disk. This file is
the version of the installation. `#rc_1.0` is the release candidate; production installations use
tags. Build contexts have no built-in defaults: a component without a line in `sources.env` does
not build.

### Secrets

`secrets/` is not in git. The installation key (RSA-4096) is available to the node agent and
`crypto`; the controller gets the public half. Signing keys: `auth.hmac` and `auth-app.hmac` for
the login gate, `captcha.hmac` for captcha, `cookie.hmac` for the cookie inspector; they are not
shared. Archive credentials are a file in the AWS profile format. The panel `admin` password is not
in `secrets/`: only its bcrypt hash goes to the user list.

Reissuing the installation key (`bootstrap/secrets.sh --force`) resets trust: certificates uploaded
through the panel can no longer be decrypted. Reissuing a signing key logs out everyone it signed
and does nothing else.

## What runs

Eight infrastructure services and Placitum itself: the protection node, the controller with the
panel, logger and search, `crypto`, `geo`, `keeper`, nine inspectors (`ip`, `modsec`, `json`,
`counter`, `action`, `rewrite`, `cookie`, `auth` with the login form, `captcha` with the widget) and
three monitoring sidecars. Each inspector runs in `PLC_COPIES_<INSPECTOR>` copies; an inspector with
no copies does not run, and neither the panel nor routes see it. The text classifier `vlai` is off
by default: with `PLC_COPIES_VLAI=1`, `./install.sh reconfigure` builds and starts it.

Only the node is exposed: traffic (`PLC_HTTP_PORT`) and the panel (`PLC_PANEL_BIND`,
`PLC_PANEL_PORT`). With several nodes the traffic ports belong to `balancer`. The controller is
published on `127.0.0.1` only. Login forms, the captcha widget, search and `crypto` stay inside the
network: only the node and the controller talk to them.

## After installation

1. Open the panel at `http://127.0.0.1:8081` (or the address from `PLC_PANEL_BIND`) and sign in as
   `admin` with the password from the installation. There is one space, `default`, the inspector
   catalog, the shipped profiles and one server, the panel itself (`panel`). There are no other
   servers or routes: the operator creates them.
2. Create the first route: a server bound to the `http-8080` port (it is shipped: the node listens
   on 8080 inside the container, which is `PLC_HTTP_PORT` outside), a location, an upstream and
   inspectors on the route. An inspector called by the route must be declared on the space (space
   page, inspectors), otherwise the build fails with `undeclared_inspector`. WAF on a server or
   location is enabled explicitly with the `waf` setting of the route: it is off by default, and
   without it the module silently skips a route with inspectors. Publish the configuration: the
   node applies the generation with `nginx -s reload` and reports back.
3. Send a request through the node: `curl -i http://<host>/…` returns the upstream response, and a
   few seconds later the panel log shows an entry with the verdict.
4. The geo catalog (countries and ASN) is loaded separately: the MaxMind export has its own license
   and is not part of the images. Without it, country rules deny with an error code; everything
   else works.

## Checking

```sh
./install.sh status                                                          # services
docker compose --env-file .env --env-file sources.env -f compose/waf.yml ps
curl -fsS http://127.0.0.1:8080/healthz                                      # controller
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/api/spaces   # panel without login: 401
docker compose exec -T nats-box nats stream ls                               # WAF_AUDIT and WAF_LOG streams
```

A healthy installation: every service with a healthcheck is `healthy`, the others write a presence
frame to the log every four seconds. The panel status page shows the same in a readable form.

## Panel

The panel is served by the protection node, not by the controller: the `panel` server on port 8081
of the container, behind the `auth` login gate. The installer's panel step (`bootstrap/panel.mjs`)
sets it up through the API from inside the controller container. Running `./install.sh panel` again
creates only what is missing and keeps operator changes; `admin` is created only when the user list
is empty. The same run repairs the panel if its server, location or pool was deleted.

The `admin` password is asked right after the settings, before the build, twice and without echo. It is
not stored anywhere: only its bcrypt hash goes to the user list. Press Enter on the first
installation and the panel step generates a password and shows it once; on later runs the password
stays the same. Without a terminal the password comes from `PLC_PANEL_PASSWORD` in the environment.
To change the password and lift the login lockout:

```sh
./install.sh panel-password
```

Every request through the panel login gate is marked `panel` in the audit, next to the session
user: filter by `marker=panel` to see who did what in the panel. The audit keeps header and argument
slices of panel requests, and the archive keeps full requests for a day; the session cookie,
`Authorization` and the `password` argument are stored as hashes. Bodies are not kept for the geo
upload and for user creation.

`PLC_PANEL_BIND` decides where the panel listens. Docker publishes a port on an address, not an
interface, and the address must exist on the machine; otherwise the node does not start, and
traffic stops with it. `./install.sh check` verifies this. The host firewall is not a boundary
here: Docker routes published ports around UFW. Anything wider than loopback should be served over
TLS, otherwise the password travels in plain text.

The controller without login listens on `127.0.0.1:8080` only (`PLC_CONTROLLER_PORT`): its API is
for `install.sh` and for emergency access when the node or the login gate is down. From another
machine, use a tunnel:

```sh
ssh -L 8080:127.0.0.1:8080 <host>
```

Never proxy this port: a host nginx or any reverse proxy in front of `127.0.0.1:8080` exposes the
API without login again. If you need a proxy, put it in front of the panel port (`PLC_PANEL_PORT`)
and make it pass the browser's `Host` (`proxy_set_header Host $host;` in nginx): the controller
refuses a change whose `Origin` names another host than `Host` does, and answers
`403 cross_origin`.

A panel session lives 8 hours, is renewed silently and ends for good 24 hours after sign-in
(`session.max_ttl_s` of the `panel` source). A user removed from `panel_users`, or one whose
password was changed, is no longer renewed: the session ends when the current token does, 8 hours
(`session.ttl_s`) after that at the latest.

Do not touch these without emergency access at hand: the login gate on `/` and
`/agent_health_socket` of the `panel` server, the `panel` source and profile, the last user in
`panel_users`. Removing the login gate from `/` opens the panel without a password.

## Infrastructure ports

By default PostgreSQL, Redis, NATS, ClickHouse and MinIO are not reachable from outside: they live
in the compose network, and only the node and the panel are exposed. To reach them from the machine
itself (`psql`, `clickhouse-client`, the MinIO console), set `PLC_INFRA_PORTS=loopback` in `.env`
and run `./install.sh install` again: the ports appear on 127.0.0.1. They are never published on
0.0.0.0.

## Build version

`install.sh` takes the version from the core tag (`dev` without a tag) and the revision from its
commit and passes both to every build. They show up in image labels, in the `build` line at the
start of every process (`docker compose logs keeper | grep build`) and in the presence frame on the
status page. To set them by hand, use `PLC_VERSION` and `PLC_REVISION` in `.env`.

## Upgrading

Build new images and restart in order: infrastructure, inspectors, controller, node. The PostgreSQL
schema is not upgraded on a live database: if a new version changes it, install again on an empty
volume. There is no single upgrade command yet.

## Pitfalls

- **Ports 80 and 443 are taken** by another service: the installation fails at the node. Give other
  ports when the installer asks, or later with `./install.sh reconfigure`.
- **The node name lives in two places**: `PLC_NODE_ID` in `.env` and `waf_node_id` in
  `config/edge/node.conf`. `install.sh` keeps them in sync; if you edit by hand, edit both.
- **Do not change `COMPOSE_PROJECT_NAME` on a running installation**: a new name means a new
  project, and old containers and volumes stay under the old one.
- **Windows host (Docker Desktop)**: the bake builder does not understand git source URLs on Windows
  (`failed to evaluate path "https://…git#rc_1.0"`). The installation targets Linux; on Windows set
  `COMPOSE_BAKE=false` in the environment before `install`.
- **A secret was edited by hand and a service fails with `permission denied`**: processes in the
  images run as their own users and read the secret file through the mount as is. Files in
  `secrets/` are `0644`, the directory is `0700`; `sh bootstrap/secrets.sh` resets the modes without
  reissuing anything.
