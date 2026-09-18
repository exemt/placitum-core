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
image/build.sh`. `BUILD_PAUSE` runs a command before each image: `BUILD_PAUSE="sh image/cool.sh"`
waits until the processor is below 70 degrees (`COOL_BELOW`).

The build machine needs Docker, `qemu-system-x86_64` with access to `/dev/kvm` (the `kvm` group),
`qemu-img`, `cloud-localds` from cloud-image-utils, `ssh`, `curl` and `python3`, and internet access:
Debian and Docker packages are installed from their repositories.

## Formats

The build makes a qcow2 for KVM. `image/export.sh` turns it into the formats of the other
hypervisors; the machine inside is the same, the first boot goes the same way.

```sh
sh image/export.sh image/work/placitum-<revision>.qcow2        # both formats
sh image/export.sh image/work/placitum-<revision>.qcow2 vhdx   # Hyper-V only
```

| File | Hypervisor | How to run |
| --- | --- | --- |
| `placitum-<revision>.qcow2` | KVM, QEMU, Proxmox | a virtio disk and a virtio network adapter, BIOS or UEFI; `image/check.sh kvm` boots it under QEMU |
| `placitum-<revision>.vhdx` | Hyper-V | a generation 2 machine with Secure Boot on the Microsoft UEFI Certificate Authority template, or a generation 1 machine; the disk on the SCSI controller, 2 processors, 4 GB, a network adapter on an external switch |
| `placitum-<revision>.ova` | VirtualBox, VMware Workstation, ESXi | import the OVA: it describes 2 processors, 4 GB, an LSI Logic SCSI controller and an Intel E1000 adapter; put the adapter on the network the panel is opened from (bridged) |

The image is built on the `generic` Debian cloud image, whose kernel has the drivers of the
devices these hypervisors emulate. `--base genericcloud` takes the smaller cloud kernel instead,
which knows KVM, Xen and the paravirtual devices of Hyper-V and VMware only: no VirtualBox, and
VMware only with the paravirtual SCSI controller and vmxnet3.

Outside KVM there is no cloud-init seed, so the first boot asks its questions on the console of
the machine; the answers file works where the hypervisor gives cloud-init a NoCloud seed.

## Checking a build

`image/check.sh` boots a disk under QEMU with the devices of a hypervisor, waits for the login
prompt and the address of the machine on the serial console, and powers the machine off; the disk
itself is not written to. It shows whether the kernel found the disk and the network adapter,
whether ssh started and whether the first boot service began.

The adapter gets a random hardware address on every run. That is the point: a network
configuration tied to the adapter of the build machine works there and nowhere else, and only a
different address brings it out.

```sh
sh image/check.sh kvm    image/work/placitum-<revision>.qcow2   # virtio, BIOS
sh image/check.sh hyperv image/work/placitum-<revision>.vhdx    # UEFI, the disk on SCSI
tar -xf image/work/placitum-<revision>.ova                      # the disk of the OVA
sh image/check.sh ide    placitum-<revision>-disk1.vmdk         # IDE and E1000, as imported
sh image/check.sh sata   placitum-<revision>-disk1.vmdk         # after a move to a SATA controller
```

The check machine needs `qemu-system-x86_64` with KVM, `qemu-img`, `python3` and, for `hyperv`,
the OVMF firmware from the `ovmf` package. This is a boot check, not an installation: the whole
first boot with the installation is checked on KVM with an answers file, see [First boot](#first-boot).

A release is the three commands in a row: `build.sh`, `export.sh`, `check.sh` for each file, then
the files with their `sha256sum`.

## Files

| File | What it does |
| --- | --- |
| `build.sh` | builds the component images, provisions a Debian machine in QEMU and writes the qcow2 |
| `provision.sh` | runs inside the build machine: Docker, the images, the Placitum files, the services of the machine, the first boot service, cleanup |
| `host.sh` | nginx with the module and the node agent, haproxy and its agent as services of the machine, from the images; `install.sh` runs it too where it can |
| `export.sh` | VHDX for Hyper-V and an OVA for VirtualBox and VMware out of the qcow2 |
| `check.sh` | boots a disk under QEMU with the devices of a hypervisor and a random adapter address |
| `cool.sh` | waits until the processor cools down, for `BUILD_PAUSE` |
| `firstboot.sh`, `placitum-firstboot.service` | the first boot on the console: the `placitum` user password and the installation |
| `placitum` | `sudo placitum <command>` on the machine, the commands of `install.sh` without builds |
| `balancer/`, `node/` | units and stub configurations of haproxy and nginx on the machine |
| `network/` | the netplan configuration of the machine and the cloud-init drop-in that leaves the network to it |

## Network

The machine takes its address over DHCP on whatever ethernet adapter it is given:
`/etc/netplan/99-placitum.yaml` matches adapters by name (`en*` and `eth*`), not by hardware
address, so the same image works on every hypervisor. cloud-init does not configure the network
here — the configuration it renders is tied to the adapter it saw, and an image carries that to
machines with other adapters. For a fixed address, put it in that file and run `netplan apply`.

The console greeting shows the address of the machine before the login prompt. An empty address
there means the machine got no lease, and the panel is reachable from nowhere but itself.

## First boot

The first boot asks about the machine first, then runs the installation, all on the console (tty1).
Enter takes the value in brackets.

1. A login and a password: the user of the machine, with sudo, and the administrator of the panel,
   one and the same. Enter at the password generates one, shown once at the end. The shipped user
   `placitum` is the default; another login replaces it.
2. The machine name, `placitum` by default: the hostname, and the name of the node in the panel.
3. The time zone, `UTC` by default.
4. The network: for every adapter, DHCP or an address with a prefix length; a fixed address asks
   for the gateway and the DNS servers. The addresses the machine ended up with are printed.
5. The installation settings, see [INSTALL.md](../INSTALL.md#installing): traffic addresses, the
   panel address, the network for the containers, nodes behind a balancer, the set of inspectors
   and their parameters. The panel is proposed on an address of an internal adapter when the
   machine has one besides the adapter of its default route, on the machine's address otherwise.

The images are already on the disk, so nothing is downloaded, and the installation takes about a
minute. At the end the console shows the panel address; the login prompt shows it too, with the
address of the machine.

Without a console, for example in a cloud, put the answers into `/etc/placitum/answers.env` before
the first boot. With cloud-init:

```yaml
#cloud-config
write_files:
  - path: /etc/placitum/answers.env
    permissions: "0600"
    content: |
      PLC_LOGIN=ops
      PLC_HOSTNAME=waf-01
      PLC_TIMEZONE=Europe/Berlin
      PLC_PANEL_PASSWORD=a-long-password
```

The variables are the ones from `.env.example`, plus `PLC_LOGIN`, `PLC_HOSTNAME` and
`PLC_TIMEZONE` for the machine itself. Missing ones take the defaults; the network stays on DHCP.
`PLC_PANEL_PASSWORD` becomes the password of the machine user too; without it that user stays
locked and the panel generates its own. The file is deleted once it is read. SSH keys and users
in that case come from cloud-init as usual.

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

- Hyper-V, VirtualBox and VMware were not tried themselves: the VHDX and the OVA disk were booted
  under QEMU with UEFI and with an LSI Logic controller and an E1000 adapter, the devices those
  hypervisors present.
- Upgrades: a new version is a new machine.
- External S3 instead of the local MinIO in the settings.
- The `vlai` classifier: the image has neither its image nor the model, and the installation does
  not offer it.
- HTTPS for the panel: over plain HTTP the password travels in clear text.
