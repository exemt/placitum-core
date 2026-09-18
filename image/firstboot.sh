#!/bin/sh
# First boot of the image, on the console: a password for the placitum user, then
# ./install.sh install with its settings questions. The installation runs once;
# after it, sudo placitum reconfigure asks the settings again.
#
#     firstboot.sh           the first boot service runs this
#     firstboot.sh --issue   rewrite the console greeting from the current settings
#
# Without a console the answers come from /etc/placitum/answers.env, for example
# written by cloud-init: PLC_* settings from .env.example and PLC_PANEL_PASSWORD.
# The file is deleted after reading.

set -u

core=/opt/placitum
answers=/etc/placitum/answers.env
installed=/var/lib/placitum/installed

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

user_password() {
    printf 'Console and ssh login: user placitum, with sudo.\n'

    while :; do
        read_secret "Password for placitum: "
        first=$secret

        if [ "${#first}" -lt 8 ]; then
            printf 'at least 8 characters\n'
            continue
        fi

        read_secret "Again: "

        if [ "$first" = "$secret" ]; then
            printf 'placitum:%s\n' "$first" | chpasswd && break
        fi

        printf 'passwords do not match, try again\n'
    done
}

if [ "${1:-}" = --issue ]; then
    issue
    exit 0
fi

dmesg -n 1 2>/dev/null || true

# In a virtual machine the panel is useful only from the network.
PLC_PANEL_BIND=${PLC_PANEL_BIND:-0.0.0.0}
PLC_CLI="sudo placitum"
export PLC_PANEL_BIND PLC_CLI

console=yes

if [ -f "$answers" ]; then
    console=no
    set -a
    # shellcheck disable=SC1090
    . "$answers"
    set +a
    rm -f "$answers"

    "$core/install.sh" install --no-build --defaults
    rc=$?
else
    clear 2>/dev/null || true
    printf 'Placitum: first boot\n\n'
    printf 'The installation runs once, on this console. Enter takes the value in brackets.\n\n'

    user_password
    printf '\n'

    "$core/install.sh" install --no-build
    rc=$?
fi

if [ "$rc" -eq 0 ]; then
    mkdir -p "$(dirname "$installed")"
    touch "$installed"
else
    printf '\nThe installation failed, log: %s/install.log\n' "$core"
    printf 'Log in as placitum and run: sudo placitum install\n'
fi

issue

if [ "$console" = yes ]; then
    printf '\nPress Enter to continue '
    read -r _ || true
fi

exit 0
