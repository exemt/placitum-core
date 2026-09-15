#!/bin/sh
# Витрина shop на самом хосте -- приложение, которое защищает машина native/vm.sh.
# Машина видит хост по адресу шлюза QEMU, поэтому апстрим в её панели --
# 10.0.2.2:18090. Порт -- только на loopback хоста.
#
#     native/testapp.sh up       поднять из образа placitum/testapp
#     native/testapp.sh down     убрать контейнер
#     native/testapp.sh status   жива ли
#
# Образ placitum/testapp -- тестовое приложение платформы, его собирает рабочее
# место разработки (e2e, сервис app). Здесь он только запускается, отдельным
# контейнером со своим именем и портом, чтобы не спорить с e2e.

set -eu

name=native-testapp
image=${TESTAPP_IMAGE:-placitum/testapp}
port=${TESTAPP_PORT:-18090}

say() { printf '%s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

status() {
    state=$(docker container inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "нет контейнера")
    say "витрина: $state; на хосте http://127.0.0.1:$port, из машины http://10.0.2.2:$port"
}

up() {
    if docker container inspect "$name" >/dev/null 2>&1; then
        docker start "$name" >/dev/null
    else
        docker image inspect "$image" >/dev/null 2>&1 || die "нет образа $image: его собирает e2e (сервис app)"
        docker run -d --name "$name" --restart unless-stopped --cpus 1 --memory 512m \
            -e APP_NAME=shop -e APP_LOG=info -p "127.0.0.1:$port:8080" "$image" >/dev/null
    fi

    # --retry-all-errors, а не --retry-connrefused: пока Node не слушает, docker-proxy
    # соединение принимает и сбрасывает, а сброс (56) connrefused не повторяет. Без -S:
    # ошибки попыток, прошедших на повторе, выглядели бы сбоем.
    curl -fs --retry 20 --retry-all-errors --retry-delay 1 -o /dev/null "http://127.0.0.1:$port/healthz" ||
        die "витрина не ответила на /healthz: docker logs $name"

    status
}

down() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    say "витрина убрана"
}

case "${1:-status}" in
    up)     up ;;
    down)   down ;;
    status) status ;;
    *)      die "неизвестная команда: $1 (up, down, status)" ;;
esac
