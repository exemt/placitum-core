#!/bin/sh
#
# Потоки JetStream, которые должны существовать до первой публикации.
# nats-box гоняет это при старте и остаётся жить для exec.
#
#     docker compose exec -T nats-box sh /t/streams/streams.sh
#

set -u

NATS=${NATS_URL:-nats://nats:4222}

say() { printf '%s\n' "$*"; }

nats_cmd() {
    nats --server "$NATS" "$@"
}

# Локальный JetStream -- 1GB на всё. 256MB на сутки аудита, discard old:
# лучше потерять старые события, чем упереться в max_file_store.
add_audit() {
    if nats_cmd stream info WAF_AUDIT >/dev/null 2>&1; then
        say "поток WAF_AUDIT уже есть"
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
        say "поток WAF_AUDIT создан"
        return 0
    fi

    say "не удалось создать поток WAF_AUDIT"
    return 1
}

# Логи процессов ноды. Меньше аудита: строка лога дешевле записи запроса, а
# буфер здесь нужен только на время, пока логгер не читает, поэтому и
# потолок вдвое меньше.
add_log() {
    if nats_cmd stream info WAF_LOG >/dev/null 2>&1; then
        say "поток WAF_LOG уже есть"
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
        say "поток WAF_LOG создан"
        return 0
    fi

    say "не удалось создать поток WAF_LOG"
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

say "NATS недоступен: $NATS"
exit 1
