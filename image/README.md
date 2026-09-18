# Virtual machine image

English · [Русский](README.ru.md)

A ready virtual machine: Debian 13, Docker, every Placitum image, and nginx with the module and
haproxy with their agents as services of the machine. The image has nothing installed yet. The first boot asks the settings on the console and creates keys and passwords of
its own, so machines made from one image do not share secrets.

## Building

On a Linux machine with Docker and KVM:

```sh
sh image/build.sh
```

The script builds the images from `sources.env`, starts a Debian 13 cloud image in QEMU, installs
Docker there, loads the images, puts nginx and haproxy with their agents on the machine
(`image/host.sh`) and cleans the machine up. The result is
`image/work/placitum-<revision>.qcow2`, about 2 GB. Branches from `sources.env` are resolved to
commits, and the image lists them in `/opt/placitum/image/MANIFEST`.

The build loads every core of the machine. On a small machine that overheats, build the component
images one after another and give the build machine two cores: `BUILD_ONE_BY_ONE=1 VM_CPUS=2 sh
image/build.sh`. `BUILD_PAUSE` runs a command before each image, for example a script that waits
until the processor cools down.

The build machine needs Docker, `qemu-system-x86_64` with access to `/dev/kvm` (the `kvm` group),
`qemu-img`, `cloud-localds` from cloud-image-utils, `ssh`, `curl` and `python3`, and internet access:
Debian and Docker packages are installed from their repositories.

## First boot

The first boot runs the installation on the console (tty1):

1. A password for the `placitum` user. It logs in on the console and over SSH and has sudo.
2. The installation settings: node name, traffic addresses and ports, panel address and port, the
   network for the containers. One more question opens nodes, nginx processes, inspector copies and
   Redis memory. Enter takes the value in
   brackets. The panel address defaults to `0.0.0.0`, all addresses of the machine.
3. The password of the panel user `admin`. Enter generates one and shows it once.

The images are already on the disk, so nothing is downloaded, and the installation takes about a
minute. At the end the console shows the panel address; the login prompt shows it too.

Without a console, for example in a cloud, put the answers into `/etc/placitum/answers.env` before
the first boot. With cloud-init:

```yaml
#cloud-config
write_files:
  - path: /etc/placitum/answers.env
    permissions: "0600"
    content: |
      PLC_NODE_ID=edge-01
      PLC_PANEL_PASSWORD=a-long-password
```

The variables are the ones from `.env.example`. Missing ones take the defaults. The file is deleted
once it is read. SSH keys and users in that case come from cloud-init as usual.

## On the machine

| Command | What it does |
| --- | --- |
| `sudo placitum reconfigure` | asks the settings again and applies them |
| `sudo placitum status` | shows what is running and the addresses |
| `sudo placitum panel-password` | changes the `admin` password and lifts the login lockout |
| `sudo placitum check` | checks the settings without changing anything |
| `sudo placitum down` | stops everything; data stays |

`placitum` runs `/opt/placitum/install.sh` and never builds images. Settings live in
`/opt/placitum/.env`.

With one node nginx with the module runs on the machine itself, as the services `nginx` and
`placitum-node-agent`, and only the rest is in containers; with several nodes the nodes are
containers, and haproxy with its agent runs on the machine as `placitum-haproxy` and
`placitum-haproxy-agent`. `placitum reconfigure` turns them on and off, the agents take their
configuration from the controller. Details: [Where the node runs](../INSTALL.md#where-the-node-runs).

## Sizing

The smallest machine is 2 cores, 4 GB of memory and a 20 GB disk. Measured on KVM with the load
cases of the test stand. The test application ran on the same machine and took up to a fifth of a
core.

| Checks on the route | Requests per second without errors | p99 |
| --- | --- | --- |
| ModSecurity rules, CRS at paranoia level 1 | 750; 500 for five minutes | 120–250 ms |
| Ten address list lookups | 560 | 110 ms |
| JWT login gate, request counter and response body | 340 | 60 ms |

The processor runs out first. Memory stays at 1.3 GB free or more under load. The disk is the long
term limit: every request leaves about 270 bytes in ClickHouse, the audit is kept for 90 days and
the log for 14. At a constant 100 requests per second that is about 2.3 GB a day.

## Not there yet

- Formats other than qcow2: OVA for VMware and VirtualBox, VHDX for Hyper-V.
- Checked on KVM only.
- Upgrades: a new version is a new machine.
- External S3 instead of the local MinIO in the settings.
- The `vlai` classifier: the image has neither its image nor the model, and the installation does
  not offer it.
- HTTPS for the panel: over plain HTTP the password travels in clear text.
