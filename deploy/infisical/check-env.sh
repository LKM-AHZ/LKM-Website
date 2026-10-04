#!/bin/sh
# Fail before changing Compose/Kubernetes when Infisical omitted a core secret.
set -eu

if [ "$#" -eq 0 ]; then
    echo "Usage: check-env.sh COMMAND [ARG ...]" >&2
    exit 2
fi

for key in POSTGRES_PASSWORD MINIO_ROOT_PASSWORD CLICKHOUSE_PASSWORD \
           PREFECT_DB_PASSWORD LKM_GRAFANA_ADMIN_PASSWORD \
           LKM_SIGNOZ_JWT_SECRET LKM_BOT_SHIP_ACCESS_TOKEN \
           LKM_AUTH_HTTP_TOKEN LKM_TOTP_ENCRYPTION_KEY \
           LKM_VERIFICATION_CODE_PEPPER; do
    value="$(printenv "$key" 2>/dev/null || true)"
    case "$value" in
        ""|change-me*|\<*)
            echo "Infisical is missing a real value for $key" >&2
            exit 1
            ;;
    esac
done

if [ "$LKM_GRAFANA_ADMIN_PASSWORD" = admin ]; then
    echo "Infisical still has Grafana's default admin password" >&2
    exit 1
fi

if [ "$LKM_TOTP_ENCRYPTION_KEY" = "$LKM_VERIFICATION_CODE_PEPPER" ]; then
    echo "TOTP key and verification pepper must differ" >&2
    exit 1
fi

# The whole-stack path fetches secrets once at deploy time. Avoid a second
# in-container fetch, which would introduce a separate source and boot failure.
export LKM_INFISICAL_ENABLED=false
exec "$@"
