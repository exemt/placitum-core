#!/bin/sh
# Свой каталог компонента у каждого процесса -- то, что в контейнере даёт слой
# образа. Инспекторы пишут в свои каталоги (профили, политика, состояние), поэтому
# копия у процесса своя, а после обновления пакета приходит заново: как
# контейнер, пересозданный из нового образа.
#
#     app-sync <компонент> <процесс>        app-sync modsec modsec-1
#
# Пакет кладёт каталог в /usr/share/placitum/<компонент> с меткой сборки .build,
# копия живёт в /var/lib/placitum/<процесс>/app. Метка разошлась -- копия
# пересоздаётся; данные процесса (data рядом с app) не трогаются.

set -eu

src=/usr/share/placitum/$1
dst=/var/lib/placitum/$2/app

[ -d "$src" ] || { echo "app-sync: нет $src" >&2; exit 1; }

if [ -f "$dst/.build" ] && cmp -s "$src/.build" "$dst/.build"; then
    exit 0
fi

rm -rf "$dst.new"
cp -a "$src" "$dst.new"
chown -R placitum:placitum "$dst.new"
rm -rf "$dst"
mv "$dst.new" "$dst"
