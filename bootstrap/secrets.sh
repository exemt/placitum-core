#!/bin/sh
# Секреты установки: пара ключа контура и реквизиты архива.
#
#     sh bootstrap/secrets.sh [каталог]      завести недостающее
#     sh bootstrap/secrets.sh --fingerprint  напечатать отпечаток и выйти
#     sh bootstrap/secrets.sh --force        перевыпустить ключ контура
#
# Идемпотентно: существующие файлы не трогаются. Ключ контура -- RSA-4096,
# приватный в PKCS#8 PEM, публичный в SPKI PEM; отпечаток -- sha256 по DER
# публичного ключа, тот же, что панель сверяет в браузере.
#
# ВАЖНО: перевыпуск ключа (--force) обнуляет доверие контура -- сертификаты,
# зашифрованные прежним ключом, перестанут расшифровываться.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dir="$here/../secrets"
force=no
only_fp=no

for arg in "$@"; do
    case "$arg" in
        --force)       force=yes ;;
        --fingerprint) only_fp=yes ;;
        -*)            printf 'неизвестный ключ: %s\n' "$arg" >&2; exit 2 ;;
        *)             dir=$arg ;;
    esac
done

key="$dir/contour.key"
pub="$dir/contour.pub"
creds="$dir/s3.creds"

if ! command -v openssl >/dev/null 2>&1; then
    printf 'нужен openssl: ключ контура выпускается им\n' >&2
    exit 1
fi

fingerprint() {
    hex=$(openssl pkey -pubin -in "$pub" -outform DER 2>/dev/null |
          openssl dgst -sha256 | sed 's/.*= *//')
    printf 'sha256:%s\n' "$hex"
}

if [ "$only_fp" = yes ]; then
    [ -f "$pub" ] || { printf 'нет %s\n' "$pub" >&2; exit 1; }
    fingerprint
    exit 0
fi

mkdir -p "$dir"

if [ -f "$key" ] && [ "$force" = no ]; then
    printf 'ключ контура на месте: %s\n' "$key"
else
    if [ -f "$key" ]; then
        printf 'перевыпуск ключа контура: прежние сертификаты станут нечитаемыми\n' >&2
    fi

    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$key" 2>/dev/null
    openssl pkey -in "$key" -pubout -out "$pub" 2>/dev/null
    chmod 600 "$key"
    printf 'ключ контура выпущен: %s\n' "$key"
fi

# Реквизиты архива в формате AWS-профиля: их читают агент ноды и поиск
# (WAF_STORE_S3_CREDENTIALS_FILE). По умолчанию -- те же, с которыми поднят
# локальный MinIO; для внешнего S3 файл правится руками.
if [ -f "$creds" ]; then
    printf 'реквизиты архива на месте: %s\n' "$creds"
else
    access=${MINIO_ROOT_USER:-waf}
    secret=${MINIO_ROOT_PASSWORD:-wafwafwaf}

    cat > "$creds" <<EOF
[default]
aws_access_key_id=$access
aws_secret_access_key=$secret
EOF
    chmod 600 "$creds"
    printf 'реквизиты архива заведены: %s\n' "$creds"
fi

printf 'отпечаток ключа: %s\n' "$(fingerprint)"
