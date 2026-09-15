#!/bin/sh
# Пакеты .deb для установки без Docker -- из тех же образов, что собирает install.sh.
#
#     native/build.sh          собрать пакеты в native/work/packages
#
# Образ здесь -- среда сборки, из которой берутся готовые файлы: Go-бинарники в
# нём статические, модуль nginx зависит только от libc, контроллер -- JavaScript
# без нативных модулей. Пакет раскладывает их по путям Debian и добавляет юниты
# systemd. Адресов, паролей и числа копий в пакетах нет: это пишет install.sh.
#
# Образы берутся локальные, с теми тегами, что ставит сборка install.sh (docker
# image ls). Сам этот скрипт из git ничего не собирает.
#
# Окружение юнита берётся из окружения образа: пути /app и /var/lib/waf/<x>
# переезжают в каталоги процесса, а адреса, порты и реквизиты не переносятся --
# их пишет install.sh в /etc/placitum/env, и они главнее.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core=$(dirname "$here")
work="$here/work"
out="$work/packages"
stage="$work/stage"
version=${PKG_VERSION:-0.1~dev$(date -u +%Y%m%d%H%M)}

# Сторонние бинарники -- те же, что поднимает compose/infra.yml.
IMG_NATS=nats:2.12-alpine
IMG_NATS_BOX=natsio/nats-box:latest
IMG_MINIO=quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z
IMG_MC=quay.io/minio/mc:latest

# Сборка nginx.org той же версии, против исходников которой собран модуль.
NGINX_DEB=1.28.0-1~trixie

units=usr/lib/systemd/system

say() { printf '%s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

# extract <образ> <путь в образе> <куда>: файл или каталог без запуска контейнера.
extract() {
    cid=$(docker create "$1") || die "нет образа $1"
    mkdir -p "$(dirname "$3")"

    if ! docker cp "$cid:$2" "$3" >/dev/null; then
        docker rm "$cid" >/dev/null
        die "$1: нет $2"
    fi

    docker rm "$cid" >/dev/null
}

# which_in <образ> <команда>: где команда лежит в образе.
which_in() {
    docker run --rm --network none --entrypoint sh "$1" -c "command -v $2" || die "$1: нет $2"
}

label() {
    docker image inspect "$1" --format "{{index .Config.Labels \"org.opencontainers.image.$2\"}}"
}

# stamp <каталог> <образ>: метка сборки; по ней app-sync пересоздаёт копии процессов.
stamp() {
    printf 'version=%s\nimage=%s\nrevision=%s\n' "$version" "$2" "$(label "$2" revision)" > "$1/.build"
}

# env_lines <образ> <каталог app> <каталог данных>: окружение образа строками юнита.
env_lines() {
    docker image inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' |
    awk -v app="$2" -v data="$3" '
        /^$/ { next }
        {
            i = index($0, "="); k = substr($0, 1, i - 1); v = substr($0, i + 1)
            if (k ~ /^(PATH|NODE_VERSION|YARN_VERSION|NGINX_VERSION|NJS_VERSION|NJS_RELEASE|PKG_RELEASE|DYNPKG_RELEASE)$/) next
            if (v ~ /:\/\// || v ~ /^:/) next
            if (k ~ /(LISTEN|_HTTP|_GRPC|_ADDR|ENDPOINT|ACCESS_KEY|SECRET_KEY|PASSWORD|DATABASE_URL|_PORT)$/) next
            if (v ~ /^\/app(\/|$)/) {
                if (app == "") next
                v = app substr(v, 5)
            } else if (v ~ /^\/var\/lib\/waf\/[^\/]+/) {
                sub(/^\/var\/lib\/waf\/[^\/]+/, "", v)
                v = data v
            }
            printf "Environment=\"%s=%s\"\n", k, v
        }'
}

# proc <stage> <юнит> <описание> <образ> <бинарь> <app> <after> [env…]
#
# <юнит> с @ на конце -- шаблон копий, процесс называется <юнит>-%i.
# <app>: - -- без каталога; sync:<компонент> -- своя копия
# /usr/share/placitum/<компонент> у процесса; ro:<каталог> -- общий, только чтение.
# [env…] -- файлы /etc/placitum/env/<имя>.env, после common.env.
proc() {
    st=$1 unit=$2 desc=$3 img=$4 bin=$5 app=$6 after=$7
    shift 7

    case "$unit" in
        *@) id="${unit%@}-%i" ;;
        *)  id=$unit ;;
    esac

    state=/var/lib/placitum/$id
    appdir=""
    pre=""
    wd=""

    case "$app" in
        -)
            ;;
        sync:*)
            appdir=$state/app
            pre="ExecStartPre=+/usr/lib/placitum/bin/app-sync ${app#sync:} $id"
            wd="WorkingDirectory=-$appdir"
            ;;
        ro:*)
            appdir=${app#ro:}
            wd="WorkingDirectory=$appdir"
            ;;
        *)
            die "proc $unit: непонятный app $app"
            ;;
    esac

    mkdir -p "$st/$units"

    {
        printf '[Unit]\nDescription=Placitum: %s\nPartOf=placitum.target\n' "$desc"
        printf 'After=network-online.target %s\nWants=network-online.target\n\n' "$after"
        printf '[Service]\nUser=placitum\nGroup=placitum\n'
        printf 'StateDirectory=placitum/%s placitum/%s/data\n' "$id" "$id"
        if [ -n "$pre" ]; then printf '%s\n' "$pre"; fi
        if [ -n "$wd" ]; then printf '%s\n' "$wd"; fi
        env_lines "$img" "$appdir" "$state/data"
        printf 'Environment="WAF_LOG_WRITER=%s"\n' "$id"
        for f in common "$@"; do
            printf 'EnvironmentFile=-/etc/placitum/env/%s.env\n' "$f"
        done
        printf 'ExecStart=/usr/lib/placitum/bin/%s\n' "$bin"
        printf 'Restart=always\nRestartSec=2\n\n[Install]\nWantedBy=placitum.target\n'
    } > "$st/$units/placitum-$unit.service"
}

# deb <stage> <пакет> <Depends> <описание> [строки postinst]
deb() {
    st=$1 pkg=$2 depends=$3 desc=$4 extra=${5:-}

    mkdir -p "$st/DEBIAN"

    {
        printf 'Package: %s\nVersion: %s\nArchitecture: amd64\n' "$pkg" "$version"
        printf 'Maintainer: Placitum native build <build@placitum.invalid>\n'
        printf 'Section: net\nPriority: optional\n'
        if [ -n "$depends" ]; then printf 'Depends: %s\n' "$depends"; fi
        printf 'Description: %s\n' "$desc"
    } > "$st/DEBIAN/control"

    {
        printf '#!/bin/sh\nset -e\n'
        if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
        printf 'if [ -d /run/systemd/system ]; then systemctl daemon-reload || true; fi\n'
    } > "$st/DEBIAN/postinst"
    chmod 0755 "$st/DEBIAN/postinst"

    dpkg-deb --root-owner-group -Zxz --build "$st" "$out/${pkg}_${version}_amd64.deb" >/dev/null ||
        die "dpkg-deb: $pkg"

    printf '  %-22s %s\n' "$pkg" "$(du -h "$out/${pkg}_${version}_amd64.deb" | cut -f1)"
}

# inspector <компонент> <образ> <описание> [описание формы <компонент>-http]
inspector() {
    comp=$1 img=$2 desc=$3 http=${4:-}
    st=$stage/$comp

    for bin in "$comp" "$comp-probe" ${http:+"$comp-http"}; do
        extract "$img" "/usr/local/bin/$bin" "$st/usr/lib/placitum/bin/$bin"
    done

    extract "$img" /app "$st/usr/share/placitum/$comp"
    stamp "$st/usr/share/placitum/$comp" "$img"

    proc "$st" "$comp@" "инспектор $comp, копия %i" "$img" "$comp" "sync:$comp" \
        "placitum-nats.service placitum-redis@exchange.service placitum-redis@internal.service placitum-geo.service" \
        "$comp"

    if [ -n "$http" ]; then
        proc "$st" "$comp-http" "$http" "$img" "$comp-http" "sync:$comp" \
            "placitum-redis@internal.service placitum-controller.service" "$comp-http"
    fi

    deb "$st" "placitum-$comp" "placitum-common" "Placitum: $desc"
}

command -v docker >/dev/null 2>&1 || die "нужен docker: образы -- источник файлов"
command -v dpkg-deb >/dev/null 2>&1 || die "нужен dpkg-deb"
command -v node >/dev/null 2>&1 || die "нужен node: им собирается шаг панели"
[ -f "$core/bootstrap/panel.mjs" ] || die "не репозиторий core: нет $core/bootstrap/panel.mjs"

rm -rf "$stage" "$out"
mkdir -p "$stage" "$out"

say "== пакеты $version -> $out"

# --- общее -----------------------------------------------------------------

st=$stage/common
mkdir -p "$st/usr/lib/placitum/bin" "$st/usr/share/placitum/bootstrap" \
    "$st/usr/share/placitum/config/clickhouse" "$st/usr/share/placitum/config/minio" \
    "$st/usr/lib/tmpfiles.d" "$st/$units"

install -m 0755 "$here/pkg/app-sync.sh" "$st/usr/lib/placitum/bin/app-sync"
install -m 0644 "$core/bootstrap/secrets.sh" "$core/bootstrap/streams.sh" "$st/usr/share/placitum/bootstrap/"
install -m 0644 "$core/config/edge/agent.conf" "$core/config/nats/nats-server.conf" "$st/usr/share/placitum/config/"
install -m 0644 "$core/config/clickhouse/logger.xml" "$core/config/clickhouse/system-logs.xml" \
    "$st/usr/share/placitum/config/clickhouse/"
install -m 0644 "$core/config/minio/lifecycle.json" "$st/usr/share/placitum/config/minio/"

cat > "$st/usr/lib/tmpfiles.d/placitum.conf" <<'EOF'
# Сокеты узла (вердикты и журнал nginx) и хранилище его поколений.
d /run/waf 0755 root root -
d /var/lib/waf/store 0755 root root -
EOF

cat > "$st/$units/placitum.target" <<'EOF'
[Unit]
Description=Placitum: весь контур
Wants=network-online.target
After=network-online.target

[Install]
WantedBy=multi-user.target
EOF

# Экземпляры: exchange -- обменник (6379), internal -- внутренний Redis (6380).
cat > "$st/$units/placitum-redis@.service" <<'EOF'
[Unit]
Description=Placitum: Redis %i
PartOf=placitum.target
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=redis
Group=redis
StateDirectory=placitum/redis-%i
ExecStart=/usr/bin/redis-server /etc/placitum/redis/%i.conf --supervised systemd --daemonize no
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=placitum.target
EOF

deb "$st" placitum-common "adduser" "Placitum: пользователь, каталоги и общие файлы установки" '
if ! getent group placitum >/dev/null; then addgroup --system placitum; fi
if ! getent passwd placitum >/dev/null; then
    adduser --system --ingroup placitum --home /var/lib/placitum --no-create-home placitum
fi
mkdir -p /etc/placitum /var/lib/placitum
systemd-tmpfiles --create placitum.conf || true'

# --- шина ------------------------------------------------------------------

st=$stage/nats
extract "$IMG_NATS" "$(which_in "$IMG_NATS" nats-server)" "$st/usr/lib/placitum/bin/nats-server"
extract "$IMG_NATS_BOX" "$(which_in "$IMG_NATS_BOX" nats)" "$st/usr/lib/placitum/bin/nats"
mkdir -p "$st/$units"

cat > "$st/$units/placitum-nats.service" <<'EOF'
[Unit]
Description=Placitum: шина NATS
PartOf=placitum.target
After=network-online.target
Wants=network-online.target

[Service]
User=placitum
Group=placitum
StateDirectory=placitum/nats
ExecStart=/usr/lib/placitum/bin/nats-server --config /etc/placitum/nats/nats-server.conf
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=placitum.target
EOF

deb "$st" placitum-nats "placitum-common" "Placitum: шина NATS и её клиент nats"

# --- архив -----------------------------------------------------------------

st=$stage/minio
extract "$IMG_MINIO" "$(which_in "$IMG_MINIO" minio)" "$st/usr/lib/placitum/bin/minio"
extract "$IMG_MC" "$(which_in "$IMG_MC" mc)" "$st/usr/lib/placitum/bin/mc"
mkdir -p "$st/$units"

cat > "$st/$units/placitum-minio.service" <<'EOF'
[Unit]
Description=Placitum: архив тел, MinIO
PartOf=placitum.target
After=network-online.target
Wants=network-online.target

[Service]
User=placitum
Group=placitum
StateDirectory=placitum/minio
EnvironmentFile=/etc/placitum/env/minio.env
ExecStart=/usr/lib/placitum/bin/minio server /var/lib/placitum/minio --address 127.0.0.1:9100 --console-address 127.0.0.1:9101
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=placitum.target
EOF

deb "$st" placitum-minio "placitum-common" "Placitum: локальный S3 архива (MinIO) и клиент mc"

# --- узел ------------------------------------------------------------------

st=$stage/edge
extract placitum-edge /etc/nginx/modules/ngx_http_waf_module.so "$st/usr/lib/nginx/modules/ngx_http_waf_module.so"
extract placitum-edge /usr/local/bin/waf-agent "$st/usr/lib/placitum/bin/waf-agent"
extract placitum-edge /usr/share/waf/pages "$st/usr/share/waf/pages"
mkdir -p "$st/$units"

cat > "$st/$units/placitum-edge.service" <<'EOF'
[Unit]
Description=Placitum: агент узла защиты (nginx с модулем)
PartOf=placitum.target
After=network-online.target nginx.service placitum-nats.service
Wants=network-online.target nginx.service

[Service]
# root: агент пишет поколение в /etc/nginx и шлёт nginx reload.
StateDirectory=placitum/edge
EnvironmentFile=-/etc/placitum/env/common.env
EnvironmentFile=-/etc/placitum/env/edge.env
ExecStart=/usr/lib/placitum/bin/waf-agent
Restart=always
RestartSec=2

[Install]
WantedBy=placitum.target
EOF

deb "$st" placitum-edge "placitum-common, nginx (= $NGINX_DEB)" "Placitum: модуль nginx, агент узла, страницы отказа"

# --- контроллер ------------------------------------------------------------

st=$stage/controller
app=/usr/lib/placitum/controller
extract placitum-controller /app "$st$app"
rm -rf "$st$app/data"

# Пин отпечатка ключа контура зашит в сборку панели. Ключ у установки свой,
# поэтому install.sh подменяет пин; прежний лежит в PIN.
pins=$(grep -rhoE 'sha256:[0-9a-f]{64}' "$st$app/ux/dist" | sort -u)
[ "$(printf '%s\n' "$pins" | grep -c .)" -eq 1 ] ||
    die "контроллер: в сборке панели ждал один пин отпечатка, нашлось: ${pins:-ни одного}"
printf '%s\n' "$pins" > "$st$app/PIN"

mkdir -p "$st$app/bootstrap"
node "$here/pkg/patch-panel.mjs" "$core/bootstrap/panel.mjs" > "$st$app/bootstrap/panel.mjs" ||
    die "шаг панели не собрался"
install -m 0644 "$core/bootstrap/publish.mjs" "$here/pkg/tune.mjs" "$st$app/bootstrap/"

mkdir -p "$st/$units"
{
    printf '[Unit]\nDescription=Placitum: контроллер, API и панель\nPartOf=placitum.target\n'
    printf 'After=network-online.target postgresql.service placitum-nats.service placitum-redis@internal.service\n'
    printf 'Wants=network-online.target\n\n'
    printf '[Service]\nUser=placitum\nGroup=placitum\n'
    printf 'StateDirectory=placitum/controller placitum/controller/compile\n'
    printf 'WorkingDirectory=%s\n' "$app"
    env_lines placitum-controller "$app" /var/lib/placitum/controller
    printf 'EnvironmentFile=-/etc/placitum/env/common.env\nEnvironmentFile=-/etc/placitum/env/controller.env\n'
    printf 'ExecStart=/usr/bin/node src/main.ts\nRestart=always\nRestartSec=2\n\n'
    printf '[Install]\nWantedBy=placitum.target\n'
} > "$st/$units/placitum-controller.service"

deb "$st" placitum-controller "placitum-common, nodejs (>= 22.18)" "Placitum: контроллер, API и панель"

# --- логгер и поиск --------------------------------------------------------

st=$stage/logger
extract placitum/logger /usr/local/bin/waf-logger "$st/usr/lib/placitum/bin/waf-logger"
extract placitum/logger /usr/local/bin/waf-search "$st/usr/lib/placitum/bin/waf-search"
extract placitum/logger /app "$st/usr/share/placitum/logger"
proc "$st" logger "логгер аудита и журнала в ClickHouse" placitum/logger waf-logger ro:/usr/share/placitum/logger \
    "clickhouse-server.service placitum-nats.service" logger
proc "$st" search "поиск по аудиту для панели" placitum/logger waf-search ro:/usr/share/placitum/logger \
    "clickhouse-server.service" search
deb "$st" placitum-logger "placitum-common" "Placitum: логгер аудита и поиск"

# --- сервисы контура -------------------------------------------------------

st=$stage/crypto
extract placitum-crypto /usr/local/bin/waf-crypto "$st/usr/lib/placitum/bin/waf-crypto"
proc "$st" crypto "держатель ключа контура" placitum-crypto waf-crypto - "placitum-controller.service" crypto
deb "$st" placitum-crypto "placitum-common" "Placitum: расшифровка сертификатов ключом контура"

st=$stage/geo
extract placitum-geo /usr/local/bin/waf-geo "$st/usr/lib/placitum/bin/waf-geo"
mkdir -p "$st/usr/share/placitum/geo/data/country" "$st/usr/share/placitum/geo/data/asn"
stamp "$st/usr/share/placitum/geo" placitum-geo
proc "$st" geo "страна и ASN по адресу" placitum-geo waf-geo sync:geo "placitum-nats.service" geo
deb "$st" placitum-geo "placitum-common" "Placitum: кодер страны и ASN"

st=$stage/keeper
extract placitum-keeper /usr/local/bin/waf-keeper "$st/usr/lib/placitum/bin/waf-keeper"
proc "$st" keeper "истина активных наборов" placitum-keeper waf-keeper - \
    "postgresql.service placitum-nats.service placitum-redis@internal.service" keeper
deb "$st" placitum-keeper "placitum-common" "Placitum: keeper, истина активных наборов"

# --- инспекторы ------------------------------------------------------------

inspector ip      placitum-inspector-ip      "инспектор адреса"
inspector modsec  placitum-inspector-modsec  "инспектор правил, CRS на Coraza"
inspector json    placitum-inspector-json    "инспектор контракта API"
inspector counter placitum-inspector-counter "поведенческий счётчик"
inspector action  placitum-inspector-action  "отправитель канала действий"
inspector rewrite placitum-inspector-rewrite "модификация ответов"
inspector cookie  placitum/cookie            "подписанные куки"
inspector auth    placitum/auth              "калитка и форма входа" "форма входа калитки"
inspector captcha placitum/captcha           "капча и её виджет" "виджет капчи"

# --- наблюдатели -----------------------------------------------------------

st=$stage/agents
extract placitum-redis-agent /usr/local/bin/waf-redis-agent "$st/usr/lib/placitum/bin/waf-redis-agent"
extract placitum-s3-agent /usr/local/bin/waf-s3-agent "$st/usr/lib/placitum/bin/waf-s3-agent"
proc "$st" redis-agent@ "наблюдатель Redis %i" placitum-redis-agent waf-redis-agent - \
    "placitum-nats.service placitum-redis@exchange.service placitum-redis@internal.service" "redis-agent-%i"
proc "$st" s3-agent "наблюдатель архива S3" placitum-s3-agent waf-s3-agent - \
    "placitum-nats.service placitum-minio.service" s3-agent
deb "$st" placitum-agents "placitum-common" "Placitum: наблюдатели Redis и S3"

# --- что из чего собрано ---------------------------------------------------

{
    printf 'version %s\n' "$version"
    for img in placitum-edge placitum-controller placitum/logger placitum-crypto placitum-geo placitum-keeper \
        placitum-inspector-ip placitum-inspector-modsec placitum-inspector-json placitum-inspector-counter \
        placitum-inspector-action placitum-inspector-rewrite placitum/cookie placitum/auth placitum/captcha \
        placitum-redis-agent placitum-s3-agent "$IMG_NATS" "$IMG_NATS_BOX" "$IMG_MINIO" "$IMG_MC"; do
        printf '%-50s %s\n' "$img" "$(label "$img" revision)"
    done
} > "$out/MANIFEST"

say "готово: $(ls "$out"/*.deb | wc -l) пакетов, $(du -sh "$out" | cut -f1); что из чего -- $out/MANIFEST"
