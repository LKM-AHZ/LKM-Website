#!/bin/sh
# Start only Infisical and its dependencies before application secrets exist.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
bootstrap_file="${1:-$root/.env.infisical}"
if [ ! -f "$bootstrap_file" ]; then
    echo "Missing Infisical bootstrap file: $bootstrap_file" >&2
    exit 1
fi
bootstrap_file="$(cd "$(dirname "$bootstrap_file")" && pwd)/$(basename "$bootstrap_file")"

for key in INFISICAL_DB_PASSWORD INFISICAL_ENCRYPTION_KEY INFISICAL_AUTH_SECRET; do
    value="$(sed -n "s/^${key}=//p" "$bootstrap_file" | tail -1)"
    case "$value" in
        ""|change-me*|\<*)
            echo "Missing real Infisical bootstrap value: $key" >&2
            exit 1
            ;;
    esac
done

# Compose interpolates every service, including services not selected by `up`.
# These values are never used: this command starts only the Infisical service.
export POSTGRES_PASSWORD=bootstrap-only
export PREFECT_DB_PASSWORD=bootstrap-only
export MINIO_ROOT_PASSWORD=bootstrap-only
export LKM_AUTH_HTTP_TOKEN=bootstrap-only
export LKM_TOTP_ENCRYPTION_KEY=bootstrap-only
export LKM_VERIFICATION_CODE_PEPPER=bootstrap-only
export LKM_JWT_PRIVATE_KEY_FILE=/dev/null
export LKM_JWT_PUBLIC_KEY_FILE=/dev/null

cd "$root"
exec docker compose --env-file "$bootstrap_file" --profile infisical up -d infisical
