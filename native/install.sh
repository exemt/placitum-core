#!/bin/sh
# Placitum without Docker: the whole installation on one Debian 13 machine.
#
#     sudo sh install.sh                 install; asks for whatever is not answered yet
#     sudo sh install.sh --reconfigure   ask everything again; current answers become defaults
#     sudo sh install.sh --defaults      no questions; missing answers take defaults
#     sudo sh install.sh status          what is running
#     sudo sh install.sh check           check a clean installation
#
# Answers are kept in /etc/placitum/placitum.conf, and a repeated run reuses them.
# The panel admin password is never stored: without a terminal it comes from
# PLC_PANEL_PASSWORD; if that is empty, a password is generated and shown once.
#
# Needs packages/ from native/build.sh next to this script. Infrastructure comes from
# the Debian, nginx.org, ClickHouse and NodeSource repositories.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
etc=/etc/placitum
conf=$etc/placitum.conf
envd=$etc/env
secrets=$etc/secrets
log=/var/log/placitum-install.log

NGINX_DEB=1.28.0-1~trixie
CLICKHOUSE_DEB=24.8.14.39
NODE_MAJOR=22

INSPECTORS="ip modsec json counter action rewrite cookie auth captcha"

INTERNAL_PORTS="4222 5432 6379 6380 8079 8080 8081 8085 8086 8091 8092 8093 8094 8123 8222 9000 9004 9005 9009 9100 9101 50051"

cmd=install
mode=ask

for arg in "$@"; do
    case "$arg" in
        install|status|check) cmd=$arg ;;
        --defaults)           mode=defaults ;;
        --reconfigure)        mode=reconfigure ;;
        -h|--help|help)       sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                    printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

say()  { printf '\n== %s\n' "$*"; }
note() { printf '%s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf '!! %s\n' "$*" >&2; exit 1; }

elapsed() {
    s=$(( $(date +%s) - $1 ))

    if [ "$s" -ge 60 ]; then
        printf '%dm %02ds' $((s / 60)) $((s % 60))
    else
        printf '%ds' "$s"
    fi
}

log_tail() {
    tail -n 30 "$log" | sed 's/^/    | /' >&2
}

# quietly <what> <command...>: output goes to the log, the screen gets one line. set -e does not
# apply inside if, so functions passed here must check their own steps.
quietly() {
    what=$1
    shift
    started=$(date +%s)

    printf '  %s ... ' "$what"
    printf '\n== %s %s\n' "$(date '+%F %T')" "$what" >> "$log"

    if "$@" >> "$log" 2>&1; then
        printf 'done, %s\n' "$(elapsed "$started")"
        return 0
    fi

    printf 'failed\n'
    log_tail
    die "$what failed, full log: $log"
}

wait_for() {
    left=$1
    shift

    until "$@" >/dev/null 2>&1; do
        left=$((left - 2))
        [ "$left" -gt 0 ] || return 1
        sleep 2
    done
}

interactive=no
if [ "$mode" != defaults ] && [ -t 0 ] && [ -t 1 ]; then
    interactive=yes
fi

save() {
    mkdir -p "$etc"
    touch "$conf"

    if grep -q "^$1=" "$conf"; then
        sed -i "s|^$1=.*|$1=$2|" "$conf"
    else
        printf '%s=%s\n' "$1" "$2" >> "$conf"
    fi
}

is_name()    { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,62}$'; }
is_count()   { printf '%s' "$1" | grep -Eq '^[0-9]{1,2}$' && [ "$1" -ge 1 ] && [ "$1" -le 32 ]; }
is_workers() { [ "$1" = auto ] || { printf '%s' "$1" | grep -Eq '^[0-9]{1,2}$' && [ "$1" -ge 1 ]; }; }
is_mb()      { printf '%s' "$1" | grep -Eq '^[0-9]{2,6}$' && [ "$1" -ge 32 ]; }

is_http_port() {
    printf '%s' "$1" | grep -Eq '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || return 1

    for busy in $INTERNAL_PORTS; do
        [ "$1" != "$busy" ] || return 1
    done
}

is_bind() {
    case "$1" in
        0.0.0.0|127.0.0.1) return 0 ;;
    esac

    ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx "$1"
}

why() {
    case "$1" in
        is_name)      echo "lowercase latin letters, digits and hyphens" ;;
        is_count)     echo "a number from 1 to 32" ;;
        is_workers)   echo "auto or a number" ;;
        is_mb)        echo "megabytes, at least 32" ;;
        is_http_port) echo "a port from 1 to 65535, except those used by Placitum: $INTERNAL_PORTS" ;;
        is_bind)      echo "0.0.0.0, 127.0.0.1 or an IPv4 address of this machine" ;;
    esac
}

# ask <variable> <check> <default> <question>
ask() {
    var=$1 check=$2 default=$3 question=$4
    eval "current=\${$var:-}"

    if [ -n "$current" ] && [ "$mode" != reconfigure ]; then
        "$check" "$current" || die "$conf: $var=$current -- $(why "$check")"
        return 0
    fi

    if [ -n "$current" ]; then
        default=$current
    fi

    while :; do
        answer=$default

        if [ "$interactive" = yes ]; then
            printf '%s [%s]: ' "$question" "$default"
            IFS= read -r answer || answer=""
            [ -n "$answer" ] || answer=$default
        fi

        if "$check" "$answer"; then
            break
        fi

        [ "$interactive" = yes ] || die "$var=$answer -- $(why "$check")"
        warn "$(why "$check")"
    done

    eval "$var=\$answer"
    save "$var" "$answer"
}

upper() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

copies() {
    eval "printf '%s' \"\$PLC_COPIES_$(upper "$1")\""
}

answers() {
    say "answers"

    if [ -f "$conf" ]; then
        # shellcheck disable=SC1090
        . "$conf"
    fi

    ask PLC_NODE_ID       is_name      edge-01   "Node name, shown in the panel and the audit"
    ask PLC_HTTP_PORT     is_http_port 80        "HTTP traffic port"
    ask PLC_PANEL_BIND    is_bind      127.0.0.1 "Panel address: 127.0.0.1 for this machine only, 0.0.0.0 for all, or an interface address"
    ask PLC_NGINX_WORKERS is_workers   auto      "nginx workers: auto means one per core"

    for name in $INSPECTORS; do
        ask "PLC_COPIES_$(upper "$name")" is_count 1 "Copies of the $name inspector"
    done

    ask PLC_REDIS_EXCHANGE_MB is_mb 512 "Exchange Redis memory (request objects), MB"
    ask PLC_REDIS_INTERNAL_MB is_mb 256 "Internal Redis memory (generations, buckets), MB"

    note "answers: $conf"
}

panel_pass=""
generated=""

read_secret() {
    printf '%s' "$1" >&2
    stty -echo 2>/dev/null || true
    IFS= read -r secret || secret=""
    stty echo 2>/dev/null || true
    printf '\n' >&2
    printf '%s' "$secret"
}

ask_panel_password() {
    if [ -n "${PLC_PANEL_PASSWORD:-}" ]; then
        [ "${#PLC_PANEL_PASSWORD}" -ge 8 ] || die "PLC_PANEL_PASSWORD: at least 8 characters"
        panel_pass=$PLC_PANEL_PASSWORD
        note "panel admin password: from PLC_PANEL_PASSWORD"
        return 0
    fi

    [ "$interactive" = yes ] || return 0

    trap 'stty echo 2>/dev/null' EXIT INT TERM

    while :; do
        first=$(read_secret "Panel admin password (Enter keeps the current one or generates one): ")
        [ -n "$first" ] || break

        if [ "${#first}" -lt 8 ]; then
            warn "at least 8 characters"
            continue
        fi

        second=$(read_secret "Again: ")

        if [ "$first" = "$second" ]; then
            panel_pass=$first
            break
        fi

        warn "passwords do not match, try again"
    done

    trap - EXIT INT TERM
}

preflight() {
    say "checks"

    [ "$(id -u)" -eq 0 ] || die "root required: sudo sh $0"

    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${VERSION_CODENAME:-}" = trixie ] ||
        die "the installation targets Debian 13 (trixie), this is ${PRETTY_NAME:-an unknown system}"
    [ "$(dpkg --print-architecture)" = amd64 ] || die "amd64 required"

    set -- "$here"/packages/placitum-common_*.deb
    [ -f "$1" ] || die "no packages in $here/packages: build them with native/build.sh"

    note "$PRETTY_NAME, $(nproc) cores, $(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo) MB of memory"
    note "Placitum packages: $(ls "$here"/packages/*.deb | wc -l), $here/packages"
}

fetch_keys() {
    curl -fsSL https://nginx.org/keys/nginx_signing.key -o /etc/apt/keyrings/placitum-nginx.asc &&
        curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key \
            -o /etc/apt/keyrings/placitum-clickhouse.asc &&
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            -o /etc/apt/keyrings/placitum-nodesource.asc
}

repos() {
    say "repositories"

    install -d -m 0755 /etc/apt/keyrings
    quietly "nginx.org, ClickHouse and NodeSource keys" fetch_keys

    cat > /etc/apt/sources.list.d/placitum.list <<EOF
# Placitum (install.sh): nginx matching the module build, ClickHouse, Node.js $NODE_MAJOR.
deb [signed-by=/etc/apt/keyrings/placitum-nginx.asc] https://nginx.org/packages/debian trixie nginx
deb [signed-by=/etc/apt/keyrings/placitum-clickhouse.asc arch=amd64] https://packages.clickhouse.com/deb stable main
deb [signed-by=/etc/apt/keyrings/placitum-nodesource.asc] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main
EOF

    quietly "apt update" apt-get update
}

packages() {
    say "packages"

    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l

    quietly "nginx $NGINX_DEB" apt-get install -y --no-install-recommends \
        --allow-downgrades --allow-change-held-packages "nginx=$NGINX_DEB"
    apt-mark hold nginx >> "$log" 2>&1

    quietly "PostgreSQL, Redis" apt-get install -y --no-install-recommends postgresql redis-server
    quietly "ClickHouse $CLICKHOUSE_DEB" apt-get install -y --no-install-recommends \
        "clickhouse-server=$CLICKHOUSE_DEB" "clickhouse-client=$CLICKHOUSE_DEB" \
        "clickhouse-common-static=$CLICKHOUSE_DEB"
    quietly "Node.js $NODE_MAJOR" apt-get install -y --no-install-recommends nodejs

    quietly "Placitum packages" apt-get install -y --no-install-recommends --allow-downgrades \
        "$here"/packages/*.deb
}

secrets_step() {
    say "secrets"

    install -d -m 0750 -o root -g placitum "$secrets"

    if [ -f "$secrets/passwords" ]; then
        note "infrastructure passwords exist: $secrets/passwords"
    else
        (
            umask 077
            {
                printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 16)"
                printf 'CLICKHOUSE_PASSWORD=%s\n' "$(openssl rand -hex 16)"
                printf 'MINIO_ROOT_PASSWORD=%s\n' "$(openssl rand -hex 16)"
            } > "$secrets/passwords"
        )
        note "infrastructure passwords created: $secrets/passwords"
    fi

    # shellcheck disable=SC1091
    . "$secrets/passwords"

    quietly "installation key and signing keys" env MINIO_ROOT_USER=waf MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
        sh /usr/share/placitum/bootstrap/secrets.sh "$secrets"

    # secrets.sh sets Docker modes; here the placitum group reads the files and passwords are root-only.
    chown root:placitum "$secrets" "$secrets"/*
    chmod 0750 "$secrets"
    chmod 0640 "$secrets"/*
    chown root:root "$secrets/passwords"
    chmod 0600 "$secrets/passwords"
}

env_file() {
    install -d -m 0750 -o root -g placitum "$envd"
    cat > "$envd/$1.env"
    chown root:placitum "$envd/$1.env"
    chmod 0640 "$envd/$1.env"
}

# subst <template> <dest> <sed args...>: a Docker address left in the result is fatal.
subst() {
    src=$1 dst=$2
    shift 2
    sed "$@" "$src" > "$dst"

    if grep -Eq 'redis://redis|nats://nats|minio:9000|/run/secrets|0\.0\.0\.0:(4222|8222)|store_dir: /data' "$dst"; then
        die "$dst: Docker addresses left"
    fi
}

redis_conf() {
    cat > "$etc/redis/$1.conf" <<EOF
# Placitum (install.sh): Redis $1. noeviction: a loud error beats a silently evicted key.
bind 127.0.0.1 -::1
port $2
protected-mode yes
maxmemory ${3}mb
maxmemory-policy noeviction
save ""
appendonly no
dir /var/lib/placitum/redis-$1
EOF
    chmod 0644 "$etc/redis/$1.conf"
}

clickhouse_conf() {
    hash=$(printf '%s' "$CLICKHOUSE_PASSWORD" | sha256sum | cut -d' ' -f1)

    install -d -m 0755 /etc/clickhouse-server/users.d /etc/clickhouse-server/config.d

    cat > /etc/clickhouse-server/users.d/placitum.xml <<EOF
<!-- Placitum (install.sh): user for logger and search. -->
<clickhouse>
    <users>
        <waf>
            <password_sha256_hex>$hash</password_sha256_hex>
            <networks>
                <ip>::1</ip>
                <ip>127.0.0.1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
            <named_collection_control>1</named_collection_control>
        </waf>
    </users>
</clickhouse>
EOF
    chown clickhouse:clickhouse /etc/clickhouse-server/users.d/placitum.xml
    chmod 0640 /etc/clickhouse-server/users.d/placitum.xml

    sed 's|<level from_env="CLICKHOUSE_LOG_LEVEL"/>|<level>warning</level>|' \
        /usr/share/placitum/config/clickhouse/logger.xml > /etc/clickhouse-server/config.d/placitum-logger.xml
    cp /usr/share/placitum/config/clickhouse/system-logs.xml \
        /etc/clickhouse-server/config.d/placitum-system-logs.xml
}

configure() {
    say "configuration"

    # shellcheck disable=SC1091
    . "$secrets/passwords"

    db="postgres://waf:$POSTGRES_PASSWORD@127.0.0.1:5432/waf"
    geo=127.0.0.1:50051

    env_file common <<EOF
NATS_URL=nats://127.0.0.1:4222
WAF_NATS_URL=nats://127.0.0.1:4222
REDIS_URL=redis://127.0.0.1:6379
REDIS_INTERNAL_URL=redis://127.0.0.1:6380
EOF

    env_file controller <<EOF
CONTROLLER_HOST=127.0.0.1
CONTROLLER_PORT=8080
CONTROLLER_NAME=controller
CONTROLLER_LOG=info
CONTROLLER_DATABASE_URL=$db
CONTROLLER_NATS_URL=nats://127.0.0.1:4222
CONTROLLER_REDIS_URL=redis://127.0.0.1:6379
CONTROLLER_REDIS_INTERNAL_URL=redis://127.0.0.1:6380
CONTROLLER_SEARCH_URL=http://127.0.0.1:8091
CONTROLLER_GEO_URL=http://127.0.0.1:8092
CONTROLLER_CRYPTO_SERVICE_URL=http://127.0.0.1:8093
CONTROLLER_CRYPTO_PUBLIC_KEY=$secrets/contour.pub
CONTROLLER_COMPILE_DIR=/var/lib/placitum/controller/compile
CONTROLLER_UX_DIR=/usr/lib/placitum/controller/ux/dist
CONTROLLER_SCHEMA_DIR=/usr/lib/placitum/controller/schema
CONTROLLER_FLEET_DEMO=0
EOF

    env_file logger <<EOF
WAF_LOGGER_LOG=info
CLICKHOUSE_ADDR=127.0.0.1:9000
CLICKHOUSE_USER=waf
CLICKHOUSE_PASSWORD=$CLICKHOUSE_PASSWORD
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_USER=waf
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=waf
EOF

    env_file search <<EOF
SEARCH_HOST=127.0.0.1
SEARCH_PORT=8091
WAF_SEARCH_LOG=info
CLICKHOUSE_ADDR=127.0.0.1:9000
CLICKHOUSE_USER=waf
CLICKHOUSE_PASSWORD=$CLICKHOUSE_PASSWORD
WAF_STORE_S3_ENDPOINT=http://127.0.0.1:9100
WAF_STORE_S3_REGION=us-east-1
WAF_STORE_S3_CREDENTIALS_FILE=$secrets/s3.creds
WAF_STORE_BUCKET_HEADERS=waf-headers
WAF_STORE_BUCKET_ARGS=waf-args
WAF_STORE_BUCKET_BODY=waf-bodies
EOF

    env_file crypto <<EOF
WAF_CRYPTO_HTTP=127.0.0.1:8093
WAF_CRYPTO_LOG=info
WAF_NODE_KEY=$secrets/contour.key
WAF_CONTROLLER_URL=http://127.0.0.1:8080
EOF

    env_file geo <<EOF
WAF_GEO_CONTROLLER_URL=http://127.0.0.1:8080
WAF_GEO_LOG=info
WAF_GEO_HTTP=127.0.0.1:8092
WAF_GEO_GRPC=$geo
GOMEMLIMIT=1GiB
EOF

    env_file keeper <<EOF
WAF_KEEPER_LOG=info
WAF_KEEPER_DATABASE_URL=$db
WAF_KEEPER_HTTP=127.0.0.1:8094
GOMEMLIMIT=512MiB
EOF

    for name in ip modsec json counter action; do
        printf 'WAF_%s_GEO_ADDR=%s\n' "$(upper "$name")" "$geo" | env_file "$name"
    done

    : | env_file rewrite

    env_file cookie <<EOF
WAF_COOKIE_SECRET_FILE=$secrets/cookie.hmac
WAF_COOKIE_GEO_ADDR=$geo
EOF

    env_file auth <<EOF
WAF_AUTH_KEY_FILE=$secrets/auth.hmac
WAF_AUTH_HTTP_URL=http://127.0.0.1:8085
WAF_AUTH_GEO_ADDR=$geo
EOF

    env_file auth-http <<EOF
WAF_AUTH_NAME=auth
WAF_AUTH_LOG=info
WAF_AUTH_LISTEN=127.0.0.1:8085
WAF_AUTH_KEY_FILE=$secrets/auth.hmac
WAF_AUTH_APP_KEY_FILE=$secrets/auth-app.hmac
WAF_AUTH_COOKIE_SECURE=off
WAF_AUTH_CONTROLLER=http://127.0.0.1:8080
WAF_AUTH_SCOPE=name:default
WAF_AUTH_CONTOUR_KEY=$secrets/contour.key
EOF

    env_file captcha <<EOF
WAF_CAPTCHA_KEY_FILE=$secrets/captcha.hmac
WAF_CAPTCHA_HTTP_URL=http://127.0.0.1:8086
WAF_CAPTCHA_GEO_ADDR=$geo
EOF

    env_file captcha-http <<EOF
WAF_CAPTCHA_NAME=captcha
WAF_CAPTCHA_LOG=info
WAF_CAPTCHA_LISTEN=127.0.0.1:8086
WAF_CAPTCHA_KEY_FILE=$secrets/captcha.hmac
WAF_CAPTCHA_COOKIE_SECURE=off
WAF_CAPTCHA_CONTROLLER=http://127.0.0.1:8080
WAF_CAPTCHA_SCOPE=name:default
WAF_CAPTCHA_CONTOUR_KEY=$secrets/contour.key
EOF

    env_file redis-agent-redis <<EOF
REDIS_URL=redis://127.0.0.1:6379
WAF_REDIS_NAME=redis
WAF_REDIS_AGENT_LOG=info
EOF

    env_file redis-agent-redis-internal <<EOF
REDIS_URL=redis://127.0.0.1:6380
WAF_REDIS_NAME=redis-internal
WAF_REDIS_AGENT_LOG=info
EOF

    env_file s3-agent <<EOF
S3_ENDPOINT=http://127.0.0.1:9100
S3_ACCESS_KEY=waf
S3_SECRET_KEY=$MINIO_ROOT_PASSWORD
S3_BUCKET=waf-bodies
S3_ENSURE_BUCKETS=waf-bodies,waf-headers,waf-args
S3_REGION=us-east-1
WAF_S3_NAME=s3
WAF_S3_AGENT_LOG=info
EOF

    env_file minio <<EOF
MINIO_ROOT_USER=waf
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
EOF

    env_file edge <<EOF
WAF_NODE_ID=$PLC_NODE_ID
WAF_AGENT_CONFIG=$etc/edge/agent.conf
WAF_NGINX_MANAGE=on
WAF_AGENT_LOG=info
WAF_NGINX_DEBUG=off
WAF_LOG_WRITER=$PLC_NODE_ID
EOF

    install -d -m 0755 "$etc/edge" "$etc/nats" "$etc/redis"

    subst /usr/share/placitum/config/agent.conf "$etc/edge/agent.conf" \
        -e "s|/run/secrets/waf_node_key|$secrets/contour.key|" \
        -e "s|/var/lib/waf/agent|/var/lib/placitum/edge|" \
        -e "s|nats://nats:4222|nats://127.0.0.1:4222|" \
        -e "s|redis://redis-internal:6379|redis://127.0.0.1:6380|" \
        -e "s|redis://redis:6379|redis://127.0.0.1:6379|" \
        -e "s|http://minio:9000|http://127.0.0.1:9100|" \
        -e "s|/run/secrets/waf_s3_creds|$secrets/s3.creds|"

    printf '# Node name for the module; install.sh rewrites this file from PLC_NODE_ID.\nwaf_node_id %s;\n' \
        "$PLC_NODE_ID" > /etc/nginx/waf-node.conf

    subst /usr/share/placitum/config/nats-server.conf "$etc/nats/nats-server.conf" \
        -e "s|listen: 0.0.0.0:4222|listen: 127.0.0.1:4222|" \
        -e "s|http: 0.0.0.0:8222|http: 127.0.0.1:8222|" \
        -e "s|store_dir: /data|store_dir: /var/lib/placitum/nats|"

    redis_conf exchange 6379 "$PLC_REDIS_EXCHANGE_MB"
    redis_conf internal 6380 "$PLC_REDIS_INTERNAL_MB"

    clickhouse_conf

    note "process environment: $envd"
}

psql_q() {
    (cd / && runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 "$@")
}

database() {
    say "database"

    # shellcheck disable=SC1091
    . "$secrets/passwords"

    quietly "PostgreSQL" systemctl enable --now postgresql
    quietly "PostgreSQL responds" wait_for 60 runuser -u postgres -- pg_isready -q

    if [ "$(psql_q -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'waf'")" = 1 ]; then
        psql_q -c "ALTER ROLE waf LOGIN PASSWORD '$POSTGRES_PASSWORD'" >> "$log" 2>&1 || die "role waf: password"
        note "role waf exists, password set"
    else
        psql_q -c "CREATE ROLE waf LOGIN PASSWORD '$POSTGRES_PASSWORD'" >> "$log" 2>&1 || die "role waf"
        note "role waf created"
    fi

    if [ "$(psql_q -tAc "SELECT 1 FROM pg_database WHERE datname = 'waf'")" = 1 ]; then
        note "database waf exists"
    else
        psql_q -c "CREATE DATABASE waf OWNER waf" >> "$log" 2>&1 || die "database waf"
        note "database waf created"
    fi
}

buckets() {
    export MC_CONFIG_DIR=/root/.placitum-mc
    export MC_HOST_waf="http://waf:$MINIO_ROOT_PASSWORD@127.0.0.1:9100"

    wait_for 60 /usr/lib/placitum/bin/mc ready waf || return 1

    for bucket in waf-headers waf-args waf-bodies; do
        /usr/lib/placitum/bin/mc mb --ignore-existing "waf/$bucket" || return 1
        /usr/lib/placitum/bin/mc ilm import "waf/$bucket" < /usr/share/placitum/config/minio/lifecycle.json ||
            return 1
    done
}

infra() {
    say "infrastructure"

    # shellcheck disable=SC1091
    . "$secrets/passwords"

    # The package's own Redis would take 6379; Placitum runs two instances with their own configs.
    systemctl disable --now redis-server >> "$log" 2>&1 || true
    systemctl daemon-reload

    quietly "Redis: exchange 6379 and internal 6380" \
        systemctl enable --now placitum-redis@exchange placitum-redis@internal
    quietly "NATS" systemctl enable --now placitum-nats
    quietly "JetStream streams" env NATS_URL=nats://127.0.0.1:4222 PATH="/usr/lib/placitum/bin:$PATH" \
        sh /usr/share/placitum/bootstrap/streams.sh

    quietly "ClickHouse" systemctl restart clickhouse-server
    systemctl enable clickhouse-server >> "$log" 2>&1
    quietly "ClickHouse responds" wait_for 90 \
        clickhouse-client --user waf --password "$CLICKHOUSE_PASSWORD" --query "SELECT 1"

    quietly "MinIO" systemctl enable --now placitum-minio
    quietly "archive buckets and lifecycle rules" buckets
}

# as_placitum <command...>: run as placitum in the controller directory with its environment.
as_placitum() {
    (
        cd /usr/lib/placitum/controller || exit 1
        set -a
        # shellcheck disable=SC1091
        . "$envd/common.env"
        # shellcheck disable=SC1091
        . "$envd/controller.env"
        set +a
        exec runuser -u placitum -- "$@"
    )
}

schema() {
    say "schema"
    quietly "PostgreSQL schema" as_placitum node src/migrate.ts
}

# The key fingerprint pin is baked into the panel build; swap it for this machine's key.
pin() {
    old=$(cat /usr/lib/placitum/controller/PIN)
    new=$(sh /usr/share/placitum/bootstrap/secrets.sh --fingerprint "$secrets")
    dist=/usr/lib/placitum/controller/ux/dist

    if grep -rqF "$new" "$dist"; then
        note "panel fingerprint pin: $new"
        return 0
    fi

    files=$(grep -rlF "$old" "$dist") || die "pin $old not found in the panel build"

    for file in $files; do
        sed -i "s|$old|$new|g" "$file"
    done

    grep -rqF "$new" "$dist" || die "the fingerprint pin did not get into the panel"
    note "panel fingerprint pin: $new (the build had $old)"
}

nginx_stub() {
    rm -f /etc/nginx/conf.d/default.conf

    if grep -q ngx_http_waf_module /etc/nginx/nginx.conf 2>/dev/null; then
        note "nginx: already on a controller generation"
        return 0
    fi

    cat > /etc/nginx/nginx.conf <<'EOF'
# Node stub until the first controller generation overwrites this file.
events {}

http {
    server {
        listen 8079;
        location = /healthz { return 200 "bootstrap\n"; }
        location / { return 503 "waiting for controller generation\n"; }
    }
}
EOF
    note "nginx: stub until the first generation"
}

services() {
    say "processes"

    systemd-tmpfiles --create placitum.conf
    nginx_stub
    quietly "nginx" systemctl restart nginx
    systemctl enable nginx >> "$log" 2>&1

    list="placitum.target placitum-controller placitum-crypto placitum-geo placitum-keeper"
    list="$list placitum-logger placitum-search placitum-auth-http placitum-captcha-http"
    list="$list placitum-redis-agent@redis placitum-redis-agent@redis-internal placitum-s3-agent placitum-edge"

    for name in $INSPECTORS; do
        n=$(copies "$name")
        i=1

        while [ "$i" -le "$n" ]; do
            list="$list placitum-$name@$i"
            i=$((i + 1))
        done

        # Stop and disable copies above the answered count.
        for unit in $(systemctl list-units --all --plain --no-legend "placitum-$name@*.service" | cut -d' ' -f1); do
            k=${unit#"placitum-$name@"}
            k=${k%.service}

            if [ "$k" -gt "$n" ] 2>/dev/null; then
                systemctl disable --now "$unit" >> "$log" 2>&1 || true
                note "removed extra copy: $unit"
            fi
        done
    done

    # shellcheck disable=SC2086
    quietly "units: $(printf '%s\n' $list | wc -l)" systemctl enable --now $list
    quietly "controller responds" wait_for 120 curl -fsS http://127.0.0.1:8080/healthz
}

panel() {
    say "panel"

    edge=$PLC_PANEL_BIND
    [ "$edge" != 0.0.0.0 ] || edge=127.0.0.1

    quietly "traffic port and nginx workers" as_placitum env PLC_HTTP_PORT="$PLC_HTTP_PORT" \
        PLC_NGINX_WORKERS="$PLC_NGINX_WORKERS" node bootstrap/tune.mjs

    started=$(date +%s)
    printf '  login gate, admin and publish to the node ... '
    printf '\n== %s panel\n' "$(date '+%F %T')" >> "$log"

    if ! result=$(printf '%s' "$panel_pass" | as_placitum env PANEL_ADMIN=ensure \
            PANEL_EDGE="http://$edge:8081" PANEL_RESOLVER=none \
            PANEL_CONTROLLER_HOST=127.0.0.1 PANEL_CONTROLLER_PORT=8080 \
            PANEL_FORM_HOST=127.0.0.1 PANEL_FORM_PORT=8085 PANEL_BIND="$PLC_PANEL_BIND" \
            node bootstrap/panel.mjs 2>> "$log"); then
        printf 'failed\n'
        log_tail
        die "panel setup failed, log: $log"
    fi

    printf 'done, %s\n' "$(elapsed "$started")"

    case "$result" in
        created)       note "admin created with the entered password" ;;
        updated)       note "admin password changed" ;;
        kept)          note "admin exists, password unchanged" ;;
        "generated "*) generated=${result#generated } ;;
        *)             die "unexpected answer from the panel step: $result" ;;
    esac
}

publish() {
    say "publish"

    started=$(date +%s)
    printf '  configuration channels to processes ... '
    printf '\n== %s publish\n' "$(date '+%F %T')" >> "$log"

    if ! result=$(as_placitum node bootstrap/publish.mjs 2>> "$log"); then
        printf 'failed\n'
        log_tail
        die "configuration channels did not converge, log: $log"
    fi

    printf 'done, %s\n' "$(elapsed "$started")"
    note "$result"
}

summary() {
    say "done"

    failed=$(systemctl list-units --state=failed --plain --no-legend 'placitum*' | cut -d' ' -f1 | tr '\n' ' ')
    active=$(systemctl list-units --state=active --plain --no-legend 'placitum*.service' | wc -l)

    if [ -n "$failed" ]; then
        warn "failed: $failed"
    else
        note "placitum processes: $active, none failed"
    fi

    if [ "$PLC_PANEL_BIND" = 0.0.0.0 ]; then
        for addr in $(ip -o -4 addr show | awk '$2 != "lo" {print $4}' | cut -d/ -f1); do
            note "panel:   http://$addr:8081"
        done
    else
        note "panel:   http://$PLC_PANEL_BIND:8081"
    fi

    if [ -n "$generated" ]; then
        note "login:   admin / $generated (the password is not stored anywhere, write it down)"
    else
        note "login:   admin"
    fi

    note "API:     http://127.0.0.1:8080, no login, this machine only (from elsewhere use ssh -L)"
    note "traffic: port $PLC_HTTP_PORT"
    note "answers: $conf"
    note "log:     $log"
}

case "$cmd" in
    install)
        [ "$(id -u)" -eq 0 ] || die "root required: sudo sh $0"
        : > "$log"
        preflight
        answers
        ask_panel_password
        repos
        packages
        secrets_step
        configure
        database
        infra
        schema
        pin
        services
        panel
        publish
        summary
        ;;
    status)
        systemctl list-units --all --no-pager 'placitum*' nginx.service postgresql.service clickhouse-server.service
        ;;
    check)
        exec node "$here/check.mjs"
        ;;
esac
