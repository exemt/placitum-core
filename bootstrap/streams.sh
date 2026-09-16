#!/bin/sh
# JetStream streams that must exist before the first publish; nats-box runs this on start.
#
#     docker compose exec -T nats-box sh /etc/waf/streams.sh

set -u

NATS=${NATS_URL:-nats://nats:4222}

say() { printf '%s\n' "$*"; }

nats_cmd() {
    nats --server "$NATS" "$@"
}

add_audit() {
    if nats_cmd stream info WAF_AUDIT >/dev/null 2>&1; then
        say "stream WAF_AUDIT exists"
        return 0
    fi

    if nats_cmd stream add WAF_AUDIT \
           --subjects 'waf.audit.>' \
           --storage file \
           --retention limits \
           --max-age 24h \
           --max-bytes 256MB \
           --discard old \
           --dupe-window 2m \
           --defaults >/dev/null 2>&1
    then
        say "stream WAF_AUDIT created"
        return 0
    fi

    say "failed to create stream WAF_AUDIT"
    return 1
}

add_log() {
    if nats_cmd stream info WAF_LOG >/dev/null 2>&1; then
        say "stream WAF_LOG exists"
        return 0
    fi

    if nats_cmd stream add WAF_LOG \
           --subjects 'waf.log.>' \
           --storage file \
           --retention limits \
           --max-age 24h \
           --max-bytes 128MB \
           --discard old \
           --defaults >/dev/null 2>&1
    then
        say "stream WAF_LOG created"
        return 0
    fi

    say "failed to create stream WAF_LOG"
    return 1
}

tries=0
while [ "$tries" -lt 15 ]; do
    if nats_cmd account info >/dev/null 2>&1; then
        add_audit
        add_log
        exit $?
    fi

    tries=$((tries + 1))
    sleep 1
done

say "NATS unavailable: $NATS"
exit 1
