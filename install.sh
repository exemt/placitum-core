#!/bin/sh
# Установка Placitum: окружение, секреты, инфраструктура, компоненты, панель.
#
#     ./install.sh check       только проверки: чем и куда ставим
#     ./install.sh install     всё по порядку
#     ./install.sh infra       поднять одну инфраструктуру
#     ./install.sh panel       завести панель за калиткой на поднятом контуре
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

# Версия и ревизия сборки: едут в образы метками OCI и в бинарь каждого
# процесса -- их видно в журнале старта и в кадре присутствия. Версия -- тег
# core, если установка стоит на теге, иначе dev; ревизия -- коммит core.
PLC_VERSION=${PLC_VERSION:-$(git -C "$here" describe --tags --exact-match 2>/dev/null || echo dev)}
PLC_REVISION=${PLC_REVISION:-$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)}
export PLC_VERSION PLC_REVISION
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

    # Движок до 28 пропускал соседей по сети к контейнерам в обход публикации:
    # порт на 127.0.0.1 или на внутреннем адресе был достижим по адресу
    # контейнера в bridge. Панель и порты инфраструктуры держатся на этой границе.
    engine=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)

    case "${engine%%.*}" in
        ''|*[!0-9]*)
            warn "не удалось узнать версию docker engine"
            ;;
        *)
            printf 'docker engine %s\n' "$engine"
            [ "${engine%%.*}" -ge 28 ] ||
                warn "docker engine $engine: до 28 контейнеры достижимы из сети в обход публикации портов -- обновите движок"
            ;;
    esac

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

# Чей адрес: частные сети и loopback против всего остального.
addr_kind() {
    case "$1" in
        127.*) echo loopback ;;
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*) echo частный ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) echo частный ;;
        *) echo публичный ;;
    esac
}

# Адреса машины, из которых выбирают PLC_PANEL_BIND. Мосты docker не в счёт:
# на них панель не публикуют.
host_addrs() {
    command -v ip >/dev/null 2>&1 || return 0

    printf 'адреса машины:\n'
    ip -o -4 addr show | while read -r _ dev _ cidr _; do
        case "$dev" in docker0|br-*|veth*) continue ;; esac
        printf '  %-16s %-12s %s\n' "${cidr%/*}" "$dev" "$(addr_kind "${cidr%/*}")"
    done
}

# Адрес панели на хосте. Docker публикует порт только на адрес, который есть на
# машине, а порт панели висит на узле защиты: чужой адрес не даст подняться
# узлу, и вместе с панелью ляжет трафик.
check_panel() {
    say "панель"

    # shellcheck disable=SC1090
    if [ -f "$env_file" ]; then . "$env_file"; else . "$here/.env.example"; fi

    bind=${PLC_PANEL_BIND:-127.0.0.1}
    port=${PLC_PANEL_PORT:-8081}

    case "$bind" in
        *:*)
            die "PLC_PANEL_BIND=$bind: нужен адрес IPv4"
            ;;
        127.0.0.1)
            printf 'панель только с этой машины: http://127.0.0.1:%s (снаружи -- ssh -L)\n' "$port"
            ;;
        0.0.0.0)
            warn "панель на всех адресах машины, в том числе внешних: вход по паролю, но лучше назвать внутренний адрес"
            host_addrs
            ;;
        *)
            if command -v ip >/dev/null 2>&1 &&
                ! ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx "$bind"; then
                host_addrs
                die "PLC_PANEL_BIND=$bind: такого адреса на машине нет -- узел защиты не поднимется, а с ним и трафик"
            fi

            [ "$(addr_kind "$bind")" = публичный ] &&
                warn "панель на публичном адресе $bind: пока она по HTTP, пароль ходит открытым текстом"

            printf 'панель: http://%s:%s\n' "$bind" "$port"
            ;;
    esac
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

# Инфраструктуру поднимает та же модель, что и компоненты (waf.yml включает
# infra.yml и выбор портов): отдельный запуск infra.yml дал бы контейнеры без
# портов, и шаг с компонентами пересоздал бы их заново.
infra_services="nats nats-box postgres clickhouse redis redis-internal minio minio-mc"

infra() {
    say "инфраструктура"
    # shellcheck disable=SC2086
    compose waf.yml up -d --wait $infra_services
}

# Схему Postgres накатывает контроллер -- она едет в его образе, и он же
# делает это при каждом старте. Отдельный шаг здесь нужен ради порядка и
# отчёта: сначала схема, потом процессы, и видно, что именно применилось.
# --no-deps: инфраструктура уже поднята предыдущим шагом, а зависимости
# сервиса controller потянули бы за собой половину контура.
migrate() {
    say "схема базы"

    if [ "$build" = yes ]; then
        compose waf.yml build controller
    fi

    compose waf.yml run --rm --no-deps controller node src/migrate.ts --check
    compose waf.yml run --rm --no-deps controller node src/migrate.ts
}

components() {
    say "компоненты"

    if [ "$build" = yes ]; then
        compose waf.yml up -d --build --wait
    else
        compose waf.yml up -d --wait
    fi
}

# Панель за калиткой: на узле сервер panel, на нём калитка auth со списком
# panel_users, в списке admin. Объекты заводит bootstrap/panel.mjs через API
# изнутри контейнера контроллера: у машины установки нет обещанных curl и
# python, а у контроллера есть node и сам API. Пароль admin выпускается здесь,
# как прочие секреты: в список едет только bcrypt, открытый -- в secrets/.
panel() {
    say "панель"

    pass_file="$here/secrets/panel-admin.password"
    fresh=no

    if [ ! -s "$pass_file" ]; then
        (umask 077 && openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-20 > "$pass_file")
        fresh=yes
    fi

    # stdout скрипта -- одно слово: created или kept, ход работы -- в stderr.
    # Упал -- файл пароля не трогаем: admin мог успеть завестись именно с ним.
    admin=$(compose waf.yml exec -T controller node --input-type=module \
        -e "$(cat "$here/bootstrap/panel.mjs")" < "$pass_file") ||
        die "панель за калиткой не встала; контроллер напрямую -- http://127.0.0.1:${PLC_CONTROLLER_PORT:-8080}"

    case "$admin" in
        created)
            printf '\nвход в панель: admin / %s\n' "$(cat "$pass_file")"
            printf 'пароль сохранён в %s\n' "$pass_file"
            ;;
        kept)
            # Пароль, выпущенный сейчас, никому не достался: список уже был.
            [ "$fresh" = yes ] && rm -f "$pass_file"
            printf 'пользователи панели уже заведены: пароль не трогаю\n'
            ;;
        *)
            die "bootstrap/panel.mjs ответил неожиданно: $admin"
            ;;
    esac
}

status() {
    say "состояние"
    compose waf.yml ps

    # shellcheck disable=SC1090
    . "$env_file"
    bind=${PLC_PANEL_BIND:-127.0.0.1}
    [ "$bind" = 0.0.0.0 ] && bind='<адрес машины>'

    login="вход admin"
    [ -f "$here/secrets/panel-admin.password" ] &&
        login="$login, пароль установки -- secrets/panel-admin.password"

    printf '\nпанель:  http://%s:%s -- %s\n' "$bind" "${PLC_PANEL_PORT:-8081}" "$login"
    printf 'API:     http://127.0.0.1:%s -- без калитки, только с этой машины (снаружи -- ssh -L)\n' \
        "${PLC_CONTROLLER_PORT:-8080}"
    printf 'трафик:  http://localhost:%s\n' "${PLC_HTTP_PORT:-80}"
}

case "$cmd" in
    check)
        preflight
        check_panel
        ;;
    install)
        preflight
        prepare_env
        check_panel
        infra
        migrate
        components
        panel
        status
        ;;
    infra)
        preflight
        prepare_env
        infra
        ;;
    panel)
        [ -f "$env_file" ] || die "нет $env_file: панель заводится на поставленном контуре (./install.sh install)"
        # shellcheck disable=SC1090
        . "$env_file"
        panel
        ;;
    status)
        status
        ;;
    down)
        say "остановка"
        compose waf.yml down
        ;;
    help|-h|--help)
        sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "неизвестная команда: $cmd (см. ./install.sh help)"
        ;;
esac
