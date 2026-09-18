#!/bin/sh
# First boot of the image, on the console. The machine first: login and password, machine name,
# time zone, the network; then ./install.sh install with its own questions. The installation
# runs once; after it, sudo placitum reconfigure asks the installation settings again.
#
#     firstboot.sh           the first boot service runs this
#     firstboot.sh --issue   rewrite the console greeting from the current settings
#
# Without a console the answers come from /etc/placitum/answers.env, for example written by
# cloud-init: PLC_* settings from .env.example, PLC_PANEL_PASSWORD, and for the machine itself
# PLC_LOGIN (placitum), PLC_HOSTNAME (placitum) and PLC_TIMEZONE (UTC); the network stays on DHCP.
# The file is deleted after reading.

set -u

core=/opt/placitum
answers=/etc/placitum/answers.env
installed=/var/lib/placitum/installed
netplan=/etc/netplan/99-placitum.yaml

issue() {
    bind=127.0.0.1
    port=8081

    if [ -f "$core/.env" ]; then
        bind=$(sed -n 's/^PLC_PANEL_BIND=//p' "$core/.env")
        port=$(sed -n 's/^PLC_PANEL_PORT=//p' "$core/.env")
    fi

    [ "$bind" != 0.0.0.0 ] || bind='\4'

    # \4 is replaced with the address of the machine by the console itself: on a machine
    # without an address the line is empty, and that is the first thing to look at.
    address='\4'

    {
        printf 'Placitum\n\n'
        printf '  address:   %s\n' "$address"

        if [ -f "$installed" ]; then
            printf '  panel:     http://%s:%s\n' "$bind" "${port:-8081}"
            printf '  settings:  sudo placitum reconfigure\n'
            printf '  admin:     sudo placitum panel-password\n\n'
        else
            printf '  not installed: sudo placitum install\n\n'
        fi
    } > /etc/issue
}

read_secret() {
    printf '%s' "$1"
    stty -echo 2>/dev/null
    IFS= read -r secret || secret=""
    stty echo 2>/dev/null
    printf '\n'
}

# ---------- the machine ----------

# A login of our own: not a name the system already uses, apart from the shipped placitum.
is_login() {
    printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || return 1
    [ "$1" = placitum ] || ! getent passwd "$1" >/dev/null 2>&1
}

is_hostname() {
    printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
}

is_timezone() {
    case "$1" in
        UTC|*/*) [ -f "/usr/share/zoneinfo/$1" ] ;;
        *) return 1 ;;
    esac
}

is_ipv4() {
    printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' &&
        printf '%s' "$1" | awk -F. '{ for (i = 1; i <= 4; i++) if ($i > 255) exit 1 }'
}

is_cidr() {
    printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$' && is_ipv4 "${1%/*}"
}

is_cidr_or_dhcp() {
    [ "$1" = dhcp ] || is_cidr "$1"
}

# ask_text <variable> <check> <default> <question>: a question on the console until the answer
# passes the check; Enter takes the default.
ask_text() {
    while :; do
        printf '%s [%s]: ' "$4" "$3"
        IFS= read -r answer || answer=""
        [ -n "$answer" ] || answer=$3

        if "$2" "$answer"; then
            eval "$1=\$answer"
            return 0
        fi

        case "$2" in
            is_login)    printf 'lowercase latin letters, digits, - and _, up to 32, and not a name the system uses\n' ;;
            is_hostname) printf 'lowercase latin letters, digits and hyphens, up to 63\n' ;;
            is_timezone) printf 'a zone from /usr/share/zoneinfo, such as Europe/Berlin\n' ;;
            is_ipv4)     printf 'an IPv4 address\n' ;;
            *)           printf 'dhcp, or an address with a prefix length, such as 192.168.1.10/24\n' ;;
        esac
    done
}

# The password of the machine and of the panel: twice without echo, at least 8 characters; Enter
# generates one that the summary shows once.
ask_password() {
    while :; do
        read_secret "Password for $login, Enter generates one: "
        first=$secret

        if [ -z "$first" ]; then
            password=""
            return 0
        fi

        if [ "${#first}" -lt 8 ]; then
            printf 'at least 8 characters\n'
            continue
        fi

        read_secret "Again: "

        if [ "$first" = "$secret" ]; then
            password=$first
            return 0
        fi

        printf 'passwords do not match, try again\n'
    done
}

# make_user <login> <password>: the user of the machine with sudo and docker; the shipped
# placitum goes when another login is chosen.
make_user() {
    if ! getent passwd "$1" >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo,docker "$1"
    fi

    printf '%s:%s\n' "$1" "$2" | chpasswd

    if [ "$1" != placitum ] && getent passwd placitum >/dev/null 2>&1; then
        userdel -r placitum 2>/dev/null || true
    fi

    # The password is for ssh too. sshd takes the first value it reads, so this file goes before
    # the one cloud-init may write with a no.
    install -d -m 0755 /etc/ssh/sshd_config.d
    printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/10-placitum.conf
    systemctl reload ssh 2>/dev/null || true
}

set_hostname() {
    hostnamectl set-hostname "$1" 2>/dev/null || printf '%s\n' "$1" > /etc/hostname

    if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$1/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$1" >> /etc/hosts
    fi
}

set_timezone() {
    timedatectl set-timezone "$1" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$1" /etc/localtime
}

# Ethernet adapters of the machine: those with a device behind them, so without the loopback and
# the interfaces of Docker.
interfaces() {
    for dev in /sys/class/net/*; do
        name=$(basename "$dev")
        [ -e "$dev/device" ] || continue
        printf '%s\n' "$name"
    done
}

address_of() {
    ip -o -4 addr show dev "$1" 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }'
}

# The network of the machine: DHCP or a fixed address on every adapter. With DHCP everywhere the
# shipped configuration stays; a fixed address rewrites it with the adapters by name.
ask_network() {
    conf=$(mktemp)
    static=no
    dns=""

    printf 'network:\n  version: 2\n  ethernets:\n' > "$conf"

    for dev in $(interfaces); do
        carrier=$(cat "/sys/class/net/$dev/carrier" 2>/dev/null || echo 0)
        addr=$(address_of "$dev")
        link=""
        [ "$carrier" = 1 ] || link=", no link"
        printf 'Adapter %s: %s%s\n' "$dev" "${addr:-no address}" "$link"

        ask_text mode is_cidr_or_dhcp dhcp "Address of $dev: dhcp, or address/prefix"

        if [ "$mode" = dhcp ]; then
            printf '    %s:\n      dhcp4: true\n      optional: true\n' "$dev" >> "$conf"
            continue
        fi

        static=yes
        printf '    %s:\n      addresses: [%s]\n      optional: true\n' "$dev" "$mode" >> "$conf"

        gateway=""
        while :; do
            printf 'Gateway for %s, Enter for none: ' "$dev"
            IFS= read -r gateway || gateway=""
            [ -z "$gateway" ] && break
            is_ipv4 "$gateway" && break
            printf 'an IPv4 address, or nothing\n'
        done

        if [ -n "$gateway" ]; then
            printf '      routes:\n        - to: default\n          via: %s\n' "$gateway" >> "$conf"
        fi

        if [ -z "$dns" ]; then
            while :; do
                printf 'DNS servers, separated by spaces [%s]: ' "${gateway:-none}"
                IFS= read -r dns || dns=""
                [ -n "$dns" ] || dns=$gateway
                [ -z "$dns" ] && break
                ok=yes
                for server in $dns; do is_ipv4 "$server" || ok=no; done
                [ "$ok" = yes ] && break
                dns=""
                printf 'IPv4 addresses separated by spaces\n'
            done
        fi

        if [ -n "$dns" ]; then
            printf '      nameservers:\n        addresses: [%s]\n' "$(printf '%s' "$dns" | sed 's/ \{1,\}/, /g')" >> "$conf"
        fi
    done

    if [ "$static" = yes ]; then
        install -m 0600 "$conf" "$netplan"
        netplan apply 2>/dev/null
        sleep 3
    fi

    rm -f "$conf"
    printf '\n'
    ip -br -4 addr show 2>/dev/null | grep -Ev '^(lo|docker|br-|veth)' | sed 's/^/  /'
    printf '\n'
}

# The adapter of the default route faces outside; an address on any other adapter is internal.
# The panel is proposed on an internal address when there is one, on the machine's address
# otherwise.
panel_default() {
    outside=$(ip -o -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    inside=""

    for dev in $(interfaces); do
        [ "$dev" != "$outside" ] || continue
        inside=$(address_of "$dev")
        [ -z "$inside" ] || break
    done

    if [ -n "$inside" ]; then
        printf '%s' "$inside"
    elif [ -n "$outside" ] && [ -n "$(address_of "$outside")" ]; then
        address_of "$outside"
    else
        printf '0.0.0.0'
    fi
}

# ---------- the run ----------

if [ "${1:-}" = --issue ]; then
    issue
    exit 0
fi

dmesg -n 1 2>/dev/null || true

PLC_CLI="sudo placitum"
export PLC_CLI

console=yes
login=placitum
password=""
generated=no

if [ -f "$answers" ]; then
    console=no
    set -a
    # shellcheck disable=SC1090
    . "$answers"
    set +a
    rm -f "$answers"

    login=${PLC_LOGIN:-placitum}
    is_login "$login" || login=placitum
    is_hostname "${PLC_HOSTNAME:-}" && set_hostname "$PLC_HOSTNAME"
    is_timezone "${PLC_TIMEZONE:-}" && set_timezone "$PLC_TIMEZONE"

    # One password for the machine and the panel; without one the machine user stays locked
    # and the panel generates its own.
    if [ -n "${PLC_PANEL_PASSWORD:-}" ]; then
        make_user "$login" "$PLC_PANEL_PASSWORD"
    fi

    PLC_PANEL_LOGIN=${PLC_PANEL_LOGIN:-$login}
    PLC_PANEL_BIND=${PLC_PANEL_BIND:-$(panel_default)}
    export PLC_PANEL_LOGIN PLC_PANEL_BIND

    "$core/install.sh" install --no-build --defaults
    rc=$?
else
    clear 2>/dev/null || true
    printf 'Placitum: first boot\n\n'
    printf 'The installation runs once, on this console. Enter takes the value in brackets.\n\n'

    ask_text login is_login placitum "Login for this machine and the panel"
    ask_password

    if [ -z "$password" ]; then
        # Letters and digits that cannot be misread from the console: no 0 and O, no 1, l and I,
        # no 2 and Z.
        password=$(tr -dc 'a-hj-km-np-yA-HJ-NP-Y3-9' < /dev/urandom | head -c 16)
        generated=yes
    fi

    make_user "$login" "$password"

    ask_text host is_hostname placitum "Machine name"
    set_hostname "$host"

    ask_text zone is_timezone UTC "Time zone"
    set_timezone "$zone"

    printf '\n'
    ask_network

    PLC_PANEL_LOGIN=$login
    PLC_PANEL_PASSWORD=$password
    PLC_PANEL_BIND=$(panel_default)
    export PLC_PANEL_LOGIN PLC_PANEL_PASSWORD PLC_PANEL_BIND

    "$core/install.sh" install --no-build
    rc=$?
fi

if [ "$rc" -eq 0 ]; then
    mkdir -p "$(dirname "$installed")"
    touch "$installed"

    if [ "$generated" = yes ]; then
        printf '\nlogin: %s, password: %s\n' "$login" "$password"
        printf 'the password is for the console, ssh and the panel; it is not stored anywhere else: write it down\n'
    fi
else
    printf '\nThe installation failed, log: %s/install.log\n' "$core"
    printf 'Log in as %s and run: sudo placitum install\n' "$login"
fi

issue

if [ "$console" = yes ]; then
    printf '\nPress Enter to continue '
    read -r _ || true
fi

exit 0
