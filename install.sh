#!/bin/sh
# Placitum installer: settings, secrets, infrastructure, components, panel.
#
#     ./install.sh check            checks only, changes nothing
#     ./install.sh install          everything in order; the first run asks the settings
#     ./install.sh reconfigure      ask the settings again and apply them
#     ./install.sh infra            infrastructure only
#     ./install.sh panel            set up the panel on a running installation
#     ./install.sh panel-password   change the panel admin password and lift the login lockout
#     ./install.sh status           what is running and how it is doing
#     ./install.sh down             stop everything; volumes and data stay
#
# Options:
#     --sources <file>   component sources; default sources.env
#     --no-build         start already built images without rebuilding
#     --defaults         no questions: settings come from the environment or defaults
#
# Images are built on this machine from sources, so it needs access to the git
# repositories, base images and the Go module proxy.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
env_file="$here/.env"
sources="$here/sources.env"

log_file="$here/install.log"

PLC_VERSION=${PLC_VERSION:-$(git -C "$here" describe --tags --exact-match 2>/dev/null || echo dev)}
PLC_REVISION=${PLC_REVISION:-$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)}
export PLC_VERSION PLC_REVISION
build=yes
defaults=no
# How the user runs this script: a ready machine image wraps it in its own command.
cli=${PLC_CLI:-./install.sh}
cmd=${1:-help}
[ $# -gt 0 ] && shift || true

while [ $# -gt 0 ]; do
    case "$1" in
        --sources) sources=$2; shift 2 ;;
        --no-build) build=no; shift ;;
        --defaults) defaults=yes; shift ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

INSPECTORS="ip modsec json counter action rewrite cookie captcha auth vlai"

# Asked on the first install and by reconfigure. A value set in the environment
# becomes the default answer.
SETTINGS="PLC_NODE_ID PLC_HTTP_PORT PLC_HTTPS_PORT PLC_PANEL_BIND PLC_PANEL_PORT PLC_NODES PLC_NGINX_WORKERS"

for name in $INSPECTORS; do
    SETTINGS="$SETTINGS PLC_COPIES_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
done

SETTINGS="$SETTINGS PLC_REDIS_EXCHANGE_MB PLC_REDIS_INTERNAL_MB"

for name in $SETTINGS; do
    eval "given_$name=\${$name:-}"
done

interactive=no
if [ "$defaults" = no ] && [ -t 0 ] && [ -t 1 ]; then
    interactive=yes
fi

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf '!! %s\n' "$*" >&2; exit 1; }

upper() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# Compose with the values that follow from the answers: the vlai profile, the captcha form and the
# CPU cap of a node.
compose() {
    file=$1
    shift
    (
        if [ -f "$env_file" ]; then
            # shellcheck disable=SC1090
            . "$env_file"
        fi

        cores=$(nproc 2>/dev/null || echo 1)
        edge=${PLC_CPUS_EDGE:-${PLC_NGINX_WORKERS:-auto}}
        [ "$edge" != auto ] || edge=$cores
        awk -v v="$edge" -v c="$cores" 'BEGIN { exit !(v > c) }' && edge=$cores

        COMPOSE_PROFILES=""
        [ "${PLC_COPIES_VLAI:-0}" -eq 0 ] || COMPOSE_PROFILES=vlai
        [ "${PLC_NODES:-1}" -le 1 ] || COMPOSE_PROFILES="${COMPOSE_PROFILES:+$COMPOSE_PROFILES,}nodes"
        PLC_CAPTCHA_FORM=1
        [ "${PLC_COPIES_CAPTCHA:-1}" -gt 0 ] || PLC_CAPTCHA_FORM=0
        PLC_CPUS_EDGE=$edge
        export COMPOSE_PROFILES PLC_CAPTCHA_FORM PLC_CPUS_EDGE

        if [ -f "$here/compose/nodes.yml" ]; then
            set -- -f "$here/compose/$file" -f "$here/compose/nodes.yml" "$@"
        else
            set -- -f "$here/compose/$file" "$@"
        fi

        exec docker compose --ansi never --progress plain \
            --env-file "$env_file" --env-file "$sources" "$@"
    )
}

elapsed() {
    s=$(( $(date +%s) - $1 ))

    if [ "$s" -ge 60 ]; then
        printf '%dm %02ds' $((s / 60)) $((s % 60))
    else
        printf '%ds' "$s"
    fi
}

log_tail() {
    tail -n 30 "$log_file" | sed 's/^/    | /' >&2
}

# quietly <what> <command...>: output goes to install.log, the screen gets one line per step.
quietly() {
    what=$1
    shift
    started=$(date +%s)

    printf '  %s ... ' "$what"
    printf '\n== %s %s\n' "$(date '+%F %T')" "$what" >> "$log_file"

    if "$@" >> "$log_file" 2>&1; then
        printf 'done, %s\n' "$(elapsed "$started")"
        return 0
    fi

    printf 'failed\n'
    log_tail
    die "$what failed, full log: $log_file"
}

preflight() {
    say "checks"

    command -v docker >/dev/null 2>&1 || die "docker not found"
    docker info >/dev/null 2>&1 || die "docker is installed, but the daemon does not respond"

    version=$(docker compose version --short 2>/dev/null) ||
        die "docker compose v2 not found (the compose plugin)"

    major=$(printf '%s' "$version" | sed 's/^v//; s/\..*//')
    minor=$(printf '%s' "$version" | sed 's/^v//; s/^[0-9]*\.//; s/[^0-9].*//')

    if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "${minor:-0}" -lt 20 ]; }; then
        die "docker compose 2.20 or newer is required (found $version): the installation relies on include"
    fi

    engine=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)

    case "${engine%%.*}" in
        ''|*[!0-9]*)
            printf 'docker compose %s\n' "$version"
            warn "could not detect the docker engine version"
            ;;
        *)
            printf 'docker %s, compose %s\n' "$engine" "$version"
            [ "${engine%%.*}" -ge 28 ] ||
                warn "docker engine $engine: before 28, containers are reachable from the network around published ports; upgrade the engine"
            ;;
    esac

    command -v openssl >/dev/null 2>&1 || die "openssl not found: it creates the installation key"

    free=$(df -Pk "$here" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}')
    if [ "$build" = yes ] && [ -n "${free:-}" ] && [ "$free" -lt 20 ]; then
        warn "${free} GB free: the build needs about 20"
    fi

    [ -f "$sources" ] || die "sources file not found: $sources"
    printf 'sources: %s\n' "$sources"
}

addr_kind() {
    case "$1" in
        127.*) echo loopback ;;
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*) echo private ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) echo private ;;
        *) echo public ;;
    esac
}

machine_addrs() {
    command -v ip >/dev/null 2>&1 || return 0

    ip -o -4 addr show | while read -r _ dev _ cidr _; do
        case "$dev" in docker0|br-*|veth*) continue ;; esac
        printf '%s %s\n' "${cidr%/*}" "$dev"
    done
}

host_addrs() {
    printf 'machine addresses:\n'
    machine_addrs | while read -r addr dev; do
        printf '  %-16s %-12s %s\n' "$addr" "$dev" "$(addr_kind "$addr")"
    done
}

check_panel() {
    say "panel"

    # shellcheck disable=SC1090
    if [ -f "$env_file" ]; then . "$env_file"; else . "$here/.env.example"; fi

    bind=${PLC_PANEL_BIND:-127.0.0.1}
    port=${PLC_PANEL_PORT:-8081}

    case "$bind" in
        *:*)
            die "PLC_PANEL_BIND=$bind: an IPv4 address is required"
            ;;
        127.0.0.1)
            printf 'panel on this machine only: http://127.0.0.1:%s (from elsewhere use ssh -L)\n' "$port"
            ;;
        0.0.0.0)
            warn "panel on all machine addresses, external ones included: login needs a password, but an internal address is safer"
            host_addrs
            ;;
        *)
            if command -v ip >/dev/null 2>&1 &&
                ! ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx "$bind"; then
                host_addrs
                die "PLC_PANEL_BIND=$bind: no such address on this machine; the node would not start, and traffic with it"
            fi

            [ "$(addr_kind "$bind")" = public ] &&
                warn "panel on public address $bind: over plain HTTP the password travels in clear text"

            printf 'panel: http://%s:%s\n' "$bind" "$port"
            ;;
    esac
}

panel_pass=""

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
        printf 'panel admin password: from PLC_PANEL_PASSWORD\n'
        return 0
    fi

    [ -t 0 ] || return 0

    trap 'stty echo 2>/dev/null' EXIT INT TERM

    while :; do
        first=$(read_secret "panel admin password ($1): ")
        [ -n "$first" ] || break

        if [ "${#first}" -lt 8 ]; then
            warn "at least 8 characters"
            continue
        fi

        second=$(read_secret "again: ")

        if [ "$first" = "$second" ]; then
            panel_pass=$first
            break
        fi

        warn "passwords do not match, try again"
    done

    trap - EXIT INT TERM
}

prepare_env() {
    say "environment"

    setup=keep

    if [ ! -f "$env_file" ]; then
        cp "$here/.env.example" "$env_file"
        chmod 600 "$env_file"

        for name in POSTGRES_PASSWORD CLICKHOUSE_PASSWORD MINIO_ROOT_PASSWORD; do
            set_env "$name" "$(openssl rand -hex 16)"
        done

        setup=fresh
        printf 'created %s with new infrastructure passwords\n' "$env_file"
    else
        printf 'environment file exists: %s\n' "$env_file"
    fi

    [ "$cmd" != reconfigure ] || setup=reconfigure

    # The answers before this run: a refused change puts them back.
    cp -p "$env_file" "$env_file.before"

    # shellcheck disable=SC1090
    . "$env_file"
    before=$(snapshot)

    while :; do
        settings
        plan
        [ "$setup" != reconfigure ] || changes "$before"
        [ "$setup" = keep ] || confirm && break
        # Not applied: the same questions again, with these answers in brackets.
        setup=reconfigure
    done

    cpu_limits

    # shellcheck disable=SC1090
    . "$env_file"
    quietly "keys and secrets" env MINIO_ROOT_USER="${MINIO_ROOT_USER:-waf}" \
        MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-wafwafwaf}" sh "$here/bootstrap/secrets.sh"

    node_files
}

# node_name <n>: node n takes the number at the end of PLC_NODE_ID, edge-01 gives edge-02.
node_name() {
    id=${PLC_NODE_ID:-edge-01}

    if [ "$1" -eq 1 ]; then
        printf '%s' "$id"
        return 0
    fi

    digits=$(printf '%s' "$id" | sed -n 's/^.*-\([0-9][0-9]*\)$/\1/p')

    if [ -z "$digits" ]; then
        printf '%s-%s' "$id" "$1"
    else
        awk -v p="${id%"$digits"}" -v w="${#digits}" -v n="$1" 'BEGIN { printf "%s%0" w "d", p, n }'
    fi
}

# node.conf of every node and compose/nodes.yml with the nodes after the first, rebuilt from the
# answers on every run.
node_files() {
    count=${PLC_NODES:-1}
    nodes="$here/compose/nodes.yml"

    rm -f "$here"/config/edge/node-*.conf

    i=1
    while [ "$i" -le "$count" ]; do
        conf="$here/config/edge/node.conf"
        [ "$i" -eq 1 ] || conf="$here/config/edge/node-$(printf '%02d' "$i").conf"

        printf '%s\n' \
            "# Node name for the module; install.sh rewrites this file from PLC_NODE_ID." \
            "waf_node_id $(node_name "$i");" > "$conf"
        i=$((i + 1))
    done

    printf 'nodes: %s' "$(node_name 1)"
    [ "$count" -eq 1 ] || printf ' ... %s' "$(node_name "$count")"
    printf '\n'

    if [ "$count" -eq 1 ]; then
        rm -f "$nodes"
        return 0
    fi

    {
        printf '# Written by install.sh from PLC_NODES: changes here are lost on the next run.\n\n'
        printf 'services:\n'
        printf '  edge:\n'
        printf '    ports: !override\n'
        printf '      - "${PLC_PANEL_BIND:-127.0.0.1}:${PLC_PANEL_PORT:-8081}:8081"\n'

        i=2
        while [ "$i" -le "$count" ]; do
            n=$(printf '%02d' "$i")
            name=$(node_name "$i")

            printf '\n  edge-%s:\n' "$n"
            printf '    extends:\n      file: waf.yml\n      service: edge\n'
            printf '    build: !reset null\n'
            printf '    image: placitum-edge\n'
            printf '    hostname: %s\n' "$name"
            printf '    labels:\n      placitum.install: node\n'
            printf '    environment:\n      WAF_NODE_ID: %s\n' "$name"
            printf '    ports: !reset []\n'
            printf '    volumes:\n'
            printf '      - ../config/edge/node-%s.conf:/etc/nginx/waf-node.conf:ro\n' "$n"
            printf '      - edge-%s-data:/var/lib/waf/agent\n' "$n"
            printf '      - edge-%s-store:/var/lib/waf/store\n' "$n"
            i=$((i + 1))
        done

        printf '\nvolumes:\n'

        i=2
        while [ "$i" -le "$count" ]; do
            printf '  edge-%s-data:\n  edge-%s-store:\n' "$(printf '%02d' "$i")" "$(printf '%02d' "$i")"
            i=$((i + 1))
        done
    } > "$nodes"
}

set_env() {
    name=$1
    value=$2
    tmp="$env_file.tmp"

    if grep -q "^$name=" "$env_file" 2>/dev/null; then
        sed "s|^$name=.*|$name=$value|" "$env_file" > "$tmp" && cat "$tmp" > "$env_file" && rm -f "$tmp"
    else
        printf '%s=%s\n' "$name" "$value" >> "$env_file"
    fi
}

is_name()   { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,62}$'; }
is_mb()     { printf '%s' "$1" | grep -Eq '^[0-9]{2,6}$' && [ "$1" -ge 64 ]; }
is_port()   { printf '%s' "$1" | grep -Eq '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_count()  { printf '%s' "$1" | grep -Eq '^[0-9]{1,2}$' && [ "$1" -ge 1 ] && [ "$1" -le 32 ]; }
is_copies() { printf '%s' "$1" | grep -Eq '^[0-9]{1,2}$' && [ "$1" -le 32 ]; }

is_workers() {
    [ "$1" = auto ] || { printf '%s' "$1" | grep -Eq '^[0-9]{1,3}$' && [ "$1" -ge 1 ] && [ "$1" -le 256 ]; }
}

is_http_port()  { is_port "$1" && [ "$1" != "${PLC_CONTROLLER_PORT:-8080}" ]; }
is_https_port() { is_http_port "$1" && [ "$1" != "${PLC_HTTP_PORT:-}" ]; }
is_panel_port() { is_https_port "$1" && [ "$1" != "${PLC_HTTPS_PORT:-}" ]; }

is_bind() {
    case "$1" in
        0.0.0.0|127.0.0.1) return 0 ;;
        *:*) return 1 ;;
    esac

    command -v ip >/dev/null 2>&1 || return 0
    ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx "$1"
}

why() {
    case "$1" in
        is_name)       echo "lowercase latin letters, digits and hyphens" ;;
        is_mb)         echo "megabytes, at least 64" ;;
        is_count)      echo "a number from 1 to 32" ;;
        is_copies)     echo "a number from 0 to 32; 0 turns the inspector off" ;;
        is_workers)    echo "auto or a number from 1 to 256" ;;
        is_http_port)  echo "a port from 1 to 65535, not the controller API port" ;;
        is_https_port) echo "a port from 1 to 65535, not the HTTP port or the controller API port" ;;
        is_panel_port) echo "a port from 1 to 65535, not a traffic port or the controller API port" ;;
        is_bind)       echo "0.0.0.0, 127.0.0.1 or an IPv4 address of this machine" ;;
    esac
}

# ask <variable> <check> <default> <question>. A fresh .env and reconfigure ask on a
# terminal and write the answer to .env; other runs only check what .env already has.
ask() {
    var=$1 check=$2 default=$3 question=$4
    eval "current=\${$var:-}"
    eval "given=\${given_$var:-}"

    case "$setup" in
        keep)
            [ -z "$current" ] || "$check" "$current" || die "$env_file: $var=$current -- $(why "$check")"
            return 0
            ;;
        reconfigure)
            default=${given:-${current:-$default}}
            ;;
        *)
            default=${given:-$default}
            ;;
    esac

    while :; do
        answer=$default

        if [ "$interactive" = yes ]; then
            printf '%s [%s]: ' "$question" "$default"
            IFS= read -r answer || answer=""
            [ -n "$answer" ] || answer=$default
        fi

        "$check" "$answer" && break

        [ "$interactive" = yes ] || die "$var=$answer -- $(why "$check")"
        warn "$(why "$check")"
    done

    eval "$var=\$answer"
    set_env "$var" "$answer"
}

settings() {
    mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || true)
    exchange=2560
    internal=512

    if [ -n "$mb" ] && [ "$mb" -le 8192 ]; then
        exchange=640
        internal=320
    fi

    if [ "$setup" != keep ]; then
        say "settings"
    fi

    ask PLC_NODE_ID    is_name       edge-01 "Node name, shown in the panel and the audit"
    ask PLC_HTTP_PORT  is_http_port  80      "HTTP traffic port"
    ask PLC_HTTPS_PORT is_https_port 443     "HTTPS traffic port"

    if [ "$setup" != keep ] && [ "$interactive" = yes ]; then
        host_addrs
    fi

    ask PLC_PANEL_BIND is_bind       127.0.0.1 "Panel address: 127.0.0.1 for this machine only, 0.0.0.0 for all addresses, or one address"
    ask PLC_PANEL_PORT is_panel_port 8081      "Panel port"

    # Nodes, inspectors and memory come with values that suit most machines.
    asked=$interactive

    if [ "$setup" != keep ] && [ "$interactive" = yes ]; then
        printf 'Change nodes, nginx processes, inspectors and Redis memory? [y/N]: '
        IFS= read -r reply || reply=""
        case "$reply" in
            y|Y|yes) ;;
            *) interactive=no ;;
        esac
    fi

    ask PLC_NODES         is_count   1    "Protection nodes on this machine, each nginx with its agent"
    ask PLC_NGINX_WORKERS is_workers auto "nginx processes per node: auto means one per core"

    for name in $INSPECTORS; do
        case "$name" in
            auth) ask PLC_COPIES_AUTH is_count  1 "Copies of the auth inspector: the panel login needs at least one" ;;
            vlai) ask PLC_COPIES_VLAI is_copies 0 "Copies of the vlai classifier, 0 is off: 4 GB more memory and a model download" ;;
            *)    ask "PLC_COPIES_$(upper "$name")" is_copies 1 "Copies of the $name inspector, 0 is off" ;;
        esac
    done

    ask PLC_REDIS_EXCHANGE_MB is_mb "$exchange" "Exchange Redis memory, MB: request objects waiting for a verdict"
    ask PLC_REDIS_INTERNAL_MB is_mb "$internal" "Internal Redis memory, MB: configuration and inspector state"

    interactive=$asked
}

label() {
    case "$1" in
        PLC_NODE_ID)           echo "node name" ;;
        PLC_HTTP_PORT)         echo "HTTP port" ;;
        PLC_HTTPS_PORT)        echo "HTTPS port" ;;
        PLC_PANEL_BIND)        echo "panel address" ;;
        PLC_PANEL_PORT)        echo "panel port" ;;
        PLC_NODES)             echo "nodes" ;;
        PLC_NGINX_WORKERS)     echo "nginx processes per node" ;;
        PLC_REDIS_EXCHANGE_MB) echo "exchange Redis, MB" ;;
        PLC_REDIS_INTERNAL_MB) echo "internal Redis, MB" ;;
        PLC_COPIES_*)          printf '%s copies\n' "$(printf '%s' "${1#PLC_COPIES_}" | tr '[:upper:]' '[:lower:]')" ;;
    esac
}

snapshot() {
    for name in $SETTINGS; do
        eval "printf '%s=%s\\n' \"\$name\" \"\${$name:-}\""
    done
}

# plan: what the answers install; changes <snapshot>: what differs from it.
plan() {
    say "plan"

    workers=${PLC_NGINX_WORKERS:-auto}

    if [ "${PLC_NODES:-1}" -gt 1 ]; then
        printf '  nodes        %s from %s, %s nginx processes each, haproxy in front on ports %s and %s\n' \
            "$PLC_NODES" "$PLC_NODE_ID" "$workers" "$PLC_HTTP_PORT" "$PLC_HTTPS_PORT"
    else
        printf '  node         %s, %s nginx processes, ports %s and %s\n' \
            "$PLC_NODE_ID" "$workers" "$PLC_HTTP_PORT" "$PLC_HTTPS_PORT"
    fi

    printf '  panel        %s:%s\n' "$PLC_PANEL_BIND" "$PLC_PANEL_PORT"

    on=""
    off=""

    for name in $INSPECTORS; do
        default=1
        [ "$name" != vlai ] || default=0
        eval "copies=\${PLC_COPIES_$(upper "$name"):-$default}"

        if [ "$copies" -eq 0 ]; then
            off="$off $name"
        elif [ "$copies" -eq 1 ]; then
            on="$on $name"
        else
            on="$on $name x$copies"
        fi
    done

    printf '  inspectors  %s\n' "$on"
    [ -z "$off" ] || printf '  off         %s\n' "$off"
    printf '  Redis        exchange %s MB, internal %s MB\n' "$PLC_REDIS_EXCHANGE_MB" "$PLC_REDIS_INTERNAL_MB"

    cores=$(nproc 2>/dev/null || echo 1)

    if [ "$workers" != auto ] && [ $((PLC_NODES * workers)) -gt "$cores" ]; then
        warn "$PLC_NODES nodes x $workers nginx processes is more than the $cores cores of this machine"
    fi
}

changes() {
    shown=no

    for name in $SETTINGS; do
        old=$(printf '%s\n' "$1" | sed -n "s/^$name=//p")
        eval "new=\${$name:-}"
        [ "$old" != "$new" ] || continue

        if [ "$shown" = no ]; then
            say "changes"
            shown=yes
        fi

        printf '  %-28s %s -> %s\n' "$(label "$name")" "${old:-none}" "$new"
    done

    [ "$shown" = yes ] || printf '\nno changes\n'
}

confirm() {
    [ "$interactive" = yes ] || return 0

    printf '\nApply? [Y/n]: '
    IFS= read -r reply || reply=""

    case "$reply" in
        n|N|no) return 1 ;;
    esac
}

# Docker refuses a CPU cap above the number of cores: caps are lowered to fit this machine.
cpu_limits() {
    cores=$(nproc 2>/dev/null || echo 1)

    for pair in PLC_CPUS:2 PLC_CPUS_NATS:6 PLC_CPUS_KEEPER:4; do
        name=${pair%%:*}
        eval "value=\${$name:-${pair#*:}}"

        if awk -v v="$value" -v c="$cores" 'BEGIN { exit !(v > c) }'; then
            set_env "$name" "$cores"
            printf 'CPU cap %s lowered to %s, the cores of this machine\n' "$name" "$cores"
        fi
    done
}

infra_services="nats nats-box postgres clickhouse redis redis-internal minio minio-mc"

infra() {
    say "infrastructure"
    # shellcheck disable=SC2086
    quietly "postgres, clickhouse, redis, nats, minio" compose waf.yml up -d --wait $infra_services
}

migrate() {
    say "database schema"

    if [ "$build" = yes ]; then
        quietly "controller build" compose waf.yml build controller
    fi

    quietly "PostgreSQL schema" compose waf.yml run --rm --no-deps controller node src/migrate.ts
}

components() {
    say "components"

    # A running controller checks the catalog first: an inspector that routes still call stays.
    if [ -n "$(compose waf.yml ps --status running -q controller 2>/dev/null)" ]; then
        err=$(mktemp)

        if ! result=$(layout_run catalog 2> "$err"); then
            cat "$err" >> "$log_file"
            why=$(sed -n 's/^Error: //p' "$err" | head -n 1)
            rm -f "$err"
            cat "$env_file.before" > "$env_file"
            die "${why:-the inspector catalog refused the change}; the answers stay as they were"
        fi

        rm -f "$err"
        [ -z "$result" ] || printf '%s\n' "$result" | sed 's/^/  /'
    fi

    # What the answers no longer run: vlai, haproxy for a single node, nodes beyond PLC_NODES.
    if [ "${PLC_COPIES_VLAI:-0}" -eq 0 ]; then
        compose waf.yml --profile vlai rm --stop --force inspector-vlai >> "$log_file" 2>&1 || true
    fi

    if [ "${PLC_NODES:-1}" -le 1 ]; then
        compose waf.yml --profile nodes rm --stop --force balancer >> "$log_file" 2>&1 || true
    fi

    docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-placitum}" \
        --filter label=placitum.install=node --format '{{.ID}} {{.Label "com.docker.compose.service"}}' |
    while read -r id service; do
        if [ "${service#edge-}" -gt "${PLC_NODES:-1}" ] 2>/dev/null; then
            docker rm -f "$id" >> "$log_file" 2>&1
        fi
    done

    if [ "$build" = yes ]; then
        quietly "image build (up to half an hour on the first install)" compose waf.yml build
    fi

    quietly "start and health check" compose waf.yml up -d --wait
}

panel() {
    say "panel"

    started=$(date +%s)
    printf '  login gate, admin and publish to the node ... '
    printf '\n== %s panel\n' "$(date '+%F %T')" >> "$log_file"

    # shellcheck disable=SC1090
    if [ -f "$env_file" ]; then . "$env_file"; fi

    if ! result=$(printf '%s' "$panel_pass" |
        compose waf.yml exec -T -e "PANEL_ADMIN=${1:-ensure}" \
            -e "PANEL_COOKIE_SECURE=${PLC_COOKIE_SECURE:-off}" controller \
            node --input-type=module -e "$(cat "$here/bootstrap/panel.mjs")" 2>> "$log_file"); then
        printf 'failed\n'
        log_tail
        die "panel setup failed, log: $log_file; controller directly: http://127.0.0.1:${PLC_CONTROLLER_PORT:-8080}"
    fi

    printf 'done, %s\n' "$(elapsed "$started")"

    case "$result" in
        created)
            printf 'admin created with the entered password\n'
            ;;
        updated)
            printf 'admin password changed\n'
            ;;
        kept)
            printf 'admin exists, password unchanged (to change it: %s panel-password)\n' "$cli"
            ;;
        "generated "*)
            printf '\npanel login: admin / %s\n' "${result#generated }"
            printf 'the password is not stored anywhere: write it down or change it with %s panel-password\n' "$cli"
            ;;
        *)
            die "unexpected answer from bootstrap/panel.mjs: $result"
            ;;
    esac
}

# layout.mjs in the controller with the answers: inspectors, nginx processes, nodes behind haproxy.
layout_run() {
    nodes=""
    inspectors=""
    i=1

    while [ "$i" -le "${PLC_NODES:-1}" ]; do
        service=edge
        [ "$i" -eq 1 ] || service="edge-$(printf '%02d' "$i")"
        nodes="$nodes $service:$(node_name "$i")"
        i=$((i + 1))
    done

    for name in $INSPECTORS; do
        default=1
        [ "$name" != vlai ] || default=0
        eval "copies=\${PLC_COPIES_$(upper "$name"):-$default}"
        [ "$copies" -eq 0 ] || inspectors="$inspectors $name"
    done

    compose waf.yml exec -T \
        -e "LAYOUT_STEP=$1" \
        -e "LAYOUT_INSPECTORS=${inspectors# }" \
        -e "LAYOUT_WORKERS=${PLC_NGINX_WORKERS:-auto}" \
        -e "LAYOUT_NODES=${nodes# }" \
        controller node --input-type=module -e "$(cat "$here/bootstrap/layout.mjs")"
}

layout() {
    say "layout"

    started=$(date +%s)
    printf '  inspectors, nginx processes, ports, haproxy ... '
    printf '\n== %s layout\n' "$(date '+%F %T')" >> "$log_file"

    if ! result=$(layout_run all 2>> "$log_file"); then
        printf 'failed\n'
        log_tail
        die "layout step failed, log: $log_file"
    fi

    printf 'done, %s\n' "$(elapsed "$started")"
    [ -z "$result" ] || printf '%s\n' "$result" | sed 's/^/  /'
}

publish() {
    say "publish"

    started=$(date +%s)
    printf '  configuration channels to processes ... '
    printf '\n== %s publish\n' "$(date '+%F %T')" >> "$log_file"

    if ! result=$(compose waf.yml exec -T controller \
        node --input-type=module -e "$(cat "$here/bootstrap/publish.mjs")" 2>> "$log_file"); then
        printf 'failed\n'
        log_tail
        die "configuration channels did not converge, log: $log_file"
    fi

    printf 'done, %s\n' "$(elapsed "$started")"
    printf '%s\n' "$result"
}

panel_password() {
    ask_panel_password "Enter to generate"
    panel reset

    compose waf.yml exec -T redis-internal sh -c \
        "redis-cli --scan --pattern 'auth:*:panel/*' | xargs -r redis-cli del >/dev/null" &&
        printf 'panel login lockouts cleared\n'
}

health() {
    rows=$(compose waf.yml ps -a --format '{{.Service}} {{.State}} {{.Health}}')
    total=$(printf '%s\n' "$rows" | grep -c . || true)
    bad=$(printf '%s\n' "$rows" | awk 'NF && ($2 != "running" || ($3 != "" && $3 != "healthy"))')

    if [ -z "$bad" ]; then
        printf 'containers: %s, all running\n' "$total"
        return 0
    fi

    warn "containers with problems ($(printf '%s\n' "$bad" | grep -c .) of $total):"
    printf '%s\n' "$bad" | sed 's/^/     /' >&2
}

summary() {
    # shellcheck disable=SC1090
    . "$env_file"
    bind=${PLC_PANEL_BIND:-127.0.0.1}
    port=${PLC_PANEL_PORT:-8081}

    printf '\n'

    if [ "$bind" = 0.0.0.0 ]; then
        machine_addrs | while read -r addr _; do
            printf 'panel:   http://%s:%s\n' "$addr" "$port"
        done
    else
        printf 'panel:   http://%s:%s\n' "$bind" "$port"
    fi

    printf 'login:   admin, change the password with %s panel-password\n' "$cli"
    printf 'API:     http://127.0.0.1:%s, no login, this machine only (from elsewhere use ssh -L)\n' \
        "${PLC_CONTROLLER_PORT:-8080}"
    printf 'traffic: port %s\n' "${PLC_HTTP_PORT:-80}"
    printf 'log:     %s\n' "$log_file"
}

install_all() {
    : > "$log_file"
    preflight
    prepare_env
    check_panel
    ask_panel_password "$1"
    infra
    migrate
    components
    panel
    layout
    publish
    say "done"
    rm -f "$env_file.before"
    health
    summary
}

case "$cmd" in
    check)
        preflight
        check_panel
        ;;
    install)
        install_all "Enter keeps the current one or generates one on the first install"
        ;;
    reconfigure)
        [ -f "$env_file" ] || die "$env_file not found: install first ($cli install)"
        [ "$interactive" = yes ] || [ "$defaults" = yes ] ||
            die "reconfigure asks on a terminal; without one, pass --defaults and set the new values in the environment"
        build=no
        install_all "Enter keeps the current one"
        ;;
    infra)
        preflight
        prepare_env
        infra
        ;;
    panel|panel-password)
        [ -f "$env_file" ] || die "$env_file not found: set up the panel on an installed system ($cli install)"
        # shellcheck disable=SC1090
        . "$env_file"

        if [ "$cmd" = panel ]; then
            panel
        else
            panel_password
        fi
        ;;
    status)
        say "status"
        compose waf.yml ps
        printf '\n'
        health
        summary
        ;;
    down)
        say "stopping"
        compose waf.yml down
        ;;
    help|-h|--help)
        sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "unknown command: $cmd (see $cli help)"
        ;;
esac
