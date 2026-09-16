#!/bin/sh
# Placitum installer: environment, secrets, infrastructure, components, panel.
#
#     ./install.sh check            checks only, changes nothing
#     ./install.sh install          everything in order
#     ./install.sh infra            infrastructure only
#     ./install.sh panel            set up the panel on a running installation
#     ./install.sh panel-password   change the panel admin password and lift the login lockout
#     ./install.sh status           what is running and how it is doing
#     ./install.sh down             stop everything; volumes and data stay
#
# Options:
#     --sources <file>   component sources; default sources.env
#     --no-build         start already built images without rebuilding
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
cmd=${1:-help}
[ $# -gt 0 ] && shift || true

while [ $# -gt 0 ]; do
    case "$1" in
        --sources) sources=$2; shift 2 ;;
        --no-build) build=no; shift ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf '!! %s\n' "$*" >&2; exit 1; }

compose() {
    file=$1
    shift
    docker compose --ansi never --progress plain \
        --env-file "$env_file" --env-file "$sources" -f "$here/compose/$file" "$@"
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
    if [ -n "${free:-}" ] && [ "$free" -lt 20 ]; then
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

    if [ ! -f "$env_file" ]; then
        cp "$here/.env.example" "$env_file"
        printf 'created %s from .env.example; check the ports and credentials\n' "$env_file"
    else
        printf 'environment file exists: %s\n' "$env_file"
    fi

    # shellcheck disable=SC1090
    . "$env_file"
    quietly "keys and secrets" env MINIO_ROOT_USER="${MINIO_ROOT_USER:-waf}" \
        MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-wafwafwaf}" sh "$here/bootstrap/secrets.sh"

    fp=$(sh "$here/bootstrap/secrets.sh" --fingerprint)
    set_env VITE_CONTOUR_FINGERPRINT "$fp"

    node_id=${PLC_NODE_ID:-edge-01}
    printf '%s\n' \
        "# Node name for the module; install.sh rewrites this file from PLC_NODE_ID." \
        "waf_node_id $node_id;" > "$here/config/edge/node.conf"
    printf 'node: %s\n' "$node_id"
}

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

    if ! result=$(printf '%s' "$panel_pass" |
        compose waf.yml exec -T -e "PANEL_ADMIN=${1:-ensure}" controller \
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
            printf 'admin exists, password unchanged (to change it: ./install.sh panel-password)\n'
            ;;
        "generated "*)
            printf '\npanel login: admin / %s\n' "${result#generated }"
            printf 'the password is not stored anywhere: write it down or change it with ./install.sh panel-password\n'
            ;;
        *)
            die "unexpected answer from bootstrap/panel.mjs: $result"
            ;;
    esac
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

    printf 'login:   admin, change the password with ./install.sh panel-password\n'
    printf 'API:     http://127.0.0.1:%s, no login, this machine only (from elsewhere use ssh -L)\n' \
        "${PLC_CONTROLLER_PORT:-8080}"
    printf 'traffic: port %s\n' "${PLC_HTTP_PORT:-80}"
    printf 'log:     %s\n' "$log_file"
}

case "$cmd" in
    check)
        preflight
        check_panel
        ;;
    install)
        : > "$log_file"
        preflight
        prepare_env
        check_panel
        ask_panel_password "Enter keeps the current one or generates one on the first install"
        infra
        migrate
        components
        panel
        publish
        say "done"
        health
        summary
        ;;
    infra)
        preflight
        prepare_env
        infra
        ;;
    panel|panel-password)
        [ -f "$env_file" ] || die "$env_file not found: set up the panel on an installed system (./install.sh install)"
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
        sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "unknown command: $cmd (see ./install.sh help)"
        ;;
esac
