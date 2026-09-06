#!/bin/sh
# LKM nginx 入口:缺证书时为各域名生成自签占位证书,并后台定时 reload 拾取续期后的新证书。
# 现状为自签模式;未来接入 Let's Encrypt(certbot certonly)后各域名证书原地更新,本脚本不覆盖。
set -e

# 需要自签占位证书的域名(与 nginx.conf 各 server 的证书路径 /etc/letsencrypt/live/<域名>/ 对应)
DOMAINS="lkm-ahz.ltd lkm-ahz.icu"

ensure_selfsigned() {
    domain="$1"
    CERT_DIR="/etc/letsencrypt/live/$domain"
    CERT_FILE="$CERT_DIR/fullchain.pem"
    KEY_FILE="$CERT_DIR/privkey.pem"

    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        # nginx:alpine 默认不含 openssl CLI,按需安装
        apk add --no-cache openssl >/dev/null 2>&1 || true
        mkdir -p "$CERT_DIR"
        openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE" \
            -subj "/CN=$domain" >/dev/null 2>&1
    fi
}

for d in $DOMAINS; do
    ensure_selfsigned "$d"
done

# 后台每 6h reload,拾取 certbot 续期后的新证书(证书文件原地更新)
( while :; do sleep 21600; nginx -s reload; done ) &

exec "$@"
