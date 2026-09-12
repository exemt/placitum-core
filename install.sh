#!/bin/sh
# Установка Placitum: окружение, секреты, инфраструктура, компоненты.
#
#     ./install.sh check       только проверки: чем и куда ставим
#     ./install.sh install     всё по порядку
#     ./install.sh infra       поднять одну инфраструктуру
#     ./install.sh status      что поднято и как себя чувствует
#     ./install.sh down        остановить (тома и данные не трогает)
#
# Ключи:
#     --sources <файл>   откуда брать исходники компонентов; умолчание sources.env
#     --no-build         не пересобирать образы (только поднять уже собранные)
#
# Образы собираются здесь же, из исходников: готовых никто не раздаёт
# (docs/delivery.md). Поэтому машине установки нужна сеть до репозиториев,
# базовых образов и прокси модулей Go.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
env_file="$here/.env"
sources="$here/sources.env"
build=yes
cmd=${1:-help}
[ $# -gt 0 ] && shift || true

while [ $# -gt 0 ]; do
    case "$1" in
        --sources) sources=$2; shift 2 ;;
        --no-build) build=no; shift ;;
        *) printf 'неизвестный ключ: %s\n' "$1" >&2; exit 2 ;;
    esac
done

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf '!! %s\n' "$*" >&2; exit 1; }

compose() {
    file=$1
    shift
    docker compose --env-file "$env_file" --env-file "$sources" -f "$here/compose/$file" "$@"
}

# --- проверки -------------------------------------------------------------

preflight() {
    say "проверки"

    command -v docker >/dev/null 2>&1 || die "нет docker"
    docker info >/dev/null 2>&1 || die "docker есть, но демон не отвечает"

    version=$(docker compose version --short 2>/dev/null) ||
        die "нет docker compose v2 (плагин compose)"

    major=$(printf '%s' "$version" | sed 's/^v//; s/\..*//')
    minor=$(printf '%s' "$version" | sed 's/^v//; s/^[0-9]*\.//; s/[^0-9].*//')

    if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "${minor:-0}" -lt 20 ]; }; then
        die "нужен docker compose 2.20 или новее (есть $version): установка держится на include"
    fi

    printf 'docker compose %s\n' "$version"

    command -v openssl >/dev/null 2>&1 || die "нет openssl: им выпускается ключ контура"

    # Место: сборка из исходников -- это базовые образы, кеш Go и слои.
    # Двадцати гигабайт хватает на контур без модели vlai.
    free=$(df -Pk "$here" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}')
    if [ -n "${free:-}" ] && [ "$free" -lt 20 ]; then
        warn "свободно ${free} ГБ: сборке контура нужно около 20"
    fi

    [ -f "$sources" ] || die "нет файла источников: $sources"
    printf 'источники: %s\n' "$sources"
}

# --- окружение и секреты --------------------------------------------------

prepare_env() {
    say "окружение"

    if [ ! -f "$env_file" ]; then
        cp "$here/.env.example" "$env_file"
        printf 'заведён %s из .env.example -- проверьте порты и реквизиты\n' "$env_file"
    else
        printf 'окружение на месте: %s\n' "$env_file"
    fi

    say "секреты"
    # shellcheck disable=SC1090
    . "$env_file"
    MINIO_ROOT_USER=${MINIO_ROOT_USER:-waf} MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-wafwafwaf} \
        sh "$here/bootstrap/secrets.sh"

    # Отпечаток ключа зашивается в панель на сборке: пин, отставший от ключа,
    # выключает сверку публичного ключа в браузере.
    fp=$(sh "$here/bootstrap/secrets.sh" --fingerprint)
    set_env VITE_CONTOUR_FINGERPRINT "$fp"

    # Имя ноды живёт в двух местах: окружение агента и конфиг модуля. Держим
    # их вместе, иначе панель покажет ноду под одним именем, а аудит -- под другим.
    node_id=${PLC_NODE_ID:-edge-01}
    printf '%s\n' \
        "# Идентичность узла для модуля. Значение ведёт PLC_NODE_ID из .env --" \
        "# install.sh переписывает этот файл. Шину печатает поколение контроллера." \
        "waf_node_id $node_id;" > "$here/config/edge/node.conf"
    printf 'узел: %s\n' "$node_id"
}

# Переписывает одну строку в .env, не трогая остальные.
set_env() {
    name=$1
    value=$2
    tmp="$env_file.tmp"

    if grep -q "^$name=" "$env_file" 2>/dev/null; then
        sed "s|^$name=.*|$name=$value|" "$env_file" > "$tmp" && mv "$tmp" "$env_file"
    else
        printf '%s=%s\n' "$name" "$value" >> "$env_file"
    fi
}

# --- шаги установки -------------------------------------------------------

infra() {
    say "инфраструктура"
    compose infra.yml up -d --wait
}

migrate() {
    say "схема базы"

    if [ -x "$here/bootstrap/migrate.sh" ]; then
        sh "$here/bootstrap/migrate.sh"
        return
    fi

    warn "накатчика схемы Postgres ещё нет (core/migrate/README.md)."
    warn "База поднимется пустой, и контроллер на ней не заработает."
    warn "Пока: применить controller/schema вручную или дождаться накатчика."
}

components() {
    say "компоненты"

    if [ "$build" = yes ]; then
        compose waf.yml up -d --build --wait
    else
        compose waf.yml up -d --wait
    fi
}

status() {
    say "состояние"
    compose waf.yml ps

    . "$env_file"
    printf '\nпанель:  http://localhost:%s\n' "${PLC_PANEL_PORT:-8080}"
    printf 'трафик:  http://localhost:%s\n' "${PLC_HTTP_PORT:-80}"
}

case "$cmd" in
    check)
        preflight
        ;;
    install)
        preflight
        prepare_env
        infra
        migrate
        components
        status
        ;;
    infra)
        preflight
        prepare_env
        infra
        ;;
    status)
        status
        ;;
    down)
        say "остановка"
        compose waf.yml down
        ;;
    help|-h|--help)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "неизвестная команда: $cmd (см. ./install.sh help)"
        ;;
esac
