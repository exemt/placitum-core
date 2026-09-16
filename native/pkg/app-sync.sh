#!/bin/sh
# Gives a process its own copy of /usr/share/placitum/<component>, the way an image layer does.
# The copy is recreated when the .build stamp changes; the process data next to it stays.
#
#     app-sync <component> <process>        app-sync modsec modsec-1

set -eu

src=/usr/share/placitum/$1
dst=/var/lib/placitum/$2/app

[ -d "$src" ] || { echo "app-sync: $src not found" >&2; exit 1; }

if [ -f "$dst/.build" ] && cmp -s "$src/.build" "$dst/.build"; then
    exit 0
fi

rm -rf "$dst.new"
cp -a "$src" "$dst.new"
chown -R placitum:placitum "$dst.new"
rm -rf "$dst"
mv "$dst.new" "$dst"
