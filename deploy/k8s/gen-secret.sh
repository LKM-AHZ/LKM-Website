#!/bin/sh
# 从根仓库 .env 生成 k8s Secret（不落盘、不进 git）。
#
# 为什么用脚本而不是提交一份 Secret YAML：Secret 的键集与 compose 的变量名高度重叠但
# 并非一一对应（如 LKM_S3_SECRET_KEY 只是 MINIO_ROOT_PASSWORD 的别名），提交一份 YAML
# 会随之腐烂成「第二真相源」。脚本从 .env 派生，.env 仍是唯一来源。
#
# 用法：
#   sh deploy/k8s/gen-secret.sh                     # 输出到 stdout，人工管道 apply
#   sh deploy/k8s/gen-secret.sh | kubectl apply -f -
#   NAMESPACE=lkm sh deploy/k8s/gen-secret.sh | kubectl -n lkm apply -f -
#
# 前置：根目录 .env 需已按 .env.example 配齐（三个主密钥、POSTGRES_PASSWORD、
# MINIO_ROOT_PASSWORD、LKM_AUTH_HTTP_TOKEN 必填）。
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
NS="${NAMESPACE:-lkm}"

if [ ! -f "$ENV_FILE" ]; then
    echo "找不到 $ENV_FILE —— 请先从 .env.example 复制并填值" >&2
    exit 1
fi

# 只读取需要的键；不 source 整个 .env（避免 .env 里任意命令被执行）。
get() {
    # get KEY [default]；取 .env 中最后一次赋值，去掉行内注释与首尾空白/引号
    key="$1"
    def="${2-}"
    line="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$ENV_FILE" | tail -1)"
    line="$(printf '%s' "$line" | sed 's/[[:space:]]*#.*$//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$line" in
        \"*\") line="$(printf '%s' "$line" | sed 's/^"//; s/"$//')" ;;
        \'*\') line="$(printf '%s' "$line" | sed "s/^'//; s/'\$//")" ;;
    esac
    if [ -z "$line" ]; then printf '%s' "$def"; else printf '%s' "$line"; fi
}

require() {
    if [ -z "$(get "$1")" ]; then
        echo "必填项 $1 在 $ENV_FILE 中缺失或为空" >&2
        exit 1
    fi
}

for k in LKM_JWT_SECRET LKM_TOTP_ENCRYPTION_KEY LKM_VERIFICATION_CODE_PEPPER \
         LKM_AUTH_HTTP_TOKEN POSTGRES_PASSWORD MINIO_ROOT_PASSWORD; do
    require "$k"
done

PG_USER="$(get POSTGRES_USER lkm)"
MINIO_USER="$(get MINIO_ROOT_USER lkmadmin)"

# Secret 的键集 = 应用/中间件消费的全部敏感项。POSTGRES_PASSWORD 与 LKM_DB_PASSWORD 等
# 同值多键是刻意的：让各 Pod 直接 envFrom 这一张表即可，不必在 Deployment 里到处写
# secretKeyRef 做逐键映射（少一层易漏的间接）。
umask 077
cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: lkm-secrets
  namespace: $NS
  labels:
    app.kubernetes.io/part-of: lkm
type: Opaque
stringData:
  LKM_JWT_SECRET: "$(get LKM_JWT_SECRET)"
  LKM_TOTP_ENCRYPTION_KEY: "$(get LKM_TOTP_ENCRYPTION_KEY)"
  LKM_VERIFICATION_CODE_PEPPER: "$(get LKM_VERIFICATION_CODE_PEPPER)"
  LKM_AUTH_HTTP_TOKEN: "$(get LKM_AUTH_HTTP_TOKEN)"
  LKM_GITHUB_CLIENT_SECRET: "$(get LKM_GITHUB_CLIENT_SECRET)"
  POSTGRES_USER: "$PG_USER"
  POSTGRES_PASSWORD: "$(get POSTGRES_PASSWORD)"
  LKM_DB_PASSWORD: "$(get POSTGRES_PASSWORD)"
  LKM_AUTH_DB_PASSWORD: "$(get POSTGRES_PASSWORD)"
  MINIO_ROOT_USER: "$MINIO_USER"
  MINIO_ROOT_PASSWORD: "$(get MINIO_ROOT_PASSWORD)"
  LKM_S3_ACCESS_KEY: "$MINIO_USER"
  LKM_S3_SECRET_KEY: "$(get MINIO_ROOT_PASSWORD)"
  CLICKHOUSE_USER: "$(get CLICKHOUSE_USER lkm)"
  CLICKHOUSE_PASSWORD: "$(get CLICKHOUSE_PASSWORD change-me-clickhouse)"
  PREFECT_DB_PASSWORD: "$(get PREFECT_DB_PASSWORD change-me-prefect-db)"
  INFISICAL_DB_PASSWORD: "$(get INFISICAL_DB_PASSWORD change-me-infisical-db)"
  INFISICAL_ENCRYPTION_KEY: "$(get INFISICAL_ENCRYPTION_KEY change-me)"
  INFISICAL_AUTH_SECRET: "$(get INFISICAL_AUTH_SECRET change-me)"
YAML
