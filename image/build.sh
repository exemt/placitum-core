#!/bin/sh
# Builds a ready virtual machine image: Debian 13, Docker, Placitum files and images.
# Nothing is installed yet: the first boot asks the settings on the console and
# creates keys and passwords of its own on every machine.
#
#     sh image/build.sh                    image/work/placitum-<revision>.qcow2
#     sh image/build.sh --sources <file>   other component sources
#
# The host needs Docker, qemu-system-x86_64 with KVM, qemu-img, cloud-localds,
# ssh and python3. Branches in the sources are resolved to commits, and the image
# lists them in /opt/placitum/image/MANIFEST.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core=$(dirname "$here")
work="$here/work"
sources="$core/sources.env"

while [ $# -gt 0 ]; do
    case "$1" in
        --sources) sources=$2; shift 2 ;;
        -h|--help|help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

BASE_URL=https://cloud.debian.org/images/cloud/trixie/latest
BASE_NAME=debian-13-genericcloud-amd64.qcow2

VM_CPUS=${VM_CPUS:-4}
VM_MEM=${VM_MEM:-4096}
VM_DISK=${VM_DISK:-20G}
VM_SSH_PORT=${VM_SSH_PORT:-2232}

project=placitum-image
revision=$(git -C "$core" rev-parse --short HEAD)
if [ -n "$(git -C "$core" status --porcelain)" ]; then
    revision="$revision-dirty"
fi

say() { printf '\n== %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

for tool in docker qemu-system-x86_64 qemu-img cloud-localds ssh scp ssh-keygen python3 git curl; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done

mkdir -p "$work"

say "sources"

# Every branch becomes a commit, so the image says exactly what is inside.
lock="$work/sources.lock.env"
: > "$lock"
: > "$work/MANIFEST"
printf 'core %s\n' "$revision" >> "$work/MANIFEST"

grep '^PLC_SRC_' "$sources" | while IFS='=' read -r name url; do
    case "$url" in
        *://*|git@*)
            ;;
        *)
            # A directory, relative to compose/ as in sources.env.
            path=$(cd "$core/compose" && cd "$url" && pwd) || die "$name: no directory $url"
            state=$(git -C "$path" rev-parse --short HEAD 2>/dev/null || echo unknown)
            [ -z "$(git -C "$path" status --porcelain 2>/dev/null)" ] || state="$state-dirty"

            printf '%s=%s\n' "$name" "$path" >> "$lock"
            printf '%s %s %s\n' "$name" "$state" "$path" | tee -a "$work/MANIFEST"
            continue
            ;;
    esac

    repo=${url%%#*}
    rest=${url#*#}
    ref=${rest%%:*}
    sub=""
    case "$rest" in *:*) sub=":${rest#*:}" ;; esac

    sha=$(git ls-remote "$repo" "refs/heads/$ref" "refs/tags/$ref" | head -n 1 | cut -f1)
    [ -n "$sha" ] || sha=$ref

    printf '%s=%s#%s%s\n' "$name" "$repo" "$sha" "$sub" >> "$lock"
    printf '%s %s %s\n' "$name" "$sha" "$url" | tee -a "$work/MANIFEST"
done

say "images"

compose() {
    docker compose -p "$project" --ansi never --progress plain \
        --env-file "$core/.env.example" --env-file "$lock" \
        -f "$core/compose/waf.yml" "$@"
}

# Built images get names of their own, so the build does not retag images this
# host already uses. On the machine they get their installation names back.
compose config --format json > "$work/compose.json"

python3 - "$work/compose.json" "$work/names.yml" "$work/retag.txt" "$work/images.txt" <<'EOF'
import json, sys

cfg = json.load(open(sys.argv[1]))
names, retag, images = [], [], set()

for service, spec in sorted(cfg["services"].items()):
    if spec.get("profiles"):
        continue
    if "build" in spec:
        built = f"placitum-image/{service}"
        names.append(f"  {service}:\n    image: {built}\n")
        retag.append(f"{built} {spec.get('image') or 'placitum-' + service}\n")
        images.add(built)
    elif not spec["image"].startswith("placitum/"):
        images.add(spec["image"])

open(sys.argv[2], "w").write("services:\n" + "".join(names))
open(sys.argv[3], "w").write("".join(retag))
open(sys.argv[4], "w").write("".join(f"{i}\n" for i in sorted(images)))
EOF

PLC_VERSION=${PLC_VERSION:-dev} PLC_REVISION=$revision \
    compose -f "$work/names.yml" build > "$work/build.log" 2>&1 ||
    die "image build failed, log: $work/build.log"

while read -r image; do
    case "$image" in
        placitum-image/*) ;;
        *) docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null ;;
    esac
done < "$work/images.txt"

# shellcheck disable=SC2046
docker save -o "$work/images.tar" $(cat "$work/images.txt")
printf 'images: %s, %s\n' "$(wc -l < "$work/images.txt")" "$(du -h "$work/images.tar" | cut -f1)"

say "files"

# Tracked and new files of core, without what an installation creates by itself.
git -C "$core" ls-files --cached --others --exclude-standard |
    grep -v -e '^native/' -e '^image/work/' |
    tar -C "$core" -cf "$work/core.tar" -T -

say "base image"

base="$work/$BASE_NAME"

if [ ! -f "$base" ]; then
    curl -fsSL --retry 3 -o "$work/SHA512SUMS" "$BASE_URL/SHA512SUMS"
    curl -fsSL --retry 3 -o "$base.part" "$BASE_URL/$BASE_NAME"

    want=$(awk -v f="$BASE_NAME" '$2 == f {print $1}' "$work/SHA512SUMS")
    have=$(sha512sum "$base.part" | cut -d' ' -f1)
    [ -n "$want" ] && [ "$want" = "$have" ] || die "$BASE_NAME does not match SHA512SUMS"

    mv "$base.part" "$base"
fi

say "build machine"

vm="$work/vm"
rm -rf "$vm"
mkdir -p "$vm"

key="$vm/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -C placitum-image-build -f "$key"

cat > "$vm/user-data" <<EOF
#cloud-config
users:
  - name: build
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/sh
    ssh_authorized_keys:
      - $(cat "$key.pub")
ssh_pwauth: false
EOF
printf 'instance-id: placitum-image-build\nlocal-hostname: placitum\n' > "$vm/meta-data"
cloud-localds "$vm/seed.img" "$vm/user-data" "$vm/meta-data"

qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$vm/disk.qcow2" "$VM_DISK"

sg kvm -c "qemu-system-x86_64 -name placitum-image-build \
    -machine q35,accel=kvm -cpu host -smp $VM_CPUS -m $VM_MEM \
    -drive file=$vm/disk.qcow2,if=virtio,format=qcow2,discard=unmap \
    -drive file=$vm/seed.img,if=virtio,format=raw,readonly=on \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$VM_SSH_PORT-:22 -device virtio-net-pci,netdev=n0 \
    -display none -serial file:$vm/console.log -pidfile $vm/qemu.pid -daemonize" ||
    die "qemu did not start"

ssh_opts="-i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes"

tries=60
# shellcheck disable=SC2086
until ssh $ssh_opts -p "$VM_SSH_PORT" build@127.0.0.1 true 2>/dev/null; do
    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || die "build machine has no ssh, console: $vm/console.log"
    sleep 5
done

# shellcheck disable=SC2086
scp $ssh_opts -q -P "$VM_SSH_PORT" "$work/core.tar" "$work/images.tar" "$work/retag.txt" \
    "$work/MANIFEST" "$here/provision.sh" build@127.0.0.1:/tmp/ ||
    die "copy to the build machine failed"

# shellcheck disable=SC2086
ssh $ssh_opts -p "$VM_SSH_PORT" build@127.0.0.1 'sudo sh /tmp/provision.sh' > "$work/provision.log" 2>&1 ||
    die "provisioning failed, log: $work/provision.log"

pid=$(cat "$vm/qemu.pid")
n=0
while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -lt 120 ] || die "build machine did not power off, console: $vm/console.log"
    sleep 2
done

say "image"

out="$work/placitum-$revision.qcow2"
qemu-img convert -c -O qcow2 "$vm/disk.qcow2" "$out"
rm -rf "$vm" "$work/images.tar" "$work/core.tar"

printf 'image: %s, %s\n' "$out" "$(du -h "$out" | cut -f1)"
