#!/bin/sh
# Services of this machine that stand in front of the containers, from the images on it: nginx of
# the module's version with the module and the node agent for a single node, haproxy and its agent
# for several nodes. Runs as root on Debian or Ubuntu with systemd. The machine image build runs it,
# and install.sh runs it when it runs as root and the machine lacks the services.
#
#     sh image/host.sh node        nginx from nginx.org, the module, the node agent, deny pages
#     sh image/host.sh balancer    haproxy from the distribution and its agent
#     sh image/host.sh all         both
#
# NGINX_VERSION: the version the module is built against, by default from .env or .env.example
# next to install.sh. IMAGE_EDGE and IMAGE_BALANCER: the images to take the files from
# (placitum-edge and placitum/agents-haproxy).

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core=$(dirname "$here")
what=${1:-all}

IMAGE_EDGE=${IMAGE_EDGE:-placitum-edge}
IMAGE_BALANCER=${IMAGE_BALANCER:-placitum/agents-haproxy}

die() { printf '!! %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

case "$what" in
    node|balancer|all) ;;
    *) die "usage: host.sh node|balancer|all" ;;
esac

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -d /run/systemd/system ] || die "systemd is required"
command -v apt-get >/dev/null 2>&1 || die "apt-get not found: Debian or Ubuntu is required"
command -v docker >/dev/null 2>&1 || die "docker not found: the files come out of the images"

# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "${PRETTY_NAME:-unknown system}: Debian or Ubuntu is required" ;;
esac

export DEBIAN_FRONTEND=noninteractive

version_of() {
    for file in "$core/.env" "$core/.env.example"; do
        if [ -f "$file" ]; then
            value=$(sed -n 's/^NGINX_VERSION=//p' "$file" | tail -n 1)
            [ -z "$value" ] || { printf '%s' "$value"; return 0; }
        fi
    done

    printf '1.28.0'
}

NGINX_VERSION=${NGINX_VERSION:-$(version_of)}

# extract <image> <path in the image> <path on the machine>
extract() {
    id=$(docker create "$1") || die "no image $1 on this machine"
    docker cp "$id:$2" "$3.new" >/dev/null || { docker rm "$id" >/dev/null; die "no $2 in $1"; }
    docker rm "$id" >/dev/null
    rm -rf "$3"
    mv "$3.new" "$3"
}

node() {
    say "== node on this machine: nginx $NGINX_VERSION, the module, the agent"

    if command -v nginx >/dev/null 2>&1; then
        have=$(nginx -v 2>&1 | sed -n 's|^nginx version: nginx/||p')

        [ "$have" = "$NGINX_VERSION" ] ||
            die "nginx $have is already on this machine and the module is built for $NGINX_VERSION: remove it, or keep the node in a container"
        say "nginx $have is on this machine"
    else
        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL https://nginx.org/keys/nginx_signing.key -o /etc/apt/keyrings/placitum-nginx.asc ||
            die "nginx.org signing key: download failed"

        printf '# Placitum (image/host.sh): nginx of the version the module is built against.\ndeb [signed-by=/etc/apt/keyrings/placitum-nginx.asc] https://nginx.org/packages/%s %s nginx\n' \
            "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/placitum-nginx.list

        apt-get update -q
        apt-get install -y -q --no-install-recommends "nginx=$NGINX_VERSION-1~$VERSION_CODENAME" ||
            die "nginx $NGINX_VERSION for $ID $VERSION_CODENAME: not installed"
        # The module refuses another version: no upgrades behind its back.
        apt-mark hold nginx >/dev/null
        say "nginx $NGINX_VERSION installed from nginx.org and held"
    fi

    # install.sh turns nginx on for a single node; until then it stays off.
    systemctl disable --now nginx >/dev/null 2>&1 || true

    install -d -m 0755 /usr/lib/nginx/modules /usr/share/waf
    extract "$IMAGE_EDGE" /etc/nginx/modules/ngx_http_waf_module.so /usr/lib/nginx/modules/ngx_http_waf_module.so
    extract "$IMAGE_EDGE" /usr/local/bin/waf-agent /usr/local/bin/waf-agent
    extract "$IMAGE_EDGE" /usr/share/waf/pages /usr/share/waf/pages
    chmod 0644 /usr/lib/nginx/modules/ngx_http_waf_module.so
    chmod 0755 /usr/local/bin/waf-agent

    # The module has to load into this nginx: a version mismatch shows here, not at the first generation.
    probe=$(mktemp)
    printf 'load_module /usr/lib/nginx/modules/ngx_http_waf_module.so;\nevents {}\n' > "$probe"
    nginx -t -q -c "$probe" 2>/dev/null || { rm -f "$probe"; die "the module does not load into nginx $NGINX_VERSION: nginx -t -c $probe"; }
    rm -f "$probe"

    install -d -m 0755 /etc/placitum
    install -m 0644 "$here/node/nginx-bootstrap.conf" /etc/placitum/nginx-bootstrap.conf
    install -m 0644 "$here/node/placitum-node-agent.service" /etc/systemd/system/placitum-node-agent.service
    systemctl daemon-reload
    say "node agent: /usr/local/bin/waf-agent, service placitum-node-agent (off until install.sh needs it)"
}

balancer() {
    say "== haproxy on this machine and its agent"

    if command -v haproxy >/dev/null 2>&1; then
        say "haproxy $(haproxy -v 2>/dev/null | sed -n 's/^HA-Proxy version \([^ ]*\).*/\1/p; s/^HAProxy version \([^ ]*\).*/\1/p' | head -n 1) is on this machine"
    else
        apt-get update -q
        apt-get install -y -q --no-install-recommends haproxy || die "haproxy: not installed"
    fi

    # haproxy of the distribution stays off: install.sh runs its own service for several nodes.
    systemctl disable --now haproxy >/dev/null 2>&1 || true

    extract "$IMAGE_BALANCER" /usr/local/bin/waf-haproxy-agent /usr/local/bin/waf-haproxy-agent
    chmod 0755 /usr/local/bin/waf-haproxy-agent

    install -d -m 0755 /etc/placitum
    install -m 0644 "$here/balancer/haproxy-bootstrap.cfg" /etc/placitum/haproxy-bootstrap.cfg
    install -m 0644 "$here/balancer/placitum-haproxy.service" \
        "$here/balancer/placitum-haproxy-agent.service" /etc/systemd/system/
    systemctl daemon-reload
    say "haproxy agent: /usr/local/bin/waf-haproxy-agent, services placitum-haproxy and placitum-haproxy-agent (off until install.sh needs them)"
}

case "$what" in
    node)     node ;;
    balancer) balancer ;;
    all)      node; balancer ;;
esac
