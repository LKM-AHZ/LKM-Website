#!/bin/sh
# 生成/更新网关 TLS Secret（lkm-tls）。
#
# 为什么 k8s 侧不像 compose 那样让 certbot 直接往卷里写：
# compose 的 certbot 与 apisix-render 共享 docker 命名卷 certbot_conf，证书是**文件**；
# 而 k8s 里跨 Pod 共享的证书应以 Secret 为载体（才能被 apisix Pod 以只读方式挂载、
# 并在轮换时触发滚动）。Secret 的键名不允许含 `/`，故用 `<域名>_fullchain.pem` 这类
# 扁平键名，再由 Pod 的 projected volume 还原成 render.sh 期望的
# `<域名>/fullchain.pem` 目录结构（见 gateway/apisix.yaml）。
#
# 用法：
#   sh deploy/k8s/gen-tls.sh                       # 为默认域生成自签证书并写入 Secret
#   DOMAINS="a.com b.com" sh deploy/k8s/gen-tls.sh # 指定域名
#   sh deploy/k8s/gen-tls.sh | kubectl -n lkm apply -f -
#
# 生产换正式证书：用 cert-manager（推荐）或把 certbot 产物按同样的键名重新导入：
#   kubectl -n lkm create secret generic lkm-tls \
#     --from-file=lkm-ahz.ltd_fullchain.pem=/etc/letsencrypt/live/lkm-ahz.ltd/fullchain.pem \
#     --from-file=lkm-ahz.ltd_privkey.pem=/etc/letsencrypt/live/lkm-ahz.ltd/privkey.pem \
#     --dry-run=client -o yaml | kubectl apply -f -
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS="${NAMESPACE:-lkm}"
DOMAINS="${DOMAINS:-lkm-ahz.ltd lkm-ahz.icu}"
DAYS="${DAYS:-30}"

command -v openssl >/dev/null 2>&1 || { echo "需要本机 openssl" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

{
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: lkm-tls\n  namespace: %s\n  labels:\n    app.kubernetes.io/part-of: lkm\ntype: Opaque\nstringData:\n' "$NS"
    for d in $DOMAINS; do
        # 自签 + SAN：APISIX 按 SNI 选证书，浏览器/curl --resolve 也会校 SAN
        openssl req -x509 -nodes -newkey rsa:2048 -days "$DAYS" \
            -keyout "$TMP/$d.key" -out "$TMP/$d.crt" \
            -subj "/CN=$d" -addext "subjectAltName=DNS:$d,DNS:www.$d" >/dev/null 2>&1
        echo "  ${d}_fullchain.pem: |"
        sed 's/^/    /' "$TMP/$d.crt"
        echo "  ${d}_privkey.pem: |"
        sed 's/^/    /' "$TMP/$d.key"
    done
}

trap - EXIT
rm -rf "$TMP"
