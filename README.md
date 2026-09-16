# Placitum core

English · [Русский](README.ru.md)

This is where Placitum, a firewall for web applications and APIs, is installed from.

The repository has everything needed to install it on your server: the `install.sh` script, compose
files, infrastructure configs and initial setup. The components themselves (the nginx node, the
controller with its panel, the inspectors) live in separate repositories. The installer downloads
their sources and builds the images right on your machine; there are no prebuilt images yet.

Detailed instructions are in [INSTALL.md](INSTALL.md).

## Requirements

- Linux, Docker 24+ and Docker Compose 2.20+
- 8 cores and 16 GB of RAM, 4 GB more with the `vlai` text classifier
- 20 GB of free disk space
- `openssl`
- Internet access during the build: GitHub, Docker Hub, quay.io, proxy.golang.org, npm, PyPI

## Installation

```sh
git clone https://github.com/exemt/placitum-core.git
cd placitum-core
./install.sh check      # check the machine without installing anything
./install.sh install
```

At the start the installer asks for the password of the panel user `admin`. You can just press
Enter: a password is generated and shown once near the end of the installation. It is not stored in
plain text anywhere. Without a terminal, pass the password in `PLC_PANEL_PASSWORD`.

The rest runs on its own: the installer creates `.env`, issues keys, brings up the databases and the
message bus, builds and starts the components and sets up the panel. The first build takes a while
because the nginx module is compiled and the panel is built. If a step fails, the installation stops
and shows the end of the log. The full log is written to `install.log`.

If ports 80 and 443 are already taken on the machine, copy `.env.example` to `.env` before
installing and change `PLC_HTTP_PORT` and `PLC_HTTPS_PORT`.

## After installation

At the end the installer shows the addresses. By default:

- panel: http://127.0.0.1:8081, user `admin`
- application traffic: port 80
- controller API: http://127.0.0.1:8080

The panel is only reachable from the machine itself. From another machine, the easiest way is an SSH
tunnel:

```sh
ssh -L 8081:127.0.0.1:8081 user@server
```

The panel then opens at http://127.0.0.1:8081 on your side.

Right after installation the panel has a single server: the panel itself. How to create the first
route and check that traffic goes through Placitum is described in
[INSTALL.md](INSTALL.md#after-installation).

## Commands

| Command | What it does |
| --- | --- |
| `./install.sh check` | checks the machine and settings without changing anything |
| `./install.sh install` | installs everything in order; safe to run again |
| `./install.sh status` | shows what is running and the addresses |
| `./install.sh panel-password` | changes the `admin` password and lifts the login lockout |
| `./install.sh panel` | restores the panel server and login if they were deleted; other changes stay |
| `./install.sh infra` | brings up the infrastructure only |
| `./install.sh down` | stops everything; data stays |

Options: `--no-build` starts already built images without rebuilding, `--sources <file>` takes
component sources from another file.

## Configuration

Installation settings live in `.env`. On the first run it is created from `.env.example`, which
describes every variable. The ones changed most often:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PLC_HTTP_PORT`, `PLC_HTTPS_PORT` | `80`, `443` | ports for application traffic |
| `PLC_PANEL_BIND` | `127.0.0.1` | machine address the panel listens on; `0.0.0.0` means all addresses |
| `PLC_PANEL_PORT` | `8081` | panel port |
| `PLC_NODE_ID` | `edge-01` | node name in the panel and the log |
| `PLC_INFRA_PORTS` | `none` | `loopback` opens the databases, NATS and MinIO on 127.0.0.1 for access from the machine |
| `PLC_COOKIE_SECURE` | `off` | set to `on` once the node serves HTTPS |

Set the ports before installing. If you change them later, run `./install.sh install` again and the
containers are recreated.

## Where components come from

`sources.env` has one line per component: the repository address and a branch or tag.

```
PLC_SRC_CONTROLLER=https://github.com/exemt/placitum-controller.git#rc_1.0
```

Every component comes from its `rc_1.0` branch, the release candidate. Once releases exist, a tag
such as `#v1.2.0` can be used instead of a branch, and this one file then pins the version of the
whole installation.

To build a component from your own copy of the sources, copy `sources.env`, replace the address with
a path to the directory in the copy and pass the file to the installer. Paths are relative to the
`compose/` directory.

```sh
cp sources.env sources.local.env
./install.sh install --sources sources.local.env
```

## Security

- The controller API on `127.0.0.1:8080` has no login. Do not expose it and do not put a proxy in
  front of it. For access from another machine, use an SSH tunnel.
- Docker publishes ports around UFW and other firewalls on the machine. Only `PLC_PANEL_BIND`
  decides who can reach the panel.
- If the panel is reachable from outside the machine, serve it over HTTPS; otherwise the password
  travels in plain text.
- Installation keys live in `secrets/` and never go to git. Do not run `bootstrap/secrets.sh --force`
  unless you really have to: it issues a new key, and certificates uploaded through the panel can no
  longer be decrypted.

## What runs

Infrastructure (`compose/infra.yml`): NATS, PostgreSQL, ClickHouse, two Redis instances and MinIO.
It is not reachable from outside.

Placitum itself (`compose/waf.yml`):

- `edge`: the protection node, nginx with the Placitum module. Application traffic and the panel go
  through it.
- `controller`: API and admin panel.
- `logger` and `search`: event recording and search.
- Inspectors that check requests: `ip`, `modsec`, `json`, `counter`, `action`, `rewrite`, `cookie`,
  `auth` (login form) and `captcha`.
- Service components `crypto`, `geo`, `keeper` and agents that watch Redis and MinIO.
- `vlai`: the text classifier. It does not start by default: it is heavy and downloads a model on
  first start. How to enable it is described in [INSTALL.md](INSTALL.md#what-runs).

Services set up their database schemas themselves on start: ClickHouse by `logger`, PostgreSQL by
`controller` on an empty database.

## Installation without Docker

There is an experimental option without Docker: everything on one Debian 13 machine, services
installed as .deb packages and run as systemd units. The packages are still built from the images
made by `install.sh`, so a machine with Docker is needed for the build. Details are in
[native/README.md](native/README.md).

## Repository layout

```
install.sh      installer
sources.env     where component sources come from
.env.example    settings template
compose/        compose files: infra.yml for the infrastructure, waf.yml for everything
config/         configs for NATS, ClickHouse, MinIO and the node, geo data directories
bootstrap/      initial setup: keys, NATS streams, panel, configuration delivery
native/         installation without Docker
secrets/        installation keys, not in git
```

## Not there yet

- Several protection nodes behind a load balancer: there is one node for now.
- Upgrades with a single command.
- Prebuilt images: everything is built from sources.
- Kubernetes manifests.

## License

[Placitum License Agreement](LICENSE.md). A Russian translation is in
[LICENSE.ru.md](LICENSE.ru.md); the English text is the legally binding one.
