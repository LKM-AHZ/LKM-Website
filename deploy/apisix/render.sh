#!/bin/sh
# APISIX standalone 配置渲染器（M5 7.2.4）：
# standalone 的 ssl 对象只接受**内联 PEM**（不能引用证书文件路径），故由本 sidecar 读取
# deploy/apisix/apisix.yaml（路由模板，含 `# __SSL_SECTION__` 占位）+ certbot 证书，渲染出
# 完整 apisix.yaml 写入共享卷，供 APISIX 的 yaml config_provider 自动加载。
# - 缺证书时生成自签占位（CN=域名，1 天有效），保证 APISIX 冷启动即有证书可起。
# - 每 6h 重渲染一次：既拾取 certbot 续期后的新证书，也顺带触发 APISIX reload 重新解析
#   upstream DNS（standalone 静态解析，重启后容器 IP 变化靠此刷新）。
# - 渲染失败（awk/sed 异常）不覆盖上一版 good config（tmp + mv 原子替换）。
set -e

DOMAINS="${APISIX_DOMAINS:-lkm-ahz.ltd lkm-ahz.icu}"
SRC="${APISIX_SRC:-/src/apisix.yaml}"
OUT="${APISIX_OUT:-/out/apisix.yaml}"
CERT_ROOT="${APISIX_CERT_ROOT:-/etc/letsencrypt/live}"
# APISIX_RENDER_ONCE=1 → 只渲染一次后退出（测试用；生产默认常驻循环）
RENDER_ONCE="${APISIX_RENDER_ONCE:-0}"

ensure_selfsigned() {
    domain="$1"
    dir="$CERT_ROOT/$domain"
    cert="$dir/fullchain.pem"
    key="$dir/privkey.pem"
    if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
        # alpine 基础镜像不含 openssl CLI，按需安装（失败不致命：已有证书时根本不走这里）
        apk add --no-cache openssl >/dev/null 2>&1 || true
        mkdir -p "$dir"
        openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
            -keyout "$key" -out "$cert" -subj "/CN=$domain" >/dev/null 2>&1
    fi
}

ssl_block() {
    tmp="$1"
    count=0
    {
        echo "ssls:"
        for d in $DOMAINS; do
            cert="$CERT_ROOT/$d/fullchain.pem"
            key="$CERT_ROOT/$d/privkey.pem"
            if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
                continue
            fi
            count=$((count + 1))
            echo "  - snis:"
            echo "    - $d"
            echo "    - www.$d"
            echo "    cert: |"
            sed 's/^/      /' "$cert"
            echo "    key: |"
            sed 's/^/      /' "$key"
        done
    } > "$tmp"
    # 无任何可用证书 → 显式空列表（避免 ssls: null）
    if [ "$count" -eq 0 ]; then
        echo "ssls: []" > "$tmp"
    fi
    return 0
}

render_once() {
    ssl_tmp=/tmp/ssls.yaml
    ssl_block "$ssl_tmp"
    awk -v ssl="$ssl_tmp" '
        /^# __SSL_SECTION__$/ {
            while ((getline line < ssl) > 0) print line
            close(ssl)
            next
        }
        { print }
    ' "$SRC" > "$OUT.tmp"
    # 就地覆盖（不用 mv）：APISIX 以单文件方式挂载该卷内文件，替换 inode 会导致容器内
    # 挂载仍指向旧文件；同 inode 写入才能被 APISIX 的 yaml provider 监测到 mtime 变化并 reload。
    cat "$OUT.tmp" > "$OUT"
    echo "[apisix-render] rendered $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

for d in $DOMAINS; do ensure_selfsigned "$d"; done
render_once

if [ "$RENDER_ONCE" = "1" ]; then
    exit 0
fi

while :; do
    sleep 21600
    for d in $DOMAINS; do ensure_selfsigned "$d"; done
    render_once
done
