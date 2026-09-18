#!/bin/sh
# Boots a built disk under QEMU with the devices of a hypervisor and waits for the login prompt on
# the serial console; then the machine is powered off. The disk is opened through a throwaway
# overlay, so the file stays as it was. A quick check of a build before it goes anywhere.
#
#     sh image/check.sh kvm       <image.qcow2>     virtio disk and network, BIOS: KVM, Proxmox
#     sh image/check.sh hyperv    <image.vhdx>      UEFI, the disk on SCSI: Hyper-V generation 2
#     sh image/check.sh ide       <disk.vmdk>       BIOS, IDE disk and E1000 adapter: the OVA as
#                                                   VirtualBox and VMware import it
#     sh image/check.sh sata      <disk.vmdk>       BIOS, SATA disk and E1000 adapter: VirtualBox
#                                                   with the disk moved to its SATA controller
#
# The disk of an OVA is inside the archive: tar -xf placitum-<revision>.ova takes it out.
# CHECK_SECONDS bounds the wait (240). The machine gets 2 processors and 2 GB and a network
# adapter with a random address, so that a network configuration tied to the adapter of the build
# machine shows up here and not at the customer: the check waits for the machine to print its own
# address on the console. Needs qemu-system-x86_64 with KVM, qemu-img, python3 and, for hyperv,
# the OVMF firmware (the ovmf package). The console log stays in image/work for a look.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mode=${1:?usage: check.sh kvm|hyperv|ide|sata <disk>}
disk=${2:?usage: check.sh kvm|hyperv|ide|sata <disk>}
wait=${CHECK_SECONDS:-240}

die() { printf '!! %s\n' "$*" >&2; exit 1; }

[ -f "$disk" ] || die "no disk: $disk"

for tool in qemu-system-x86_64 qemu-img python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done

format=$(qemu-img info "$disk" | sed -n 's/^file format: //p')
[ -n "$format" ] || die "qemu-img does not recognise $disk"

mkdir -p "$here/work"
work=$(mktemp -d "$here/work/check.XXXXXX")
overlay="$work/overlay.qcow2"
qemu-img create -q -f qcow2 -F "$format" -b "$(readlink -f "$disk")" "$overlay"

# A random adapter address: it matches no configuration carried inside the image.
mac=$(python3 -c 'import random; print("02:%02x:%02x:%02x:%02x:%02x" % tuple(random.randrange(256) for _ in range(5)))')

machine=q35
[ "$mode" != ide ] || machine=pc

set -- -name placitum-check -machine "$machine,accel=kvm" -cpu host -smp 2 -m 2048 \
    -display none -serial "file:$work/console.log" -pidfile "$work/qemu.pid" -daemonize \
    -monitor "unix:$work/monitor.sock,server,nowait"

case "$mode" in
    kvm)
        set -- "$@" -drive file="$overlay",if=virtio,format=qcow2 \
            -netdev user,id=n0 -device virtio-net-pci,netdev=n0,mac="$mac"
        ;;
    hyperv)
        firmware=""
        for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd \
            /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
            [ -f "$f" ] && { firmware=$f; break; }
        done
        [ -n "$firmware" ] || die "no OVMF firmware: install the ovmf package"

        set -- "$@" -drive "if=pflash,format=raw,readonly=on,file=$firmware" \
            -device virtio-scsi-pci,id=scsi0 \
            -drive file="$overlay",if=none,format=qcow2,id=d0 -device scsi-hd,drive=d0,bus=scsi0.0 \
            -netdev user,id=n0 -device virtio-net-pci,netdev=n0,mac="$mac"
        ;;
    ide)
        # i440FX with its PIIX3 IDE controller, the one the OVA describes.
        set -- "$@" -drive file="$overlay",if=ide,format=qcow2,index=0 \
            -netdev user,id=n0 -device e1000,netdev=n0,mac="$mac"
        ;;
    sata)
        # The AHCI controller of Q35.
        set -- "$@" -drive file="$overlay",if=none,format=qcow2,id=d0 -device ide-hd,drive=d0,bus=ide.0 \
            -netdev user,id=n0 -device e1000,netdev=n0,mac="$mac"
        ;;
    *)
        die "unknown mode: $mode (kvm, hyperv, ide or sata)"
        ;;
esac

# monitor <command>: a line to the QEMU monitor; sendkey <key>: one key to the console.
monitor() {
    python3 - "$work/monitor.sock" "$1" <<'PY' >/dev/null 2>&1 || true
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.settimeout(1)
try:
    s.recv(65536)
except Exception:
    pass
s.sendall(sys.argv[2].encode() + b"\n")
time.sleep(0.3)
PY
}

sendkey() {
    monitor "sendkey $1"
}

# The kvm group gives /dev/kvm; a member already gets a no-op sg.
if id -nG | grep -qw kvm && [ ! -w /dev/kvm ]; then
    sg kvm -c "qemu-system-x86_64 $*" || die "qemu did not start"
else
    qemu-system-x86_64 "$@" || die "qemu did not start"
fi

# The address of the machine: what the greeting prints in place of \4. 10.0.2.15 is what the
# network of QEMU hands out; loopback and the Docker networks of the machine do not count.
address() {
    sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$work/console.log" 2>/dev/null |
        grep -ao 'address: *[0-9][0-9.]*' | awk '{ print $2 }' |
        grep -v '^127\.' | grep -v '^172\.1[6-9]\.' | grep -v '^172\.2[0-9]\.' | grep -v '^172\.3[01]\.' |
        tail -n 1
}

started=$(date +%s)
booted=0
result=1

while [ $(( $(date +%s) - started )) -lt "$wait" ]; do
    if [ "$booted" -eq 0 ] && grep -aq 'login:' "$work/console.log" 2>/dev/null; then
        booted=$(( $(date +%s) - started ))
        # A new prompt: the greeting is rendered again, now with the address of the lease.
        sleep 10
        sendkey ret
        sendkey ret
    fi

    if [ "$booted" -gt 0 ] && [ -n "$(address)" ]; then
        result=0
        break
    fi

    sleep 5
done

printf '%s %s (%s): ' "$mode" "$(basename "$disk")" "$format"

if [ "$result" -eq 0 ]; then
    printf 'login prompt after %ss, address %s\n' "$booted" "$(address)"
elif [ "$booted" -gt 0 ]; then
    printf 'login prompt after %ss, but no address of its own within %ss: the network did not come up\n' "$booted" "$wait"
else
    printf 'no login prompt within %ss\n' "$wait"
fi

# What the guest saw: the disk, the network adapter, ssh and the first boot service.
grep -a -E ' sd[a-z]: | vd[a-z]: |e1000 .*eth[0-9]|virtio_net .*eth[0-9]|Started .*ssh.service|Failed to start .*ssh|placitum-firstboot|EFI stub' \
    "$work/console.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/^/    /' | head -n 12

monitor system_powerdown

n=0
while kill -0 "$(cat "$work/qemu.pid" 2>/dev/null)" 2>/dev/null && [ "$n" -lt 20 ]; do
    n=$((n + 1))
    sleep 2
done
kill "$(cat "$work/qemu.pid" 2>/dev/null)" 2>/dev/null || true

rm -f "$overlay" "$work/qemu.pid" "$work/monitor.sock"
printf 'console: %s\n' "$work/console.log"
exit "$result"
