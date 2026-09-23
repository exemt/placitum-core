# Installation without Docker

English · [Русский](README.ru.md)

An experimental installation of the whole of Placitum on one Debian 13 machine: processes run as
systemd units, components are installed as .deb packages. The packages are built from the same
images that `install.sh` builds. The main installation is still `install.sh` in the repository root.

## Building and installing

Build the packages on a machine with Docker where `./install.sh install` has already built the
images:

```sh
sh native/build.sh        # packages from the local images into native/work/packages
```

Copy the packages and the installer to a Debian 13 machine into one directory and run it there:

```sh
scp -r native/work/packages native/install.sh native/check.mjs user@server:placitum/
ssh user@server 'cd placitum && sudo sh install.sh'
```

`packages/` must sit next to `install.sh`. Infrastructure comes from repositories: Debian
(PostgreSQL, Redis), nginx.org (the nginx version the module is built against), ClickHouse and
NodeSource. At the end the installer shows the panel address and the `admin` password.

| Command | What it does |
| --- | --- |
| `sudo sh install.sh` | installs; asks for whatever is not in the answers yet |
| `sudo sh install.sh --reconfigure` | asks everything again; current answers become the defaults |
| `sudo sh install.sh --defaults` | installs without questions, using defaults for missing answers |
| `sudo sh install.sh status` | shows what is running |
| `sudo sh install.sh check` | checks a clean installation the way a user sees it |

## Files

| File | What it does |
| --- | --- |
| `build.sh` | builds 19 packages from local images: binaries, `/app` directories, units with the image environment; `work/packages/MANIFEST` lists the commit in every image |
| `install.sh` | questions, repositories, packages, secrets, configs, database, schema, processes, panel, delivery |
| `check.mjs` | checks a clean installation for systemd and 127.0.0.1 addresses; `install.sh check` runs it |
| `pkg/` | what goes into the packages besides the images: `app-sync`, the node step `tune.mjs`, the panel step build |

## Installer questions

Answers are written to `/etc/placitum/placitum.conf`. A repeated run takes them from the file and
asks nothing. The `admin` password is not stored in the answers: without a terminal it comes from
`PLC_PANEL_PASSWORD`; if empty, it is generated and shown once.

| Answer | Default | Purpose |
| --- | --- | --- |
| `PLC_NODE_ID` | `edge-01` | node name in the panel and the audit |
| `PLC_HTTP_PORT` | `80` | traffic port; ports used by Placitum itself are rejected |
| `PLC_PANEL_BIND` | `127.0.0.1` | panel address: loopback, `0.0.0.0` or a machine interface address |
| `PLC_NGINX_WORKERS` | `auto` | nginx workers, a node setting in the panel |
| `PLC_COPIES_<INSPECTOR>` | `1` | copies of each inspector: `ip`, `modsec`, `json`, `counter`, `action`, `rewrite`, `cookie`, `auth`, `captcha` |
| `PLC_REDIS_EXCHANGE_MB`, `PLC_REDIS_INTERNAL_MB` | `512`, `256` | memory limits of the exchange and internal Redis |

An inspector copy is an instance of the `placitum-<inspector>@<n>` template. When the number goes
down, the installer stops and removes the extra instances.

## What goes where

| What | From | Where |
| --- | --- | --- |
| nginx 1.28.0 | nginx.org, pinned with `apt-mark hold` | the module is built against this version: `/usr/lib/nginx/modules` |
| Placitum binaries | `placitum-*` packages | `/usr/lib/placitum/bin`, not in PATH: `ip` and `json` would clash with system tools |
| image `/app` directories | `placitum-*` packages | `/usr/share/placitum/<component>`; each process gets its own copy in `/var/lib/placitum/<process>/app`, data next to it in `data` |
| controller | `placitum-controller` | `/usr/lib/placitum/controller`, Node.js 22 from NodeSource |
| NATS 2.12, MinIO, `nats` and `mc` clients | binaries from the `compose/infra.yml` images | `/usr/lib/placitum/bin` |
| PostgreSQL, Redis | Debian 13 | Redis runs as two own instances, `placitum-redis@exchange` and `@internal`; the package unit is disabled |
| ClickHouse 24.8 | ClickHouse repository | user `waf` in `users.d/placitum.xml`, log to journald |
| answers, environment, secrets | `install.sh` | `/etc/placitum`: `placitum.conf`, `env/*.env`, `secrets/` |

Before start, `app-sync` gives each process its own copy of the directory, like an image layer for a
container: inspectors write to their directories. When the `.build` label differs from the package,
the copy is recreated.

`build.sh` takes the unit environment from the image environment: `/app` and `/var/lib/waf/<x>`
paths move to the process directories. Addresses, ports and credentials are not carried over:
`install.sh` writes them to `/etc/placitum/env`, and that file wins over the unit.

## Ports on the machine

| Port | What | Address |
| --- | --- | --- |
| 80, 8081, 8079 | nginx: traffic, panel, placeholder until the first generation | traffic and panel ports come from the answers |
| 8080 | controller, API without login | 127.0.0.1 (`CONTROLLER_HOST`) |
| 8091 | search | 127.0.0.1 (`SEARCH_HOST`) |
| 8085, 8086 | login and captcha forms | 127.0.0.1 |
| 8092, 50051, 8093, 8094 | geo, crypto, keeper | 127.0.0.1 |
| 4222, 8222 | NATS | 127.0.0.1 |
| 6379, 6380 | Redis: exchange and internal | 127.0.0.1 |
| 5432, 8123, 9000 | PostgreSQL, ClickHouse | localhost |
| 9100, 9101 | MinIO: API and console | 127.0.0.1 |

The controller and search have no login, so the installer binds them to 127.0.0.1
(`CONTROLLER_HOST`, `SEARCH_HOST` in their environment files).

## Differences from the Docker installation

- Panel pools use 127.0.0.1 without resolve. There are no container names, so no Docker resolver
  is configured: the panel step `bootstrap/panel.mjs` takes the addresses from `PANEL_*` variables.
- The shipped `http-8080` port becomes `PLC_HTTP_PORT`. In a container the node listens on 8080;
  on a single machine 8080 is taken by the controller (`pkg/tune.mjs`).
- The `waf` role is not a PostgreSQL superuser. The pgcrypto extension is
  trusted and installed by the database owner; installing it beforehand as postgres breaks the
  schema on `COMMENT ON EXTENSION`.
- The key fingerprint pin is written during installation. The panel reads it from
  `/usr/lib/placitum/controller/ux/dist/contour-pin.json`; root writes the machine fingerprint
  there, the controller process does not write its own files.
- Every unit sets `WAF_LOG_WRITER`. Without containers all processes would share the machine
  name in the logs.

## Limits

The installer has no proxy question yet; HAProxy in front of nginx comes together with its support.
`vlai` is not packaged. Running `install.sh` again installs new packages but does not restart running
processes. There is no TLS on the node or the panel, and this installer builds no machine image.
MinIO ships as source only since October 2025 and was archived in February 2026, so it needs a
replacement.
