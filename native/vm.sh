#!/bin/sh
# Машина для установки без Docker: Debian 13 под QEMU/KVM, без libvirt.
#
#     native/vm.sh up          скачать облачный образ и создать диск, если их нет, и запустить
#     native/vm.sh wait        дождаться ssh
#     native/vm.sh ssh [cmd]   войти в машину или выполнить в ней команду
#     native/vm.sh copy <файлы…> <каталог в машине>
#     native/vm.sh down        выключить
#     native/vm.sh restart     выключить и запустить: так применяются новые порты
#     native/vm.sh destroy     выключить и снести диск: следующий up даст чистую машину
#     native/vm.sh status      жива ли, куда проброшены порты
#
# Хосту нужны qemu-system-x86, qemu-utils, cloud-image-utils и членство в группе kvm.
#
# Сеть встроенная в QEMU (user): хост она не трогает, машина видна только через
# проброшенные порты. Мост, dnsmasq и цепочки iptables libvirt на машине, где уже
# есть Docker и своя сеть, спорили бы с ними.
#
# Настройки этой машины -- work/vm/vm.env, в git не идёт:
#
#     VM_PANEL_PUBLIC=192.168.1.10:9000     панель на адресе хоста в локальной сети
#
# Панель там идёт по HTTP: пароль в сети открытым текстом.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work="$here/work"
base="$work/images/debian-13-genericcloud-amd64.qcow2"
dir="$work/vm"
disk="$dir/disk.qcow2"
seed="$dir/seed.img"
pidfile="$dir/qemu.pid"
key="$work/ssh/id_ed25519"

if [ -f "$dir/vm.env" ]; then
    # shellcheck disable=SC1091
    . "$dir/vm.env"
fi

# Размер машины под минимальную нагрузку; перекрывается окружением.
VM_CPUS=${VM_CPUS:-4}
VM_MEM=${VM_MEM:-6144}
VM_DISK=${VM_DISK:-40G}

# Порты хоста (только 127.0.0.1) -> порты машины. API контроллера сюда не
# пробрасывается: он слушает loopback машины, к нему ходят туннелем ssh -L.
VM_SSH_PORT=${VM_SSH_PORT:-2222}
VM_HTTP_PORT=${VM_HTTP_PORT:-18080}
VM_HTTPS_PORT=${VM_HTTPS_PORT:-18443}
VM_PANEL_PORT=${VM_PANEL_PORT:-18081}

say() { printf '%s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

ssh_opts="-i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes"

running() {
    [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

vm_ssh() {
    tty=""
    [ -t 0 ] && [ -t 1 ] && tty=-t

    # shellcheck disable=SC2086
    ssh $ssh_opts $tty -p "$VM_SSH_PORT" debian@127.0.0.1 "$@"
}

# NoCloud: пользователь debian с ключом из work/ssh и sudo без пароля.
make_seed() {
    pub=$(cat "$key.pub")

    cat > "$dir/user-data" <<EOF
#cloud-config
hostname: placitum-native
users:
  - name: debian
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - $pub
ssh_pwauth: false
package_update: false
EOF

    printf 'instance-id: placitum-native\nlocal-hostname: placitum-native\n' > "$dir/meta-data"
    cloud-localds "$seed" "$dir/user-data" "$dir/meta-data"
}

# Облачный образ Debian 13 со сверкой по SHA512SUMS.
fetch_image() {
    url=https://cloud.debian.org/images/cloud/trixie/latest
    name=$(basename "$base")

    mkdir -p "$(dirname "$base")"
    say "скачиваю $url/$name"

    curl -fsSL --retry 3 -o "$base.sums" "$url/SHA512SUMS" || die "не скачался SHA512SUMS"
    curl -fsSL --retry 3 -o "$base.part" "$url/$name" || die "не скачался $name"

    want=$(awk -v f="$name" '$2 == f {print $1}' "$base.sums")
    have=$(sha512sum "$base.part" | cut -d' ' -f1)

    if [ -z "$want" ] || [ "$want" != "$have" ]; then
        die "$name не сошёлся с SHA512SUMS"
    fi

    mv "$base.part" "$base"
    rm -f "$base.sums"
}

up() {
    if running; then
        say "машина уже работает, pid $(cat "$pidfile")"
        return 0
    fi

    for tool in qemu-system-x86_64 qemu-img cloud-localds ssh-keygen; do
        command -v "$tool" >/dev/null 2>&1 ||
            die "нет $tool: sudo apt-get install --no-install-recommends qemu-system-x86 qemu-utils cloud-image-utils"
    done

    getent group kvm | grep -qw "$(id -un)" ||
        die "$(id -un) не в группе kvm: sudo usermod -aG kvm $(id -un)"

    [ -f "$base" ] || fetch_image

    if [ ! -f "$key" ]; then
        mkdir -p "$(dirname "$key")"
        ssh-keygen -q -t ed25519 -N '' -C placitum-native-vm -f "$key"
    fi

    mkdir -p "$dir"

    if [ ! -f "$disk" ]; then
        # Путь к облачному образу -- относительный: каталог work можно переносить.
        (cd "$dir" && qemu-img create -q -f qcow2 -F qcow2 -b "../images/$(basename "$base")" disk.qcow2 "$VM_DISK")
        make_seed
        say "диск: $disk, $VM_DISK поверх облачного образа"
    fi

    fwd="hostfwd=tcp:127.0.0.1:$VM_SSH_PORT-:22"
    fwd="$fwd,hostfwd=tcp:127.0.0.1:$VM_HTTP_PORT-:80"
    fwd="$fwd,hostfwd=tcp:127.0.0.1:$VM_HTTPS_PORT-:443"
    fwd="$fwd,hostfwd=tcp:127.0.0.1:$VM_PANEL_PORT-:8081"

    # Панель на внешнем адресе хоста: адрес обязан быть на машине, иначе qemu не встанет.
    if [ -n "${VM_PANEL_PUBLIC:-}" ]; then
        fwd="$fwd,hostfwd=tcp:${VM_PANEL_PUBLIC%:*}:${VM_PANEL_PUBLIC##*:}-:8081"
    fi

    # /dev/kvm принадлежит группе kvm. Членство, выданное недавно, текущий
    # сеанс ещё не видит -- поэтому запуск через sg.
    sg kvm -c "qemu-system-x86_64 -name placitum-native \
        -machine q35,accel=kvm -cpu host -smp $VM_CPUS -m $VM_MEM \
        -drive file=$disk,if=virtio,format=qcow2,discard=unmap \
        -drive file=$seed,if=virtio,format=raw,readonly=on \
        -netdev user,id=n0,$fwd -device virtio-net-pci,netdev=n0 \
        -display none -serial file:$dir/console.log \
        -pidfile $pidfile -daemonize" || die "qemu не запустился"

    say "машина запущена, pid $(cat "$pidfile"); консоль -- $dir/console.log"
}

wait_ssh() {
    tries=${1:-60}

    while [ "$tries" -gt 0 ]; do
        if vm_ssh true 2>/dev/null; then
            say "ssh отвечает"
            return 0
        fi

        tries=$((tries - 1))
        sleep 5
    done

    die "ssh не ответил; консоль -- $dir/console.log"
}

copy() {
    [ $# -ge 2 ] || die "copy <файлы…> <каталог в машине>"

    last=""
    for arg in "$@"; do last=$arg; done

    files=""
    n=$#
    i=0
    for arg in "$@"; do
        i=$((i + 1))
        [ "$i" -lt "$n" ] && files="$files $arg"
    done

    vm_ssh mkdir -p "$last"
    # shellcheck disable=SC2086
    scp $ssh_opts -q -r -P "$VM_SSH_PORT" $files "debian@127.0.0.1:$last/"
}

down() {
    if ! running; then
        say "машина не запущена"
        rm -f "$pidfile"
        return 0
    fi

    pid=$(cat "$pidfile")
    vm_ssh sudo systemctl poweroff >/dev/null 2>&1 || true

    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 30 ]; do
        n=$((n + 1))
        sleep 2
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        say "машина не выключилась за минуту, qemu остановлен сигналом"
    else
        say "машина выключена"
    fi

    rm -f "$pidfile"
}

destroy() {
    down
    rm -f "$disk" "$seed" "$dir/user-data" "$dir/meta-data" "$dir/console.log"
    say "диск снесён: следующий up поднимет чистую машину"
}

status() {
    if running; then
        say "работает, pid $(cat "$pidfile")"
    else
        say "не запущена"
    fi

    say "ssh:    127.0.0.1:$VM_SSH_PORT (native/vm.sh ssh)"
    say "http:   http://127.0.0.1:$VM_HTTP_PORT"
    say "https:  https://127.0.0.1:$VM_HTTPS_PORT"
    say "панель: http://127.0.0.1:$VM_PANEL_PORT"

    if [ -n "${VM_PANEL_PUBLIC:-}" ]; then
        say "панель снаружи: http://$VM_PANEL_PUBLIC"
    fi
}

cmd=${1:-status}
[ $# -gt 0 ] && shift

case "$cmd" in
    up)      up ;;
    wait)    wait_ssh "$@" ;;
    ssh)     vm_ssh "$@" ;;
    copy)    copy "$@" ;;
    down)    down ;;
    restart) down; up ;;
    destroy) destroy ;;
    status)  status ;;
    *)       die "неизвестная команда: $cmd (up, wait, ssh, copy, down, restart, destroy, status)" ;;
esac
