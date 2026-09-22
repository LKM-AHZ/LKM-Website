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

# BITS 会被直接交给 openssl：非数字只剩一句难懂的 openssl 报错，而 512 这种小值能生成
# 一把「RS256 验签方照样接受」的弱签名密钥，故先校验数值与下限
case "$BITS" in
    ''|*[!0-9]*)
        echo "BITS 必须是正整数，当前：$BITS" >&2
        exit 1
        ;;
esac
if [ "$BITS" -lt 2048 ]; then
    echo "BITS 至少 2048（当前 $BITS）——低于此值的 RS256 签名密钥不安全" >&2
    exit 1
fi

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
# umask 只作用于「新建」的条目：OUT_DIR 若早先以 755 建过（手工、compose、git），
# 目录会一直是 world-traversable，里面的密钥文件名可被任意本机用户枚举
chmod 700 "$OUT_DIR"
# 先写临时文件、成功后再原子改名：`openssl genrsa -out "$PRIV"` 会先把目标截断，FORCE=1
# 轮换时一旦失败（BITS 非法、磁盘满、被 Ctrl+C 打断），原可用私钥就被毁而旧公钥还在 ——
# auth 拿半份密钥签发，所有 token 验签失败。临时名带 $$，并发/重入互不踩。
tmp_priv="$PRIV.tmp.$$"
tmp_pub="$PUB.tmp.$$"
trap 'rm -f "$tmp_priv" "$tmp_pub"' EXIT INT TERM
# 私钥只留在 auth 侧；公钥可公开（JWKS 端点亦发布同一份）
openssl genrsa -out "$tmp_priv" "$BITS"
openssl rsa -in "$tmp_priv" -pubout -out "$tmp_pub"
# 落盘前自校验：用私钥现推一份公钥与刚生成的逐字节比对（不依赖已废弃的 -modulus）。
# 缺了这一步就可能「宣布成功」却留下一对不配套的密钥——auth 与验签方会对所有 token 各说各话。
if ! openssl pkey -in "$tmp_priv" -pubout 2>/dev/null | cmp -s - "$tmp_pub"; then
    echo "公私钥不匹配，生成失败（已存在的密钥未被触碰）" >&2
    exit 1
fi
chmod 600 "$tmp_priv"
chmod 644 "$tmp_pub"
mv "$tmp_priv" "$PRIV"
mv "$tmp_pub" "$PUB"

cat <<EOF
已生成 RS256 密钥对（$BITS 位）：
  私钥（仅 auth 侧挂载，勿下发）：$PRIV
  公钥（backend/网关挂载）：      $PUB

启用方式（compose）——**两步缺一不可**：
  1) 在根 .env 里显式指定**容器内路径**（compose 只挂载 ./deploy/jwt/keys 目录，
     env 变量默认取空 → 不设则 RS256 不启用、静默回落 HS256）：
       LKM_JWT_PRIVATE_KEY_FILE=/etc/lkm/jwt/jwt-private.pem
       LKM_JWT_PUBLIC_KEY_FILE=/etc/lkm/jwt/jwt-public.pem
     auth 用私钥签发；backend 与网关只用公钥验签（挂载的是整个目录，私钥文件对
     backend 可见但无任何变量引用它）。
  2) 重建容器（env 变了，restart 不够）：
       docker compose up -d --force-recreate auth backend apisix-render apisix
     网关侧由 apisix-render 把公钥渲染进消费者。
  3) 存量 token 已在批 1 重建库时全部失效，可直接设 LKM_JWT_HS_FALLBACK=false 关掉 HS。

k8s：
  NAMESPACE=lkm sh deploy/k8s/gen-secret.sh | kubectl apply -f -
  （gen-secret.sh 会读同一对 PEM 并并入 lkm-secrets，各 Pod 以卷挂载取用）
EOF
