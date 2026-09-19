#!/bin/sh
# Placitum installer: settings, secrets, infrastructure, components, panel.
#
#     ./install.sh check            checks only, changes nothing
#     ./install.sh install          everything in order; the first run asks the settings
#     ./install.sh reconfigure      ask the settings again and apply them; data stays
#     ./install.sh infra            infrastructure only
#     ./install.sh panel            set up the panel on a running installation
#     ./install.sh panel-password   change the panel admin password and lift the login lockout
#     ./install.sh status           what is running and how it is doing
#     ./install.sh down             stop everything; volumes and data stay
#
# Options:
#     --sources <file>   component sources; default sources.env
#     --no-build         never build images: only what already has an image here
#     --defaults         no questions: settings come from the environment or defaults
#
# Images are built on this machine from sources, so it needs access to the git
# repositories, base images and the Go module proxy.
#
# A single node is nginx with the module on this machine when the machine has it (the machine
# image does; as root on Debian or Ubuntu the installer puts it there), otherwise a container.
# Several nodes are containers behind haproxy, which likewise runs on this machine when it can.

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
created=no
absent=""
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
SETTINGS="PLC_NODE_ID PLC_TRAFFIC_BIND PLC_HTTP_PORT PLC_HTTPS_PORT PLC_PANEL_BIND PLC_PANEL_PORT PLC_PANEL_LOGIN PLC_SUBNET"
SETTINGS="$SETTINGS PLC_NODES PLC_NGINX_WORKERS"

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

# The machine image carries haproxy and its agent as services of this machine: with several nodes
# they take the traffic ports instead of a haproxy container.
host_balancer() {
    [ -x /usr/local/bin/waf-haproxy-agent ] && [ -f /etc/systemd/system/placitum-haproxy.service ] &&
        [ -d /run/systemd/system ]
}

# nginx of this machine, also for a user without /usr/sbin in the path.
nginx_bin() {
    command -v nginx 2>/dev/null || { [ -x /usr/sbin/nginx ] && echo /usr/sbin/nginx; }
}

# The machine can run the single node itself: nginx of the module's version with the module, the
# node agent and its service, put there by image/host.sh.
host_node() {
    [ -x /usr/local/bin/waf-agent ] && [ -f /etc/systemd/system/placitum-node-agent.service ] &&
        [ -f /usr/lib/nginx/modules/ngx_http_waf_module.so ] && [ -n "$(nginx_bin)" ] &&
        [ -d /run/systemd/system ]
}

# host_why node|balancer: why this run cannot put the service on this machine with image/host.sh;
# empty when it can. Root on Debian or Ubuntu with systemd; nginx of another version or a haproxy
# this machine runs for something else stays as it is.
host_why() {
    [ "$(id -u)" -eq 0 ] || { echo "run the installer as root to put it on this machine"; return 0; }
    [ -d /run/systemd/system ] && command -v apt-get >/dev/null 2>&1 &&
        grep -Eq '^ID=(debian|ubuntu)$' /etc/os-release 2>/dev/null ||
        { echo "on Debian or Ubuntu with systemd it goes on the machine itself"; return 0; }

    case "$1" in
        node)
            if [ -n "$(nginx_bin)" ]; then
                have=$("$(nginx_bin)" -v 2>&1 | sed -n 's|^nginx version: nginx/||p')
                [ "$have" = "${NGINX_VERSION:-1.28.0}" ] ||
                    echo "this machine has nginx $have of its own, the module is built for ${NGINX_VERSION:-1.28.0}"
            fi
            ;;
        balancer)
            if systemctl is-enabled --quiet haproxy 2>/dev/null || systemctl is-active --quiet haproxy 2>/dev/null; then
                echo "this machine runs haproxy of its own"
            fi
            ;;
    esac
}

# node_place: host or container, where the single node runs. Several nodes are containers.
node_place() {
    if [ "${PLC_NODES:-1}" -le 1 ] && { host_node || [ -z "$(host_why node)" ]; }; then
        echo host
    else
        echo container
    fi
}

# balancer_place: none with one node; host or container, where haproxy in front of several runs.
balancer_place() {
    if [ "${PLC_NODES:-1}" -le 1 ]; then
        echo none
    elif host_balancer || [ -z "$(host_why balancer)" ]; then
        echo host
    else
        echo container
    fi
}

# resolver_of: the nameservers of this machine for nginx on it, with the options of the Docker one.
resolver_of() {
    ns=$(awk '/^nameserver/ { print $2 }' /etc/resolv.conf 2>/dev/null | grep -v ':' | head -n 3 | tr '\n' ' ')
    printf '%svalid=10s ipv6=off' "${ns:-127.0.0.53 }"
}

# Compose with the values that follow from the answers: the vlai and haproxy profiles, the captcha
# form, the CPU cap of a node and compose/layout.yml unless skip_layout says otherwise.
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

        if [ "$(balancer_place)" = container ]; then
            COMPOSE_PROFILES="${COMPOSE_PROFILES:+$COMPOSE_PROFILES,}nodes"
        fi

        PLC_CAPTCHA_FORM=1
        [ "${PLC_COPIES_CAPTCHA:-1}" -gt 0 ] || PLC_CAPTCHA_FORM=0
        PLC_CPUS_EDGE=$edge
        export COMPOSE_PROFILES PLC_CAPTCHA_FORM PLC_CPUS_EDGE

        if [ -f "$here/compose/layout.yml" ] && [ "${skip_layout:-no}" = no ]; then
            set -- -f "$here/compose/$file" -f "$here/compose/layout.yml" "$@"
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

# net <network> <what>: addresses in the installation network. base; gateway; nats, balancer,
# redis, internal, minio, controller, auth, captcha and node:<n> are fixed at its start; range is
# the upper half for the other containers, capacity their number.
net() {
    awk -v cidr="$1" -v what="$2" '
        function ip2n(s, p) { split(s, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
        function n2ip(n) { return int(n / 16777216) % 256 "." int(n / 65536) % 256 "." int(n / 256) % 256 "." n % 256 }
        BEGIN {
            split(cidr, c, "/")
            size = 2 ^ (32 - c[2])
            base = int(ip2n(c[1]) / size) * size
            if (what == "base") print n2ip(base)
            else if (what == "gateway") print n2ip(base + 1)
            else if (what == "nats") print n2ip(base + 2)
            else if (what == "balancer") print n2ip(base + 3)
            else if (what == "redis") print n2ip(base + 4)
            else if (what == "internal") print n2ip(base + 5)
            else if (what == "minio") print n2ip(base + 6)
            else if (what == "controller") print n2ip(base + 7)
            else if (what == "auth") print n2ip(base + 8)
            else if (what == "captcha") print n2ip(base + 9)
            else if (what ~ /^node:/) print n2ip(base + 10 + substr(what, 6))
            else if (what == "range") print n2ip(base + size / 2) "/" (c[2] + 1)
            else if (what == "capacity") print size / 2 - 2
        }'
}

# The id of the installation network, when Docker has it.
own_net() {
    docker network inspect -f '{{.Id}}' "${COMPOSE_PROJECT_NAME:-placitum}_default" 2>/dev/null | cut -c1-12
}

# net_overlap <network>: the first network this machine reaches, by a route or a Docker network,
# that overlaps the given one. The installation network itself does not count.
net_overlap() {
    own=$(own_net)

    {
        ip -o -4 route show 2>/dev/null | awk -v dev="br-$own" '
            $1 != "default" { d = ""; for (i = 2; i < NF; i++) if ($i == "dev") d = $(i + 1); if (d != dev) print $1 }'

        docker network ls -q 2>/dev/null | while read -r id; do
            [ "$id" != "$own" ] || continue
            docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$id" 2>/dev/null | tr ' ' '\n'
        done
    } | awk -v want="$1" '
        function ip2n(s, p) { split(s, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
        function first(c, q) { split(c, q, "/"); if (q[2] == "") q[2] = 32; return int(ip2n(q[1]) / 2 ^ (32 - q[2])) * 2 ^ (32 - q[2]) }
        function last(c, q) { split(c, q, "/"); if (q[2] == "") q[2] = 32; return first(c) + 2 ^ (32 - q[2]) - 1 }
        BEGIN { a = first(want); b = last(want) }
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ { if (first($0) <= b && last($0) >= a) { print $0; exit } }'
}

# net_moves: Docker has the installation network with other addresses than the answers give it.
net_moves() {
    have=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}|{{.IPRange}}|{{.Gateway}} {{end}}' \
        "${COMPOSE_PROJECT_NAME:-placitum}_default" 2>/dev/null | tr ' ' '\n' | grep '^[0-9]*\.' | head -n 1)

    [ -n "$have" ] && [ "$have" != "$PLC_SUBNET|$(net "$PLC_SUBNET" range)|$(net "$PLC_SUBNET" gateway)" ]
}

# net_guests: containers of other projects in the installation network, "name alias,alias" per line.
# Labels of an image do not count: compose writes its config hash only on containers it creates.
net_guests() {
    network="${COMPOSE_PROJECT_NAME:-placitum}_default"

    docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$network" 2>/dev/null |
        tr ' ' '\n' | while read -r name; do
            [ -n "$name" ] || continue
            mark=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.config-hash"}}' "$name" 2>/dev/null || true)

            case "$mark" in
                "${COMPOSE_PROJECT_NAME:-placitum}|"?*) continue ;;
            esac

            aliases=$(docker inspect -f "{{with index .NetworkSettings.Networks \"$network\"}}{{join .Aliases \",\"}}{{end}}" "$name" 2>/dev/null || true)
            printf '%s %s\n' "$name" "$aliases"
        done
}

# The installation network Docker already has, or the first free one of a few.
proposed_subnet() {
    current=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' \
        "${COMPOSE_PROJECT_NAME:-placitum}_default" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+/[0-9]+$' | head -n 1)

    if [ -n "$current" ] && is_subnet "$current"; then
        printf '%s' "$current"
        return 0
    fi

    for candidate in 172.30.0.0/24 172.29.0.0/24 172.28.0.0/24 10.230.0.0/24 10.231.0.0/24 192.168.230.0/24; do
        if [ -z "$(net_overlap "$candidate")" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    printf '172.30.0.0/24'
}

check_panel() {
    say "panel"

    # shellcheck disable=SC1090
    if [ -f "$env_file" ]; then . "$env_file"; else . "$here/.env.example"; fi

    bind=${PLC_PANEL_BIND:-127.0.0.1}
    port=${PLC_PANEL_PORT:-8080}

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

# images_missing [all]: "service image" for every service of the answers whose image is not on this
# machine; all adds vlai and haproxy whatever the answers.
images_missing() {
    profiles=""
    [ "${1:-}" != all ] || profiles="--profile vlai --profile nodes"

    # shellcheck disable=SC2086
    compose waf.yml $profiles config --format json | awk '
        function flush() {
            if (service != "") print service, (image != "" ? image : project "-" service)
            service = ""
            image = ""
        }
        /^  "name": "/ { project = $2; gsub(/[",]/, "", project) }
        /^  "services": \{/ { inside = 1; next }
        inside && /^  [^ ]/ { flush(); inside = 0 }
        inside && /^    "[^"]*": \{/ { flush(); service = $1; gsub(/[":]/, "", service) }
        inside && /^      "image": "/ { image = $2; gsub(/[",]/, "", image) }
    ' | while read -r service image; do
        docker image inspect "$image" >/dev/null 2>&1 || printf '%s %s\n' "$service" "$image"
    done
}

# .env as it was before this run; a file created by this run goes, so the next run asks again.
restore_env() {
    if [ "$created" = yes ]; then
        rm -f "$env_file"
    else
        cat "$env_file.before" > "$env_file"
    fi

    rm -f "$env_file.before"
}

# containers: how many containers the answers run, copies and nodes included.
containers() {
    skip_layout=yes
    total=$(compose waf.yml config --format json | awk -v nodes="${PLC_NODES:-1}" '
        /^  "services": \{/ { inside = 1; next }
        inside && /^  [^ ]/ { inside = 0 }
        inside && /^    "[^"]*": \{/ { total += 1 }
        inside && /^        "replicas": [0-9]/ { n = $2; gsub(/,/, "", n); total += n - 1 }
        END { print total + nodes - 1 }')
    skip_layout=no
    printf '%s' "$total"
}

# The installation network holds the answers: nodes, NATS, both Redis, MinIO, the controller, the
# forms and the haproxy container at its start, every other container in its upper half.
check_network() {
    fixed=$((${PLC_NODES:-1} + 7))

    if [ "$(balancer_place)" = container ]; then
        fixed=$((fixed + 1))
    fi

    others=$(($(containers) - fixed))
    capacity=$(net "$PLC_SUBNET" capacity)

    [ "$others" -le "$capacity" ] ||
        die "network $PLC_SUBNET has room for $capacity containers besides nodes and NATS, the answers run $others: choose a larger network; nothing changed"
}

# A machine that does not build images needs an image for everything the answers run.
check_images() {
    [ "$build" = no ] || return 0

    missing=$(images_missing | awk '{ printf "%s%s", sep, $1; sep = ", " }')
    [ -z "$missing" ] || die "no image on this machine for $missing, and images are not built here; nothing changed"
}

# A running controller takes the inspectors of the answers into its catalog before anything else
# changes: an inspector that routes still call stays, and the run stops.
check_catalog() {
    [ -n "$(compose waf.yml ps --status running -q controller 2>/dev/null)" ] || return 0

    err=$(mktemp)

    if ! result=$(layout_run catalog 2> "$err"); then
        cat "$err" >> "$log_file"
        why=$(sed -n 's/^Error: //p' "$err" | head -n 1)
        rm -f "$err"
        die "${why:-the inspector catalog refused the change}; nothing changed"
    fi

    rm -f "$err"
    [ -z "$result" ] || printf '%s\n' "$result" | sed 's/^/  /'
}

prepare_env() {
    say "environment"

    setup=keep
    created=no

    if [ ! -f "$env_file" ]; then
        cp "$here/.env.example" "$env_file"
        chmod 600 "$env_file"

        for name in POSTGRES_PASSWORD CLICKHOUSE_PASSWORD MINIO_ROOT_PASSWORD; do
            set_env "$name" "$(openssl rand -hex 16)"
        done

        setup=fresh
        created=yes
        printf 'created %s with new infrastructure passwords\n' "$env_file"
    else
        printf 'environment file exists: %s\n' "$env_file"
    fi

    [ "$cmd" != reconfigure ] || setup=reconfigure

    # The answers before this run: a run that stops before they are accepted puts them back.
    cp -p "$env_file" "$env_file.before"
    trap restore_env EXIT
    trap 'exit 130' INT TERM

    if [ "$build" = no ]; then
        absent=$(images_missing all)
    fi

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

    check_network
    check_images
    check_catalog
    trap - EXIT INT TERM

    cpu_limits

    # shellcheck disable=SC1090
    . "$env_file"
    quietly "keys and secrets" env MINIO_ROOT_USER="${MINIO_ROOT_USER:-waf}" \
        MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-wafwafwaf}" sh "$here/bootstrap/secrets.sh"

    layout_files
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

# address <ip>: the fixed address of a service in compose/layout.yml.
address() {
    printf '    networks:\n      default:\n        ipv4_address: %s\n' "$1"
}

# traffic_ports: HTTP and HTTPS on every traffic address; 0.0.0.0 publishes on IPv6 as well.
traffic_ports() {
    for addr in $(printf '%s' "$PLC_TRAFFIC_BIND" | tr ',' ' '); do
        at="$addr:"
        [ "$addr" != 0.0.0.0 ] || at=""
        printf '      - "%s%s:8080"\n      - "%s%s:8443"\n' "$at" "$PLC_HTTP_PORT" "$at" "$PLC_HTTPS_PORT"
    done
}

# node.conf of every node and compose/layout.yml: the installation network, fixed addresses, traffic
# ports and the nodes after the first, rebuilt from the answers on every run. With the node on this
# machine the edge service runs no container, and the controller writes the fixed addresses of NATS
# and Redis into the node configuration.
layout_files() {
    count=${PLC_NODES:-1}
    layout="$here/compose/layout.yml"
    node=$(node_place)
    balancer=$(balancer_place)

    rm -f "$here"/config/edge/node-*.conf "$here/compose/nodes.yml"

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

    # The traffic ports belong to the node container, to the haproxy container, or to nginx or
    # haproxy on this machine, which bind them themselves.
    owner=edge
    if [ "$count" -gt 1 ]; then
        owner=balancer
        [ "$balancer" != host ] || owner=host
    elif [ "$node" = host ]; then
        owner=host
    fi

    {
        printf '# Written by install.sh from the answers: changes here are lost on the next run.\n\n'
        printf 'networks:\n  default:\n    ipam:\n      config:\n'
        printf '        - subnet: %s\n' "$PLC_SUBNET"
        printf '          ip_range: %s\n' "$(net "$PLC_SUBNET" range)"
        printf '          gateway: %s\n' "$(net "$PLC_SUBNET" gateway)"

        printf '\nservices:\n'

        for pair in nats:nats redis:redis redis-internal:internal minio:minio auth-http:auth captcha-http:captcha; do
            printf '  %s:\n' "${pair%%:*}"
            address "$(net "$PLC_SUBNET" "${pair#*:}")"
        done

        printf '  controller:\n'
        if [ "$node" = host ]; then
            printf '    environment:\n'
            printf '      CONTROLLER_NODE_NATS_URL: nats://%s:4222\n' "$(net "$PLC_SUBNET" nats)"
            printf '      CONTROLLER_NODE_REDIS_URL: redis://%s:6379\n' "$(net "$PLC_SUBNET" redis)"
            printf '      CONTROLLER_NODE_REDIS_INTERNAL_URL: redis://%s:6379\n' "$(net "$PLC_SUBNET" internal)"
        fi
        address "$(net "$PLC_SUBNET" controller)"

        printf '\n  edge:\n'
        if [ "$node" = host ]; then
            printf '    deploy:\n      replicas: 0\n'
            printf '    ports: !override []\n'
        else
            printf '    ports: !override\n'
            [ "$owner" != edge ] || traffic_ports
            printf '      - "%s:%s:8081"\n' "$PLC_PANEL_BIND" "$PLC_PANEL_PORT"
        fi
        address "$(net "$PLC_SUBNET" node:1)"

        if [ "$owner" = balancer ]; then
            printf '\n  balancer:\n'
            printf '    ports: !override\n'
            traffic_ports
            address "$(net "$PLC_SUBNET" balancer)"
        fi

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
            address "$(net "$PLC_SUBNET" "node:$i")"
            i=$((i + 1))
        done

        if [ "$count" -gt 1 ]; then
            printf '\nvolumes:\n'

            i=2
            while [ "$i" -le "$count" ]; do
                printf '  edge-%s-data:\n  edge-%s-store:\n' "$(printf '%02d' "$i")" "$(printf '%02d' "$i")"
                i=$((i + 1))
            done
        fi
    } > "$layout"
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
is_nodes()  { is_count "$1" && [ "$1" -ge 2 ]; }
is_login()  { printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; }

is_workers() {
    [ "$1" = auto ] || { printf '%s' "$1" | grep -Eq '^[0-9]{1,3}$' && [ "$1" -ge 1 ] && [ "$1" -le 256 ]; }
}

is_http_port()  { is_port "$1" && [ "$1" != "${PLC_CONTROLLER_PORT:-8081}" ]; }
is_https_port() { is_http_port "$1" && [ "$1" != "${PLC_HTTP_PORT:-}" ]; }
is_panel_port() { is_https_port "$1" && [ "$1" != "${PLC_HTTPS_PORT:-}" ]; }

is_ipv4() {
    printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' &&
        printf '%s' "$1" | awk -F. '{ for (i = 1; i <= 4; i++) if ($i > 255) exit 1 }'
}

is_bind() {
    case "$1" in
        0.0.0.0|127.0.0.1) return 0 ;;
    esac

    is_ipv4 "$1" || return 1
    command -v ip >/dev/null 2>&1 || return 0
    ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx "$1"
}

# is_bind_list: 0.0.0.0, or up to eight addresses of this machine separated by commas.
is_bind_list() {
    [ "$1" != 0.0.0.0 ] || return 0

    case "$1" in
        ''|*' '*|,*|*,|*,,*) return 1 ;;
    esac

    seen=" "
    for addr in $(printf '%s' "$1" | tr ',' ' '); do
        [ "$addr" != 0.0.0.0 ] && is_bind "$addr" || return 1

        case "$seen" in *" $addr "*) return 1 ;; esac
        seen="$seen$addr "
    done

    [ "$(printf '%s' "$seen" | wc -w)" -le 8 ]
}

# is_subnet: an IPv4 network from /16 to /24 that overlaps no network this machine reaches.
is_subnet() {
    printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/(1[6-9]|2[0-4])$' || return 1
    is_ipv4 "${1%/*}" && [ "$(net "$1" base)" = "${1%/*}" ] && [ -z "$(net_overlap "$1")" ]
}

# why <check> <answer>: what a valid answer looks like.
why() {
    case "$1" in
        is_name)       echo "lowercase latin letters, digits and hyphens" ;;
        is_mb)         echo "megabytes, at least 64" ;;
        is_count)      echo "a number from 1 to 32" ;;
        is_nodes)      echo "a number from 2 to 32: with one node there is nothing to balance" ;;
        is_login)      echo "lowercase latin letters, digits, - and _, up to 32, starting with a letter" ;;
        is_copies)     echo "a number from 0 to 32; 0 turns the inspector off" ;;
        is_workers)    echo "auto or a number from 1 to 256" ;;
        is_http_port)  echo "a port from 1 to 65535, not the controller API port" ;;
        is_https_port) echo "a port from 1 to 65535, not the HTTP port or the controller API port" ;;
        is_panel_port) echo "a port from 1 to 65535, not a traffic port or the controller API port" ;;
        is_bind)       echo "0.0.0.0, 127.0.0.1 or an IPv4 address of this machine" ;;
        is_bind_list)  echo "0.0.0.0, or up to 8 IPv4 addresses of this machine separated by commas without spaces" ;;
        is_subnet)
            overlap=""
            if printf '%s' "${2:-}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
                overlap=$(net_overlap "$2")
            fi

            if [ -n "$overlap" ]; then
                echo "overlaps $overlap, a network this machine already reaches"
            else
                echo "an IPv4 network from /16 to /24 written from its first address, such as 172.30.0.0/24"
            fi
            ;;
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
            # A .env from before this setting gets the default without a question.
            if [ -z "$current" ]; then
                eval "$var=\$default"
                set_env "$var" "$default"
                return 0
            fi

            "$check" "$current" || die "$env_file: $var=$current -- $(why "$check" "$current")"
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

        [ "$interactive" = yes ] || die "$var=$answer -- $(why "$check" "$answer")"
        warn "$(why "$check" "$answer")"
    done

    eval "$var=\$answer"
    set_env "$var" "$answer"
}

# quiet <variable> <check> <default>: a setting without a question: the environment, the current
# answer or the default, checked like an answer.
quiet() {
    was=$interactive
    interactive=no
    ask "$1" "$2" "$3" ""
    interactive=$was
}

# yes_no <question> <y|n>: on a terminal asks, otherwise takes the default. True for yes.
yes_no() {
    if [ "$interactive" != yes ]; then
        [ "$2" = y ]
        return
    fi

    while :; do
        if [ "$2" = y ]; then
            printf '%s [Y/n]: ' "$1"
        else
            printf '%s [y/N]: ' "$1"
        fi

        IFS= read -r reply || reply=""

        case "$reply" in
            "")           [ "$2" = y ]; return ;;
            y|Y|yes|Yes)  return 0 ;;
            n|N|no|No)    return 1 ;;
        esac
    done
}

# port_taken <port>: something on this machine listens on it already.
port_taken() {
    command -v ss >/dev/null 2>&1 || return 1
    ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
}

# ask_port <variable> <check> <default> <question>: a fresh installation asks about a port only
# when the machine has something on it already; reconfigure asks as usual.
ask_port() {
    eval "given=\${given_$1:-}"

    if [ "$setup" = reconfigure ]; then
        ask "$@"
    elif [ "$setup" = fresh ] && [ -z "$given" ] && port_taken "$3"; then
        warn "port $3 is taken on this machine already"
        ask "$@"
    else
        quiet "$1" "$2" "$3"
    fi
}

# effective <variable> <default>: what a question would take without an answer: the environment,
# then the current answer, except on a fresh installation, where .env still holds the example
# and the default of this machine counts.
effective() {
    eval "given=\${given_$1:-}"
    eval "current=\${$1:-}"

    if [ -n "$given" ]; then
        printf '%s' "$given"
    elif [ "$setup" != fresh ] && [ -n "$current" ]; then
        printf '%s' "$current"
    else
        printf '%s' "$2"
    fi
}

# copies <inspector>: the copies the answers give an inspector; the standard is one of everything
# but vlai.
copies() {
    default=1
    [ "$1" != vlai ] || default=0
    effective "PLC_COPIES_$(upper "$1")" "$default"
}

# absent <inspector>: this machine builds no images and has none for the inspector.
absent() {
    printf '%s\n' "$absent" | grep -q "^inspector-$1 "
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

    # The node takes the name of this machine when it fits, edge-01 otherwise; the panel login is
    # admin unless the environment says otherwise. Neither is a question.
    node=$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -d. -f1)
    is_name "$node" || node=edge-01
    quiet PLC_NODE_ID is_name "$node"
    quiet PLC_PANEL_LOGIN is_login admin

    if [ "$setup" != keep ] && [ "$interactive" = yes ]; then
        host_addrs
    fi

    ask PLC_TRAFFIC_BIND is_bind_list 0.0.0.0 "Traffic addresses: 0.0.0.0 for all, or addresses of this machine separated by commas"
    ask_port PLC_HTTP_PORT  is_http_port  80  "HTTP traffic port"
    ask_port PLC_HTTPS_PORT is_https_port 443 "HTTPS traffic port"
    ask PLC_PANEL_BIND is_bind 127.0.0.1 "Panel address: 127.0.0.1 for this machine only, 0.0.0.0 for all addresses, or one address"
    ask_port PLC_PANEL_PORT is_panel_port 8080 "Panel port"

    # The network is proposed only when it is asked or missing: the proposal looks at every route.
    subnet=""
    if [ "$setup" != keep ] || [ -z "${PLC_SUBNET:-}" ]; then
        subnet=$(proposed_subnet)
    fi

    ask PLC_SUBNET is_subnet "$subnet" "Installation network for the containers, /16 to /24, apart from the networks of this machine"

    # A .env from before these settings gets them without a question.
    if [ -z "${PLC_TRAFFIC_BIND:-}" ]; then
        PLC_TRAFFIC_BIND=0.0.0.0
        set_env PLC_TRAFFIC_BIND "$PLC_TRAFFIC_BIND"
    fi

    if [ -z "${PLC_SUBNET:-}" ]; then
        PLC_SUBNET=$subnet
        set_env PLC_SUBNET "$PLC_SUBNET"
    fi

    # One node on this machine, or several in containers behind a balancer.
    nodes=$(effective PLC_NODES 1)

    if [ "$setup" = keep ]; then
        quiet PLC_NODES is_count "$nodes"
    else
        default=n
        [ "$nodes" -le 1 ] || default=y

        if yes_no "Several protection nodes behind a balancer, so that a node can be restarted without dropping traffic?" "$default"; then
            [ "$nodes" -ge 2 ] || nodes=2
            ask PLC_NODES is_nodes "$nodes" "Protection nodes behind the balancer"
        else
            PLC_NODES=1
            set_env PLC_NODES 1
        fi
    fi

    # Which inspectors run. The standard set is every inspector but vlai; a machine that builds
    # no images cannot turn on an inspector it has no image for.
    standard=y
    list=""

    for name in $INSPECTORS; do
        if absent "$name"; then
            continue
        fi

        [ "$name" = vlai ] || list="$list $name"

        case "$name:$(copies "$name")" in
            vlai:0) ;;
            vlai:*) standard=n ;;
            *:0)    standard=n ;;
        esac
    done

    if [ "$setup" = keep ]; then
        for name in $INSPECTORS; do
            if absent "$name"; then
                continue
            fi

            case "$name" in
                auth) quiet PLC_COPIES_AUTH is_count "$(copies "$name")" ;;
                *)    quiet "PLC_COPIES_$(upper "$name")" is_copies "$(copies "$name")" ;;
            esac
        done
    elif yes_no "Standard set of inspectors (${list# })?" "$standard"; then
        # Every inspector on with the copies it has, an inspector that was off with one, vlai off.
        for name in $INSPECTORS; do
            if absent "$name"; then
                continue
            fi

            value=$(copies "$name")

            case "$name" in
                vlai) value=0 ;;
                *)    [ "$value" -gt 0 ] || value=1 ;;
            esac

            eval "PLC_COPIES_$(upper "$name")=\$value"
            set_env "PLC_COPIES_$(upper "$name")" "$value"
        done
    else
        for name in $INSPECTORS; do
            if absent "$name"; then
                continue
            fi

            value=$(copies "$name")
            default=y
            [ "$value" -gt 0 ] || default=n

            case "$name" in
                auth)
                    # The panel login needs it.
                    [ "$value" -gt 0 ] || value=1
                    ;;
                vlai)
                    if yes_no "Inspector vlai, the text classifier: 4 GB more memory and a model download?" "$default"; then
                        [ "$value" -gt 0 ] || value=1
                    else
                        value=0
                    fi
                    ;;
                *)
                    if yes_no "Inspector $name?" "$default"; then
                        [ "$value" -gt 0 ] || value=1
                    else
                        value=0
                    fi
                    ;;
            esac

            eval "PLC_COPIES_$(upper "$name")=\$value"
            set_env "PLC_COPIES_$(upper "$name")" "$value"
        done
    fi

    # Memory, copies and processes: the standard values suit most machines.
    standard=y
    [ "$(effective PLC_NGINX_WORKERS auto)" = auto ] || standard=n
    [ "$(effective PLC_REDIS_EXCHANGE_MB "$exchange")" = "$exchange" ] || standard=n
    [ "$(effective PLC_REDIS_INTERNAL_MB "$internal")" = "$internal" ] || standard=n

    for name in $INSPECTORS; do
        [ "$(copies "$name")" -le 1 ] || standard=n
    done

    if [ "$setup" = keep ]; then
        quiet PLC_NGINX_WORKERS is_workers auto
        quiet PLC_REDIS_EXCHANGE_MB is_mb "$exchange"
        quiet PLC_REDIS_INTERNAL_MB is_mb "$internal"
    elif yes_no "Standard memory, copies and processes?" "$standard"; then
        PLC_NGINX_WORKERS=auto
        PLC_REDIS_EXCHANGE_MB=$exchange
        PLC_REDIS_INTERNAL_MB=$internal
        set_env PLC_NGINX_WORKERS auto
        set_env PLC_REDIS_EXCHANGE_MB "$exchange"
        set_env PLC_REDIS_INTERNAL_MB "$internal"

        for name in $INSPECTORS; do
            [ "$(copies "$name")" -gt 1 ] || continue
            eval "PLC_COPIES_$(upper "$name")=1"
            set_env "PLC_COPIES_$(upper "$name")" 1
        done
    else
        ask PLC_NGINX_WORKERS is_workers auto "nginx processes per node: auto means one per core"

        for name in $INSPECTORS; do
            [ "$(copies "$name")" -gt 0 ] || continue
            ask "PLC_COPIES_$(upper "$name")" is_count "$(copies "$name")" "Copies of the $name inspector"
        done

        ask PLC_REDIS_EXCHANGE_MB is_mb "$exchange" "Exchange Redis memory, MB: request objects waiting for a verdict"
        ask PLC_REDIS_INTERNAL_MB is_mb "$internal" "Internal Redis memory, MB: configuration and inspector state"
    fi
}

label() {
    case "$1" in
        PLC_NODE_ID)           echo "node name" ;;
        PLC_TRAFFIC_BIND)      echo "traffic addresses" ;;
        PLC_HTTP_PORT)         echo "HTTP port" ;;
        PLC_HTTPS_PORT)        echo "HTTPS port" ;;
        PLC_PANEL_BIND)        echo "panel address" ;;
        PLC_PANEL_PORT)        echo "panel port" ;;
        PLC_PANEL_LOGIN)       echo "panel login" ;;
        PLC_SUBNET)            echo "installation network" ;;
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
    node=$(node_place)
    balancer=$(balancer_place)

    printf '  traffic      %s, ports %s and %s\n' "$PLC_TRAFFIC_BIND" "$PLC_HTTP_PORT" "$PLC_HTTPS_PORT"

    if [ "${PLC_NODES:-1}" -gt 1 ]; then
        where="in a container"
        [ "$balancer" != host ] || where="on this machine"
        printf '  nodes        %s from %s, %s nginx processes each, haproxy %s in front\n' \
            "$PLC_NODES" "$PLC_NODE_ID" "$workers" "$where"

        if [ "$balancer" = host ] && ! host_balancer; then
            printf '               haproxy and its agent are installed on this machine now\n'
        elif [ "$balancer" = container ]; then
            printf '               %s\n' "$(host_why balancer)"
        fi
    else
        where="in a container"
        [ "$node" != host ] || where="nginx on this machine"
        printf '  node         %s, %s nginx processes, %s\n' "$PLC_NODE_ID" "$workers" "$where"

        if [ "$node" = host ] && ! host_node; then
            printf '               nginx %s from nginx.org, the module and the node agent are installed on this machine now\n' \
                "${NGINX_VERSION:-1.28.0}"
        elif [ "$node" = container ]; then
            printf '               %s\n' "$(host_why node)"
        fi

        case "$node:$PLC_TRAFFIC_BIND" in
            host:*,*)
                warn "nginx on this machine listens on every address: one traffic address, 0.0.0.0, or haproxy in front of several nodes"
                ;;
        esac
    fi

    printf '  panel        %s:%s, login %s\n' "$PLC_PANEL_BIND" "$PLC_PANEL_PORT" "${PLC_PANEL_LOGIN:-admin}"
    printf '  network      %s\n' "$PLC_SUBNET"
    if net_moves; then
        printf '               the network is rebuilt: every container restarts, data stays\n'
        guests=$(net_guests | awk '{ printf "%s%s", sep, $1; sep = ", " }')
        [ -z "$guests" ] || printf '               containers of other projects move along: %s\n' "$guests"
    fi

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

    network="${COMPOSE_PROJECT_NAME:-placitum}_default"
    guests=""

    # A rebuilt network takes every container out of the old one first; volumes stay. Docker removes a
    # network only when nothing is attached, so containers of other projects step out too.
    if net_moves; then
        guests=$(net_guests)

        printf '%s\n' "$guests" | while read -r name _; do
            [ -z "$name" ] || docker network disconnect -f "$network" "$name" >> "$log_file" 2>&1
        done

        quietly "containers out of the old network" compose waf.yml down --remove-orphans
    fi

    # shellcheck disable=SC2086
    quietly "postgres, clickhouse, redis, nats, minio" compose waf.yml up -d --wait $infra_services

    # Containers of other projects come back under their aliases before the nodes look for them.
    printf '%s\n' "$guests" | while read -r name aliases; do
        [ -n "$name" ] || continue
        set --

        for alias in $(printf '%s' "$aliases" | tr ',' ' '); do
            set -- "$@" --alias "$alias"
        done

        if docker network connect "$@" "$network" "$name" >> "$log_file" 2>&1; then
            printf '  %s is back in the network\n' "$name"
        else
            warn "$name did not join the new network: docker network connect $network $name"
        fi
    done
}

migrate() {
    say "database schema"

    if [ "$build" = yes ]; then
        quietly "controller build" compose waf.yml build controller
    fi

    quietly "PostgreSQL schema" compose waf.yml -f "$here/compose/oneoff.yml" run --rm --no-deps controller node src/migrate.ts
}

# container_hosts: hostnames of the containers of the installation, one per line.
container_hosts() {
    docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-placitum}" |
        xargs -r docker inspect -f '{{.Config.Hostname}}' 2>/dev/null | sort -u
}

gone=""

# forget_gone: members of what this run removed leave the controller fleet now instead of staying
# silent for a minute. A failure costs only that minute.
forget_gone() {
    [ -n "$gone" ] || return 0

    if left=$(compose waf.yml exec -T -e "FORGET=$gone" controller \
        node --input-type=module -e "$(cat "$here/bootstrap/forget.mjs")" 2>> "$log_file" < /dev/null); then
        [ "${left:-0}" -eq 0 ] || printf '  removed from the fleet: %s\n' "$(printf '%s' "$gone" | tr '\n' ' ' | sed 's/ *$//')"
    else
        warn "the controller did not forget the removed members; they leave the panel within a minute"
    fi
}

# balancer_host start|stop: haproxy and its agent as services of this machine, when it has them.
balancer_host() {
    host_balancer || return 0

    case "$1" in
        stop)
            if systemctl is-enabled --quiet placitum-haproxy 2>/dev/null ||
                systemctl is-active --quiet placitum-haproxy 2>/dev/null; then
                quietly "haproxy on this machine off" systemctl disable --now placitum-haproxy-agent placitum-haproxy
                # The agent reports under the name of this machine.
                gone="$gone
$(hostname)"
            fi
            ;;
        start)
            install -d -m 0755 /etc/placitum
            printf 'WAF_NATS_URL=nats://%s:4222\n' "$(net "$PLC_SUBNET" nats)" > /etc/placitum/haproxy-agent.env
            quietly "haproxy and its agent on this machine" sh -c \
                'systemctl enable placitum-haproxy placitum-haproxy-agent &&
                 systemctl start placitum-haproxy &&
                 systemctl restart placitum-haproxy-agent'
            ;;
    esac
}

# node_host start|stop: nginx with the module and the node agent as services of this machine. The
# agent reaches NATS, Redis and MinIO by their fixed addresses and reads the secrets of this
# installation; until the first generation nginx runs on a stub without traffic ports.
node_host() {
    case "$1" in
        stop)
            host_node || return 0

            if systemctl is-enabled --quiet placitum-node-agent 2>/dev/null ||
                systemctl is-active --quiet placitum-node-agent 2>/dev/null; then
                quietly "nginx and the node agent on this machine off" systemctl disable --now placitum-node-agent nginx
                # The agent reports under the name of this machine.
                gone="$gone
$(hostname)"
            fi
            ;;
        start)
            install -d -m 0755 /etc/placitum/node
            sed -e "s|/run/secrets/waf_node_key|$here/secrets/contour.key|" \
                -e "s|/run/secrets/waf_s3_creds|$here/secrets/s3.creds|" \
                -e "s|nats://nats:4222|nats://$(net "$PLC_SUBNET" nats):4222|" \
                -e "s|redis://redis-internal:6379|redis://$(net "$PLC_SUBNET" internal):6379|" \
                -e "s|redis://redis:6379|redis://$(net "$PLC_SUBNET" redis):6379|" \
                -e "s|http://minio:9000|http://$(net "$PLC_SUBNET" minio):9000|" \
                "$here/config/edge/agent.conf" > /etc/placitum/node/agent.conf
            chmod 0600 /etc/placitum/node/agent.conf

            {
                printf 'WAF_NODE_ID=%s\n' "$(node_name 1)"
                printf 'WAF_AGENT_CONFIG=/etc/placitum/node/agent.conf\n'
                printf 'WAF_NGINX_MANAGE=on\nWAF_AGENT_LOG=info\nWAF_NGINX_DEBUG=off\n'
                printf 'WAF_LOG_WRITER=%s\n' "$(node_name 1)"
            } > /etc/placitum/node-agent.env

            cp "$here/config/edge/node.conf" /etc/nginx/waf-node.conf
            rm -f /etc/nginx/conf.d/default.conf

            if [ ! -f /etc/nginx/nginx.conf.prev ] && ! grep -q ngx_http_waf_module /etc/nginx/nginx.conf 2>/dev/null; then
                cp /etc/placitum/nginx-bootstrap.conf /etc/nginx/nginx.conf
            fi

            quietly "nginx and the node agent on this machine" sh -c \
                'systemctl enable nginx placitum-node-agent &&
                 if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl start nginx; fi &&
                 systemctl restart placitum-node-agent'
            ;;
    esac
}

components() {
    say "components"

    hosts_before=$(container_hosts)
    node=$(node_place)
    balancer=$(balancer_place)

    # What the answers no longer run: vlai, the haproxy container, nodes beyond PLC_NODES, the node
    # container when nginx runs on this machine, and the services of this machine the answers do
    # not need. nginx or haproxy on this machine let the traffic ports go before the others take them.
    if [ "${PLC_COPIES_VLAI:-0}" -eq 0 ]; then
        compose waf.yml --profile vlai rm --stop --force inspector-vlai >> "$log_file" 2>&1 || true
    fi

    if [ "$balancer" != container ]; then
        compose waf.yml --profile nodes rm --stop --force balancer >> "$log_file" 2>&1 || true
    fi

    [ "$balancer" = host ] || balancer_host stop
    [ "$node" = host ] || node_host stop

    if [ "$node" = host ]; then
        compose waf.yml rm --stop --force edge >> "$log_file" 2>&1 || true
    fi

    docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-placitum}" \
        --filter label=placitum.install=node --format '{{.ID}} {{.Label "com.docker.compose.service"}}' |
    while read -r id service; do
        if [ "${service#edge-}" -gt "${PLC_NODES:-1}" ] 2>/dev/null; then
            docker rm -f "$id" >> "$log_file" 2>&1
        fi
    done

    case "$build" in
        yes)
            quietly "image build (up to half an hour on the first install)" compose waf.yml build
            ;;
        missing)
            # Only what the new answers turn on and this machine has no image for.
            new=$(images_missing | awk '{ printf "%s%s", sep, $1; sep = " " }')

            if [ -n "$new" ]; then
                # shellcheck disable=SC2086
                quietly "image build: $new" compose waf.yml build $new
            fi
            ;;
    esac

    # Services of this machine the answers need and it lacks yet: from the images on it.
    if [ "$node" = host ] && ! host_node; then
        quietly "nginx ${NGINX_VERSION:-1.28.0}, the module and the node agent on this machine" \
            sh "$here/image/host.sh" node
    fi

    if [ "$balancer" = host ] && ! host_balancer; then
        quietly "haproxy and its agent on this machine" sh "$here/image/host.sh" balancer
    fi

    quietly "start and health check" compose waf.yml up -d --wait --no-build

    # Removed nodes, copies and recreated containers under new hostnames: nothing reports for them any
    # more. A hostname that is back after the run, such as a recreated node, stays.
    kept=$(mktemp)
    container_hosts > "$kept"
    gone="$gone
$(printf '%s\n' "$hosts_before" | grep -vxF -f "$kept" || true)"
    rm -f "$kept"
    gone=$(printf '%s\n' "$gone" | awk 'NF && !seen[$0]++')

    forget_gone

    [ "$node" != host ] || node_host start
}

# panel_run <docker -e options>: bootstrap/panel.mjs with the API on 127.0.0.1. Inside the
# controller container, where the node container answers as edge; with the node on this machine, in
# the network of this machine, where its panel port and the API are, with the panel pools pointed at
# the fixed addresses of the controller and the login form.
panel_run() {
    if [ "$(node_place)" = host ]; then
        image=$(docker inspect -f '{{.Config.Image}}' "$(compose waf.yml ps -q controller)")
        edge=${PLC_PANEL_BIND:-127.0.0.1}
        [ "$edge" != 0.0.0.0 ] || edge=127.0.0.1

        docker run --rm -i --network host \
            -e "CONTROLLER_PORT=${PLC_CONTROLLER_PORT:-8081}" \
            -e "PANEL_EDGE=http://$edge:${PLC_PANEL_PORT:-8080}" \
            -e PANEL_RESOLVER=none \
            -e "PANEL_CONTROLLER_HOST=$(net "$PLC_SUBNET" controller)" \
            -e "PANEL_FORM_HOST=$(net "$PLC_SUBNET" auth)" \
            -e "PANEL_BIND=${PLC_PANEL_BIND:-127.0.0.1}" \
            -e "PANEL_PORT=${PLC_PANEL_PORT:-8080}" \
            "$@" "$image" node --input-type=module -e "$(cat "$here/bootstrap/panel.mjs")"
    else
        compose waf.yml exec -T "$@" controller node --input-type=module -e "$(cat "$here/bootstrap/panel.mjs")"
    fi
}

panel() {
    say "panel"

    started=$(date +%s)
    printf '  login gate, admin and publish to the node ... '
    printf '\n== %s panel\n' "$(date '+%F %T')" >> "$log_file"

    # shellcheck disable=SC1090
    if [ -f "$env_file" ]; then . "$env_file"; fi

    if ! result=$(printf '%s' "$panel_pass" |
        panel_run -e "PANEL_ADMIN=${1:-ensure}" -e "PANEL_ADMIN_NAME=${PLC_PANEL_LOGIN:-admin}" \
            -e "PANEL_COOKIE_SECURE=${PLC_COOKIE_SECURE:-off}" 2>> "$log_file"); then
        printf 'failed\n'
        log_tail
        die "panel setup failed, log: $log_file; controller directly: http://127.0.0.1:${PLC_CONTROLLER_PORT:-8081}"
    fi

    printf 'done, %s\n' "$(elapsed "$started")"

    case "$result" in
        created)
            printf '%s created with the entered password\n' "${PLC_PANEL_LOGIN:-admin}"
            ;;
        updated)
            printf '%s password changed\n' "${PLC_PANEL_LOGIN:-admin}"
            ;;
        kept)
            printf '%s exists, password unchanged (to change it: %s panel-password)\n' "${PLC_PANEL_LOGIN:-admin}" "$cli"
            ;;
        "generated "*)
            printf '\npanel login: %s / %s\n' "${PLC_PANEL_LOGIN:-admin}" "${result#generated }"
            printf 'the password is not stored anywhere: write it down or change it with %s panel-password\n' "$cli"
            ;;
        *)
            die "unexpected answer from bootstrap/panel.mjs: $result"
            ;;
    esac
}

# layout.mjs in the controller with the answers: inspectors, nginx processes, where the node runs,
# traffic and panel ports, nodes behind haproxy. The nodes take PROXY protocol only from haproxy:
# the address of its container, or the gateway of the installation network for haproxy on this
# machine. nginx on this machine resolves names with the nameservers of the machine.
layout_run() {
    nodes=""
    inspectors=""
    i=1

    while [ "$i" -le "${PLC_NODES:-1}" ]; do
        service=edge
        [ "$i" -eq 1 ] || service="edge-$(printf '%02d' "$i")"
        nodes="$nodes $service:$(node_name "$i"):$(net "$PLC_SUBNET" "node:$i")"
        i=$((i + 1))
    done

    for name in $INSPECTORS; do
        default=1
        [ "$name" != vlai ] || default=0
        eval "copies=\${PLC_COPIES_$(upper "$name"):-$default}"
        [ "$copies" -eq 0 ] || inspectors="$inspectors $name"
    done

    balancer=container
    trust=$(net "$PLC_SUBNET" balancer)

    if [ "$(balancer_place)" = host ]; then
        balancer=host
        trust=$(net "$PLC_SUBNET" gateway)
    fi

    node=$(node_place)
    resolver="127.0.0.11 valid=10s ipv6=off"
    [ "$node" != host ] || resolver=$(resolver_of)

    bind=""
    [ "${PLC_TRAFFIC_BIND:-0.0.0.0}" = 0.0.0.0 ] || bind=$(printf '%s' "$PLC_TRAFFIC_BIND" | tr ',' ' ')

    compose waf.yml exec -T \
        -e "LAYOUT_STEP=$1" \
        -e "LAYOUT_INSPECTORS=${inspectors# }" \
        -e "LAYOUT_WORKERS=${PLC_NGINX_WORKERS:-auto}" \
        -e "LAYOUT_NODES=${nodes# }" \
        -e "LAYOUT_NODE=$node" \
        -e "LAYOUT_RESOLVER=$resolver" \
        -e "LAYOUT_PANEL=${PLC_PANEL_BIND:-127.0.0.1} ${PLC_PANEL_PORT:-8080}" \
        -e "LAYOUT_BALANCER=$balancer" \
        -e "LAYOUT_TRUST=$trust" \
        -e "LAYOUT_BIND=$bind" \
        -e "LAYOUT_PORTS=${PLC_HTTP_PORT:-80} ${PLC_HTTPS_PORT:-443}" \
        controller node --input-type=module -e "$(cat "$here/bootstrap/layout.mjs")" < /dev/null
}

layout() {
    say "layout"

    started=$(date +%s)
    printf '  inspectors, nginx processes, node placement, ports, haproxy ... '
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
        node --input-type=module -e "$(cat "$here/bootstrap/publish.mjs")" 2>> "$log_file" < /dev/null); then
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
        "redis-cli --scan --pattern 'auth:*:panel/*' | xargs -r redis-cli del >/dev/null" < /dev/null &&
        printf 'panel login lockouts cleared\n'
}

health() {
    rows=$(compose waf.yml ps -a --format '{{.Service}} {{.State}} {{.Health}}')
    total=$(printf '%s\n' "$rows" | grep -c . || true)
    bad=$(printf '%s\n' "$rows" | awk 'NF && ($2 != "running" || ($3 != "" && $3 != "healthy"))')

    if [ -z "$bad" ]; then
        printf 'containers: %s, all running\n' "$total"
    else
        warn "containers with problems ($(printf '%s\n' "$bad" | grep -c .) of $total):"
        printf '%s\n' "$bad" | sed 's/^/     /' >&2
    fi

    if [ "$(balancer_place)" = host ] && host_balancer; then
        if systemctl is-active --quiet placitum-haproxy && systemctl is-active --quiet placitum-haproxy-agent; then
            printf 'haproxy on this machine: running\n'
        else
            warn "haproxy on this machine is not running: systemctl status placitum-haproxy placitum-haproxy-agent"
        fi
    fi

    if [ "$(node_place)" = host ] && host_node; then
        if systemctl is-active --quiet nginx && systemctl is-active --quiet placitum-node-agent; then
            printf 'nginx and the node agent on this machine: running\n'
        else
            warn "the node on this machine is not running: systemctl status nginx placitum-node-agent"
        fi
    fi
}

summary() {
    # shellcheck disable=SC1090
    . "$env_file"
    bind=${PLC_PANEL_BIND:-127.0.0.1}
    port=${PLC_PANEL_PORT:-8080}

    printf '\n'

    if [ "$bind" = 0.0.0.0 ]; then
        machine_addrs | while read -r addr _; do
            printf 'panel:   http://%s:%s\n' "$addr" "$port"
        done
    else
        printf 'panel:   http://%s:%s\n' "$bind" "$port"
    fi

    printf 'login:   %s, change the password with %s panel-password\n' "${PLC_PANEL_LOGIN:-admin}" "$cli"
    printf 'API:     http://127.0.0.1:%s, no login, this machine only (from elsewhere use ssh -L)\n' \
        "${PLC_CONTROLLER_PORT:-8081}"
    printf 'traffic: %s, ports %s and %s\n' "${PLC_TRAFFIC_BIND:-0.0.0.0}" "${PLC_HTTP_PORT:-80}" "${PLC_HTTPS_PORT:-443}"

    if [ "$(node_place)" = host ] && [ -n "${PLC_SUBNET:-}" ]; then
        printf 'node:    nginx on this machine; containers by address: controller %s, login form %s, captcha form %s\n' \
            "$(net "$PLC_SUBNET" controller)" "$(net "$PLC_SUBNET" auth)" "$(net "$PLC_SUBNET" captcha)"
    fi

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
    # The layout goes before the panel: the panel step publishes the first generation, which has to
    # listen on the ports of this run already.
    layout
    panel

    # haproxy on this machine starts once the controller holds its configuration for these nodes.
    if [ "$(balancer_place)" = host ]; then
        balancer_host start
    fi

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
        # Images are built only for what the new answers turn on.
        [ "$build" = no ] || build=missing
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
        [ -f "$env_file" ] || die "$env_file not found: install first ($cli install)"
        # shellcheck disable=SC1090
        . "$env_file"
        say "status"
        compose waf.yml ps
        printf '\n'
        health
        summary
        ;;
    down)
        say "stopping"
        compose waf.yml down
        balancer_host stop
        node_host stop
        ;;
    help|-h|--help)
        sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "unknown command: $cmd (see $cli help)"
        ;;
esac
