#!/bin/sh
# Waits until the processor is below COOL_BELOW degrees (70), at most COOL_MAX seconds (600): a
# pause between the image builds of a small machine that overheats.
#
#     BUILD_ONE_BY_ONE=1 BUILD_PAUSE="sh image/cool.sh" sh image/build.sh
#
# Reads the package temperature of k10temp (AMD) or coretemp (Intel) from hwmon; a machine without
# either is not waited for.

limit=${COOL_BELOW:-70}
max=${COOL_MAX:-600}
sensor=""

for h in /sys/class/hwmon/hwmon*; do
    case "$(cat "$h/name" 2>/dev/null)" in
        k10temp|coretemp) [ -f "$h/temp1_input" ] && sensor="$h/temp1_input" ;;
    esac
done

[ -n "$sensor" ] || exit 0

waited=0

while :; do
    t=$(( $(cat "$sensor") / 1000 ))
    [ "$t" -ge "$limit" ] || break
    [ "$waited" -lt "$max" ] || break
    [ "$waited" -gt 0 ] || printf 'cooling: %s C, waiting for %s C\n' "$t" "$limit"
    sleep 5
    waited=$((waited + 5))
done

printf 'processor %s C after %ss\n' "$(( $(cat "$sensor") / 1000 ))" "$waited"
