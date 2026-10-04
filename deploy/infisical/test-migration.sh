#!/bin/sh
# Synthetic, offline check for Infisical-injected values and K8s Secret output.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
printf 'POSTGRES_PASSWORD=stale-local\n' > "$tmp/local.env"
printf 'public-test-key\n' > "$tmp/public.pem"
printf 'private-test-key\n' > "$tmp/private.pem"

env \
    POSTGRES_PASSWORD=from-infisical \
    MINIO_ROOT_PASSWORD=minio-test \
    CLICKHOUSE_PASSWORD=clickhouse-test \
    PREFECT_DB_PASSWORD=prefect-test \
    LKM_GRAFANA_ADMIN_PASSWORD=grafana-test \
    LKM_SIGNOZ_JWT_SECRET=signoz-test \
    LKM_BOT_SHIP_ACCESS_TOKEN=shipyard-test \
    LKM_PREFECT_API_TOKEN=prefect-api-test \
    LKM_SEARCH_MEILI_API_KEY=meili-test \
    LKM_AUTH_HTTP_TOKEN=token-test \
    LKM_TOTP_ENCRYPTION_KEY=totp-test \
    LKM_VERIFICATION_CODE_PEPPER=pepper-test \
    JWT_PUBLIC_KEY_PATH="$tmp/public.pem" \
    JWT_PRIVATE_KEY_PATH="$tmp/private.pem" \
    ENV_FILE="$tmp/local.env" \
    sh "$root/deploy/infisical/check-env.sh" \
    sh "$root/deploy/k8s/gen-secret.sh" > "$tmp/secret.yaml"

grep -Fq 'POSTGRES_PASSWORD: "from-infisical"' "$tmp/secret.yaml"
grep -Fq 'LKM_S3_SECRET_KEY: "minio-test"' "$tmp/secret.yaml"
grep -Fq 'LKM_GRAFANA_ADMIN_PASSWORD: "grafana-test"' "$tmp/secret.yaml"
grep -Fq 'LKM_PREFECT_API_TOKEN: "prefect-api-test"' "$tmp/secret.yaml"
grep -Fq 'LKM_SEARCH_MEILI_API_KEY: "meili-test"' "$tmp/secret.yaml"
if grep -Fq 'INFISICAL_ENCRYPTION_KEY:' "$tmp/secret.yaml"; then
    echo 'Infisical root key leaked into application Secret' >&2
    exit 1
fi
if env POSTGRES_PASSWORD=change-me \
       MINIO_ROOT_PASSWORD=minio-test CLICKHOUSE_PASSWORD=clickhouse-test \
       PREFECT_DB_PASSWORD=prefect-test \
       LKM_GRAFANA_ADMIN_PASSWORD=grafana-test \
       LKM_SIGNOZ_JWT_SECRET=signoz-test \
       LKM_BOT_SHIP_ACCESS_TOKEN=shipyard-test LKM_AUTH_HTTP_TOKEN=token-test \
       LKM_TOTP_ENCRYPTION_KEY=totp-test LKM_VERIFICATION_CODE_PEPPER=pepper-test \
       sh "$root/deploy/infisical/check-env.sh" true 2>/dev/null; then
    echo 'placeholder was accepted' >&2
    exit 1
fi

echo 'Infisical migration checks passed'
