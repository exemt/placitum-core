#!/bin/sh
# Installation key pair and its panel pin, archive credentials and signing keys.
# Existing files are kept.
#
#     sh bootstrap/secrets.sh [dir]          create what is missing
#     sh bootstrap/secrets.sh --fingerprint  print the key fingerprint
#     sh bootstrap/secrets.sh --force        reissue the installation key
#
# Reissuing the key breaks trust: certificates encrypted with the old key can no longer be decrypted.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dir="$here/../secrets"
force=no
only_fp=no

for arg in "$@"; do
    case "$arg" in
        --force)       force=yes ;;
        --fingerprint) only_fp=yes ;;
        -*)            printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
        *)             dir=$arg ;;
    esac
done

key="$dir/contour.key"
pub="$dir/contour.pub"
creds="$dir/s3.creds"

if ! command -v openssl >/dev/null 2>&1; then
    printf 'openssl required: it creates the installation key\n' >&2
    exit 1
fi

fingerprint() {
    hex=$(openssl pkey -pubin -in "$pub" -outform DER 2>/dev/null |
          openssl dgst -sha256 | sed 's/.*= *//')
    printf 'sha256:%s\n' "$hex"
}

if [ "$only_fp" = yes ]; then
    [ -f "$pub" ] || { printf 'not found: %s\n' "$pub" >&2; exit 1; }
    fingerprint
    exit 0
fi

mkdir -p "$dir"

if [ -f "$key" ] && [ "$force" = no ]; then
    printf 'installation key exists: %s\n' "$key"
else
    if [ -f "$key" ]; then
        printf 'reissuing the installation key: existing certificates become unreadable\n' >&2
    fi

    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$key" 2>/dev/null
    openssl pkey -in "$key" -pubout -out "$pub" 2>/dev/null
    printf 'installation key created: %s\n' "$key"
fi

# Archive credentials in AWS profile format; edit the file by hand for an external S3.
if [ -f "$creds" ]; then
    printf 'archive credentials exist: %s\n' "$creds"
else
    access=${MINIO_ROOT_USER:-waf}
    secret=${MINIO_ROOT_PASSWORD:-wafwafwaf}

    cat > "$creds" <<EOF
[default]
aws_access_key_id=$access
aws_secret_access_key=$secret
EOF
    printf 'archive credentials created: %s\n' "$creds"
fi

# One signing key per subsystem; reissuing one logs out only the sessions it signed.
for name in auth.hmac auth-app.hmac captcha.hmac cookie.hmac; do
    hmac="$dir/$name"

    if [ -f "$hmac" ]; then
        printf 'signing key exists: %s\n' "$hmac"
        continue
    fi

    openssl rand -hex 32 > "$hmac"
    printf 'signing key created: %s\n' "$hmac"
done

# Compose mounts secret files as is, and services run as their own users:
# the files are 0644 and the 0700 directory keeps everyone else out.
chmod 700 "$dir"

for f in "$key" "$pub" "$creds" "$dir"/*.hmac; do
    if [ -f "$f" ]; then
        chmod 644 "$f"
    fi
done

# The panel checks the key the API returns against this pin; compose mounts it read-only.
printf '{ "fingerprint": "%s" }\n' "$(fingerprint)" > "$dir/contour-pin.json"
chmod 644 "$dir/contour-pin.json"

printf 'key fingerprint: %s\n' "$(fingerprint)"
