#!/bin/sh
# APISIX standalone 配置渲染器（M5 7.2.4）：
# 本脚本是网关配置的**唯一模板展开点**，把 deploy/apisix/apisix.yaml 里的占位替换成实值后
# 写入共享卷，供 APISIX 的 yaml config_provider 自动加载。占位共五类：
#   __SSL_SECTION__        certbot 证书 → 内联 PEM 的 ssls 段（standalone 只收内联 PEM）
#   __COMMUNITY_HOSTS__    社区域名 + www（各 API/认证路由的 hosts）
#   __OFFICIAL_HOSTS__     官网域名 + www
#   __ALL_HOSTS__          两者并集（ACME challenge / http→https 重定向）
#   __COMMUNITY_ORIGINS__  CORS allow_origins（https:// + www）
#   __MAX_BODY_SIZE__      请求体上限（与后端 max_upload_bytes 同源，见 README/路线图）
# 域名只需在 APISIX_COMMUNITY_DOMAINS / APISIX_OFFICIAL_DOMAINS 两处改，hosts 与 CORS 来源
# 一并跟随——此前这两者在模板里各硬编码 12+8 处，改域名必漏。
# - 缺证书时生成自签占位（CN=域名，1 天有效），保证 APISIX 冷启动即有证书可起。
# - 每 6h 重渲染一次：既拾取 certbot 续期后的新证书，也顺带触发 APISIX reload 重新解析
#   upstream DNS（standalone 静态解析，重启后容器 IP 变化靠此刷新）。
# - 渲染失败（awk/sed 异常）不覆盖上一版 good config（tmp + mv 原子替换）。
set -e

# 社区域名（承载 /api、/graphql、前台与后台认证面）与官网域名（静态站）
COMMUNITY="${APISIX_COMMUNITY_DOMAINS:-lkm-ahz.ltd}"
OFFICIAL="${APISIX_OFFICIAL_DOMAINS:-lkm-ahz.icu}"
SRC="${APISIX_SRC:-/src/apisix.yaml}"
OUT="${APISIX_OUT:-/out/apisix.yaml}"
CERT_ROOT="${APISIX_CERT_ROOT:-/etc/letsencrypt/live}"
# 请求体上限：与后端 LKM_MAX_UPLOAD_BYTES 取同一来源（compose 下发同一个 env），
# 使「网关拒收」与「应用校验」用同一个数，不再两处手改。
MAX_BODY_SIZE="${APISIX_MAX_BODY_SIZE:-104857600}"
# APISIX_RENDER_ONCE=1 → 只渲染一次后退出（测试用；生产默认常驻循环）
RENDER_ONCE="${APISIX_RENDER_ONCE:-0}"

# 证书按域名逐个签发目录，故 DOMAINS 为并集；hosts/origins 则分域展开
# （不带引号：后续用于 for 循环词分割）
DOMAINS="$COMMUNITY $OFFICIAL"

# 下列变量注入 YAML 数组/标量，只用逗号+空格分隔，不含 sed 分隔符 `|` 与换行
hosts_of() {  # hosts_of "<空格分隔域名>" → "d1, www.d1, d2, www.d2"
    out=""
    for d in $1; do
        out="$out$d, www.$d, "
    done
    printf '%s' "$out" | sed 's/, $//'
}
COMMUNITY_HOSTS="$(hosts_of "$COMMUNITY")"
OFFICIAL_HOSTS="$(hosts_of "$OFFICIAL")"
ALL_HOSTS="$COMMUNITY_HOSTS, $OFFICIAL_HOSTS"
# MinIO 路由的 Host 改写目标：取社群主域名（裸域，不带 www）——须与后端
# LKM_S3_PUBLIC_ENDPOINT_URL 的 host 一致，否则 S3 预签名校验失败
COMMUNITY_DOMAIN="${COMMUNITY%% *}"
origins_of() {  # origins_of "<空格分隔域名>" → "https://d1,https://www.d1,..."
    out=""
    for d in $1; do
        # 必须写成 ${out}：$outhttps 会被 shell 贪婪解析成变量名 "outhttps"（空值），吃掉 scheme
        out="${out}https://$d,https://www.$d,"
    done
    printf '%s' "$out" | sed 's/,$//'
}
COMMUNITY_ORIGINS="$(origins_of "$COMMUNITY")"

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
    # 顺序：先展开标量/列表占位（sed），再整段替换 SSL 占位（awk 多行读入）
    sed \
        -e "s|__COMMUNITY_HOSTS__|$COMMUNITY_HOSTS|g" \
        -e "s|__COMMUNITY_DOMAIN__|$COMMUNITY_DOMAIN|g" \
        -e "s|__OFFICIAL_HOSTS__|$OFFICIAL_HOSTS|g" \
        -e "s|__ALL_HOSTS__|$ALL_HOSTS|g" \
        -e "s|__COMMUNITY_ORIGINS__|$COMMUNITY_ORIGINS|g" \
        -e "s|__MAX_BODY_SIZE__|$MAX_BODY_SIZE|g" \
        "$SRC" | awk -v ssl="$ssl_tmp" '
        /^# __SSL_SECTION__$/ {
            while ((getline line < ssl) > 0) print line
            close(ssl)
            next
        }
        { print }
    ' > "$OUT.tmp"
    # 占位未展开完 → 不覆盖上一版 good config（宁可保持旧配置，也不给 APISIX 送坏 YAML）。
    # 排除 __SSL_SECTION__：模板顶部注释里作为说明文字出现过（非独立占位行），会被带进产物。
    leftover="$(grep -o '__[A-Z_]*__' "$OUT.tmp" | grep -v '^__SSL_SECTION__$' | sort -u || true)"
    if [ -n "$leftover" ]; then
        echo "[apisix-render] ERROR 仍有未展开占位，保留上一版配置：" >&2
        printf '%s\n' "$leftover" >&2
        return 1
    fi
    # 就地覆盖（不用 mv）：APISIX 以单文件方式挂载该卷内文件，替换 inode 会导致容器内
    # 挂载仍指向旧文件；同 inode 写入才能被 APISIX 的 yaml provider 监测到 mtime 变化并 reload。
    cat "$OUT.tmp" > "$OUT"
    echo "[apisix-render] rendered $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

for d in $DOMAINS; do ensure_selfsigned "$d"; done
# 冷启动：展开失败时，只有在**没有**上一版 good config 可兜底的情况下才硬失败
# （否则 APISIX 无配置可加载；有旧配置则沿用，等下一轮重试）。
if ! render_once && [ ! -s "$OUT" ]; then
    exit 1
fi

if [ "$RENDER_ONCE" = "1" ]; then
    exit 0
fi

while :; do
    sleep 21600
    for d in $DOMAINS; do ensure_selfsigned "$d"; done
    # 周期重渲染失败不致命：保留上一版配置，6h 后重试
    render_once || true
done
