#!/bin/sh
# Установка Placitum: окружение, секреты, инфраструктура, компоненты, панель.
#
#     ./install.sh check            только проверки: чем и куда ставим
#     ./install.sh install          всё по порядку
#     ./install.sh infra            поднять одну инфраструктуру
#     ./install.sh panel            завести панель за калиткой на поднятом контуре
#     ./install.sh panel-password   сменить пароль admin панели и снять блокировку
#     ./install.sh status           что поднято и как себя чувствует
#     ./install.sh down             остановить (тома и данные не трогает)
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

# --- пароль admin панели --------------------------------------------------

# Пароль нигде не хранится: живёт в памяти этого процесса, до базы
# контроллера доезжает bcrypt. Спрашивается до сборки, чтобы установка не
# ждала ввода после долгой сборки. Без терминала -- PLC_PANEL_PASSWORD из
# окружения; пусто и там -- пароль сгенерирует шаг панели и покажет один раз.
panel_pass=""

read_secret() {
    printf '%s' "$1" >&2
    stty -echo 2>/dev/null || true
    IFS= read -r secret || secret=""
    stty echo 2>/dev/null || true
    printf '\n' >&2
    printf '%s' "$secret"
}

# ask_panel_password <подсказка к пустому вводу>
ask_panel_password() {
    if [ -n "${PLC_PANEL_PASSWORD:-}" ]; then
        [ "${#PLC_PANEL_PASSWORD}" -ge 8 ] || die "PLC_PANEL_PASSWORD: не короче 8 символов"
        panel_pass=$PLC_PANEL_PASSWORD
        printf 'пароль admin панели: из PLC_PANEL_PASSWORD\n'
        return 0
    fi

    [ -t 0 ] || return 0

    # Прерванный ввод не должен оставить терминал без эха.
    trap 'stty echo 2>/dev/null' EXIT INT TERM

    while :; do
        first=$(read_secret "пароль admin панели ($1): ")
        [ -n "$first" ] || break

        if [ "${#first}" -lt 8 ]; then
            warn "не короче 8 символов"
            continue
        fi

        second=$(read_secret "ещё раз: ")

        if [ "$first" = "$second" ]; then
            panel_pass=$first
            break
        fi

        warn "не совпало, ещё раз"
    done

    trap - EXIT INT TERM
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
# panel_users, в списке admin. Объекты и пароль заводит bootstrap/panel.mjs
# через API изнутри контейнера контроллера: у машины установки нет обещанных
# curl и python, а у контроллера есть node, bcrypt и сам API.
#
# panel [ensure|reset]: ensure заводит admin только в пустой список и меняет
# пароль, лишь если его ввели; reset меняет всегда, при пустом -- генерирует.
panel() {
    say "панель"

    # stdin -- пароль (может быть пустым); stdout -- одна строка: created,
    # updated, kept или generated <пароль>. Ход работы -- в stderr.
    result=$(printf '%s' "$panel_pass" |
        compose waf.yml exec -T -e "PANEL_ADMIN=${1:-ensure}" controller \
            node --input-type=module -e "$(cat "$here/bootstrap/panel.mjs")") ||
        die "панель за калиткой не встала; контроллер напрямую -- http://127.0.0.1:${PLC_CONTROLLER_PORT:-8080}"

    case "$result" in
        created)
            printf 'admin заведён с введённым паролем\n'
            ;;
        updated)
            printf 'пароль admin сменён\n'
            ;;
        kept)
            printf 'admin уже есть, пароль прежний (сменить -- ./install.sh panel-password)\n'
            ;;
        "generated "*)
            printf '\nвход в панель: admin / %s\n' "${result#generated }"
            printf 'пароль нигде не сохранён: запишите его или смените -- ./install.sh panel-password\n'
            ;;
        *)
            die "bootstrap/panel.mjs ответил неожиданно: $result"
            ;;
    esac
}

# Смена пароля -- она же аварийный вход: снимаются и блокировки калитки
# панели по логину и по адресу, иначе забывший пароль ждал бы ещё 15 минут.
panel_password() {
    ask_panel_password "Enter -- сгенерировать"
    panel reset

    compose waf.yml exec -T redis-internal sh -c \
        "redis-cli --scan --pattern 'auth:*:panel/*' | xargs -r redis-cli del >/dev/null" &&
        printf 'блокировки входа в панель сняты\n'
}

status() {
    say "состояние"
    compose waf.yml ps

    # shellcheck disable=SC1090
    . "$env_file"
    bind=${PLC_PANEL_BIND:-127.0.0.1}
    [ "$bind" = 0.0.0.0 ] && bind='<адрес машины>'

    printf '\nпанель:  http://%s:%s -- вход admin, сменить пароль -- ./install.sh panel-password\n' \
        "$bind" "${PLC_PANEL_PORT:-8081}"
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
        ask_panel_password "Enter -- оставить прежний или сгенерировать при первой установке"
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
    panel|panel-password)
        [ -f "$env_file" ] || die "нет $env_file: панель заводится на поставленном контуре (./install.sh install)"
        # shellcheck disable=SC1090
        . "$env_file"

        if [ "$cmd" = panel ]; then
            panel
        else
            panel_password
        fi
        ;;
    status)
        status
        ;;
    down)
        say "остановка"
        compose waf.yml down
        ;;
    help|-h|--help)
        sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "неизвестная команда: $cmd (см. ./install.sh help)"
        ;;
esac
