#!/bin/sh
# RS256 签发/验签密钥对生成（批 5，蓝图 §4.2）。
#
# AUTH 持**私钥**签发；主服务与网关只需**公钥**验签。私钥只应出现在 auth 进程的挂载里，
# 不要下发到 backend/worker/网关。
#
# 用法：
#   sh deploy/jwt/gen-keys.sh                 # 生成到 deploy/jwt/keys/
#   sh deploy/jwt/gen-keys.sh /path/dir       # 指定输出目录
#   FORCE=1 sh deploy/jwt/gen-keys.sh         # 覆盖已有密钥（**会使已签发 token 全部失效**）
#
# 幂等：已存在且未设 FORCE 时拒绝执行，避免误轮换。轮换流程＝用新目录生成 →
# 先把新公钥下发到验签方 → 再切 AUTH 的私钥（旧 token 在 access 有效期 15 分钟内自然过期）。
set -eu

OUT_DIR="${1:-$(cd "$(dirname "$0")" && pwd)/keys}"
PRIV="$OUT_DIR/jwt-private.pem"
PUB="$OUT_DIR/jwt-public.pem"
BITS="${BITS:-2048}"

if [ -f "$PRIV" ] || [ -f "$PUB" ]; then
    if [ "${FORCE:-0}" != "1" ]; then
        echo "已存在密钥（$OUT_DIR）。要轮换请显式 FORCE=1（会令已签发 token 全部失效）。" >&2
        exit 1
    fi
fi

command -v openssl >/dev/null 2>&1 || {
    echo "需要 openssl（本机未找到）" >&2
    exit 1
}

umask 077
mkdir -p "$OUT_DIR"
# 私钥只留在 auth 侧；公钥可公开（JWKS 端点亦发布同一份）
openssl genrsa -out "$PRIV" "$BITS" 2>/dev/null
openssl rsa -in "$PRIV" -pubout -out "$PUB" 2>/dev/null
chmod 600 "$PRIV"
chmod 644 "$PUB"

cat <<EOF
已生成 RS256 密钥对（$BITS 位）：
  私钥（仅 auth 侧挂载，勿下发）：$PRIV
  公钥（backend/网关挂载）：      $PUB

启用方式（compose）：
  1) compose 已挂载 ./deploy/jwt/keys:/etc/lkm/jwt:ro，并给 auth 下发
     LKM_JWT_PRIVATE_KEY_FILE=/etc/lkm/jwt/jwt-private.pem
     LKM_JWT_PUBLIC_KEY_FILE=/etc/lkm/jwt/jwt-public.pem
     backend 只下发 LKM_JWT_PUBLIC_KEY_FILE（无需私钥）。
  2) 重启容器：docker compose up -d --no-deps auth backend
     以及网关（apisix-render 会把公钥渲染进消费者）：
     docker compose up -d --no-deps apisix-render apisix
  3) 存量 token 已在批 1 重建库时全部失效，可直接设 LKM_JWT_HS_FALLBACK=false 关掉 HS。

k8s：
  NAMESPACE=lkm sh deploy/k8s/gen-secret.sh | kubectl apply -f -
  （gen-secret.sh 会读同一对 PEM 并并入 lkm-secrets，各 Pod 以卷挂载取用）
EOF
