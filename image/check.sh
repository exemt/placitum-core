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
# CHECK_SECONDS bounds the wait (240). The machine gets 2 processors and 2 GB. Needs
# qemu-system-x86_64 with KVM, qemu-img, python3 and, for hyperv, the OVMF firmware
# (the ovmf package). The console log stays in image/work for a look.

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

machine=q35
[ "$mode" != ide ] || machine=pc

set -- -name placitum-check -machine "$machine,accel=kvm" -cpu host -smp 2 -m 2048 \
    -display none -serial "file:$work/console.log" -pidfile "$work/qemu.pid" -daemonize \
    -monitor "unix:$work/monitor.sock,server,nowait"

case "$mode" in
    kvm)
        set -- "$@" -drive file="$overlay",if=virtio,format=qcow2 \
            -netdev user,id=n0 -device virtio-net-pci,netdev=n0
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
            -netdev user,id=n0 -device virtio-net-pci,netdev=n0
        ;;
    ide)
        # i440FX with its PIIX3 IDE controller, the one the OVA describes.
        set -- "$@" -drive file="$overlay",if=ide,format=qcow2,index=0 \
            -netdev user,id=n0 -device e1000,netdev=n0
        ;;
    sata)
        # The AHCI controller of Q35.
        set -- "$@" -drive file="$overlay",if=none,format=qcow2,id=d0 -device ide-hd,drive=d0,bus=ide.0 \
            -netdev user,id=n0 -device e1000,netdev=n0
        ;;
    *)
        die "unknown mode: $mode (kvm, hyperv, ide or sata)"
        ;;
esac

# The kvm group gives /dev/kvm; a member already gets a no-op sg.
if id -nG | grep -qw kvm && [ ! -w /dev/kvm ]; then
    sg kvm -c "qemu-system-x86_64 $*" || die "qemu did not start"
else
    qemu-system-x86_64 "$@" || die "qemu did not start"
fi

started=$(date +%s)
result=1

while [ $(( $(date +%s) - started )) -lt "$wait" ]; do
    if grep -aq 'login:' "$work/console.log" 2>/dev/null; then
        result=0
        break
    fi

    sleep 5
done

printf '%s %s (%s): ' "$mode" "$(basename "$disk")" "$format"

if [ "$result" -eq 0 ]; then
    printf 'login prompt after %ss\n' "$(( $(date +%s) - started ))"
else
    printf 'no login prompt within %ss\n' "$wait"
fi

# What the guest saw: the disk, the network adapter, ssh and the first boot service.
grep -a -E ' sd[a-z]: | vd[a-z]: |e1000 .*eth[0-9]|virtio_net .*eth[0-9]|Started .*ssh.service|Failed to start .*ssh|placitum-firstboot|EFI stub' \
    "$work/console.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/^/    /' | head -n 12

python3 - "$work/monitor.sock" <<'PY' >/dev/null 2>&1 || true
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.settimeout(1)
try:
    s.recv(65536)
except Exception:
    pass
s.sendall(b"system_powerdown\n")
time.sleep(0.3)
PY

n=0
while kill -0 "$(cat "$work/qemu.pid" 2>/dev/null)" 2>/dev/null && [ "$n" -lt 20 ]; do
    n=$((n + 1))
    sleep 2
done
kill "$(cat "$work/qemu.pid" 2>/dev/null)" 2>/dev/null || true

rm -f "$overlay" "$work/qemu.pid" "$work/monitor.sock"
printf 'console: %s\n' "$work/console.log"
exit "$result"
