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
#   __BOT_MAX_BODY_SIZE__  bot 面板请求体上限（**独立来源** LKM_BOT_MAX_UPLOAD_BYTES：
#                          bot 允许单文件 512MB，远大于社群站的 100MB，不可复用上面那个）
#   __BOT_BASE_PATH__      bot 面板子路径前缀（来源 LKM_BOT_BASE_PATH，默认 /bot）：
#                          路由 uri 与剥前缀正则的匹配串，必须与面板自身的 dashboard base
#                          及前端构建期 base 同值，否则路由空转（改了这里要同时改 compose
#                          的 lkmbot 服务 / k8s 的 lkm-gateway-config）
#   __UPSTREAM_SUFFIX__    upstream 服务名后缀（compose 空 / k8s `.lkm.svc.cluster.local`）
#   __DNS_RESOLVER__       上游 DNS（compose 127.0.0.11 / k8s CoreDNS ClusterIP）
#
# 本脚本同时渲染**两个**产物：apisix.yaml（路由）与 config.yaml（APISIX 自身配置）。
# config.yaml 里只有 DNS 解析这一处随运行时变化，故也纳入同一模板展开点，
# 避免 k8s 侧另存一份 config.yaml 副本（第二真相源）。
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
SRC_CONFIG="${APISIX_SRC_CONFIG:-/src/config.yaml}"
OUT_CONFIG="${APISIX_OUT_CONFIG:-/out/config.yaml}"
CERT_ROOT="${APISIX_CERT_ROOT:-/etc/letsencrypt/live}"
# upstream 服务名后缀：compose 留空（Docker 内嵌 DNS 解析短名）；
# k8s 置 `.lkm.svc.cluster.local`（CoreDNS 不补 search domain，裸短名查不到）
UPSTREAM_SUFFIX="${APISIX_UPSTREAM_SUFFIX:-}"
# 上游 DNS 解析器：compose 为 Docker 内嵌 DNS；k8s 为 CoreDNS ClusterIP
DNS_RESOLVER="${APISIX_DNS_RESOLVER:-127.0.0.11}"
# 请求体上限：与后端 LKM_MAX_UPLOAD_BYTES 取同一来源（compose 下发同一个 env），
# 使「网关拒收」与「应用校验」用同一个数，不再两处手改。
MAX_BODY_SIZE="${APISIX_MAX_BODY_SIZE:-104857600}"
# bot 面板请求体上限：与 bot 路由**独立**（compose 由 .env 的 LKM_BOT_MAX_UPLOAD_BYTES 下发，
# k8s 直接放 lkm-gateway-config——它只有网关消费，无应用侧同源对象），
# 默认 550000000 ≈ 550MB（bot 应用侧单文件上限 512MB + multipart 开销）。刻意不复用
# MAX_BODY_SIZE：那个数被社群站后端与网关共用，改它会把社群站的上限一起抬高。
BOT_MAX_BODY_SIZE="${APISIX_BOT_MAX_BODY_SIZE:-550000000}"
# bot 面板子路径前缀：路由 uri 与 proxy-rewrite 剥前缀正则都由它展开（占位 __BOT_BASE_PATH__）。
# compose 侧来源 .env 的 LKM_BOT_BASE_PATH（k8s 侧放 lkm-gateway-config），与面板自身的
# ASTRBOT_DASHBOARD_BASE_PATH / 构建期 VITE_BASE_PATH 同一变量——三面必须同值，否则
# 路由匹配不到面板。**不带尾斜杠**（正则里紧跟 `/(.*)`，带斜杠会多出一级）。
BOT_BASE_PATH="${APISIX_BOT_BASE_PATH:-/bot}"
# RS256 网关验签（批 5）：公钥 PEM 文件路径（未配置/文件不存在 → 网关不做 JWT 校验）。
# 公钥非机密，但由部署期生成，故以文件挂载而非写进模板；consumer/claim/cookie 三项
# 必须与 LKM-service 侧 jwt_keys.GATEWAY_KEY 及 admin 会话 cookie 名一致（有静态测试锁）。
JWT_PUBLIC_KEY_FILE="${APISIX_JWT_PUBLIC_KEY_FILE:-}"
JWT_CONSUMER="${APISIX_JWT_CONSUMER:-lkm_rs256}"
JWT_KEY_CLAIM="${APISIX_JWT_KEY_CLAIM:-lkm}"
JWT_COOKIE="${APISIX_JWT_COOKIE:-admin_session}"
# APISIX_RENDER_ONCE=1 → 只渲染一次后退出（测试用；生产默认常驻循环）
RENDER_ONCE="${APISIX_RENDER_ONCE:-0}"

# 证书按域名逐个签发目录，故 DOMAINS 为并集；hosts/origins 则分域展开
# （不带引号：后续用于 for 循环词分割）
# 注：bot 面板已并入社群域的子路径 /bot/（不再有独立子域），故证书/SNI/ACME 只覆盖这两个域。
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
            # SNI 列表必须与路由 hosts 一致（各域均带 www 变体；bot 面板已并入社群域子路径，
            # 不再有独立 SNI 条目）
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

jwt_sections() {
    # $1=consumers 段输出文件，$2=路由内 plugins 段输出文件。
    # 未配置公钥文件 → 两个文件都留空（网关不做 JWT 校验，应用层照常验签）。
    c_out="$1"
    r_out="$2"
    : > "$c_out"
    : > "$r_out"
    if [ -z "$JWT_PUBLIC_KEY_FILE" ] || [ ! -f "$JWT_PUBLIC_KEY_FILE" ]; then
        echo "[apisix-render] 未配置 APISIX_JWT_PUBLIC_KEY_FILE（或文件不存在）：网关不做 JWT 验签" >&2
        return 0
    fi
    {
        echo "consumers:"
        echo "  - username: $JWT_CONSUMER"
        echo "    plugins:"
        echo "      jwt-auth:"
        echo "        key: $JWT_KEY_CLAIM"
        echo "        algorithm: RS256"
        echo "        public_key: |"
        sed 's/^/          /' "$JWT_PUBLIC_KEY_FILE"
        # APISIX 3.9 的 jwt-auth consumer schema 在 algorithm=RS256 时**强制要求**
        # private_key 字段（dependencies.oneOf 的 required），而验签路径只用 public_key
        # （jwt-auth.lua 的 algorithm_handler 只取 keypair 的第一个返回值）。故这里填同一份
        # **公钥**：网关因此不持有任何可用于签发的密钥。data_plane 模式下 Admin API 关闭，
        # 插件的签发端点不可达，填错也无签发面。改动此处前请先读路线图 §8 的登记。
        echo "        private_key: |"
        sed 's/^/          /' "$JWT_PUBLIC_KEY_FILE"
    } > "$c_out"
    {
        echo "      jwt-auth:"
        echo "        cookie: $JWT_COOKIE"
    } > "$r_out"
    echo "[apisix-render] 网关 JWT 验签已启用（consumer=$JWT_CONSUMER alg=RS256）"
}

render_once() {
    # 临时片段名带 PID：并发跑本脚本（测试并行、多个 compose 项目共用宿主 /tmp）时，
    # 固定名会让彼此覆盖中间产物，渲染结果偶发缺路由/串证书。
    ssl_tmp="/tmp/lkm-apisix-ssls.$$"
    jwt_c_tmp="/tmp/lkm-apisix-jwt-consumers.$$"
    jwt_r_tmp="/tmp/lkm-apisix-jwt-route.$$"
    ssl_block "$ssl_tmp"
    jwt_sections "$jwt_c_tmp" "$jwt_r_tmp"
    # 顺序：先展开标量/列表占位（sed），再整段替换多行占位（awk 读入文件）：
    # __SSL_SECTION__（证书）/ __JWT_CONSUMERS_SECTION__（网关验签消费者）/ __JWT_ROUTE_SECTION__（路由内插件）
    sed \
        -e "s|__COMMUNITY_HOSTS__|$COMMUNITY_HOSTS|g" \
        -e "s|__COMMUNITY_DOMAIN__|$COMMUNITY_DOMAIN|g" \
        -e "s|__OFFICIAL_HOSTS__|$OFFICIAL_HOSTS|g" \
        -e "s|__ALL_HOSTS__|$ALL_HOSTS|g" \
        -e "s|__COMMUNITY_ORIGINS__|$COMMUNITY_ORIGINS|g" \
        -e "s|__MAX_BODY_SIZE__|$MAX_BODY_SIZE|g" \
        -e "s|__BOT_MAX_BODY_SIZE__|$BOT_MAX_BODY_SIZE|g" \
        -e "s|__BOT_BASE_PATH__|$BOT_BASE_PATH|g" \
        -e "s|__UPSTREAM_SUFFIX__|$UPSTREAM_SUFFIX|g" \
        "$SRC" | awk -v ssl="$ssl_tmp" -v jwtc="$jwt_c_tmp" -v jwtr="$jwt_r_tmp" '
        /^# __SSL_SECTION__$/ {
            while ((getline line < ssl) > 0) print line
            close(ssl)
            next
        }
        /^# __JWT_CONSUMERS_SECTION__$/ {
            while ((getline line < jwtc) > 0) print line
            close(jwtc)
            next
        }
        /^[[:space:]]*# __JWT_ROUTE_SECTION__$/ {
            while ((getline line < jwtr) > 0) print line
            close(jwtr)
            next
        }
        { print }
    ' > "$OUT.tmp"
    # ② APISIX 自身配置：仅 DNS 解析一处随运行时变化（compose 内嵌 DNS / k8s CoreDNS）
    sed -e "s|__DNS_RESOLVER__|$DNS_RESOLVER|g" "$SRC_CONFIG" > "$OUT_CONFIG.tmp"
    # 占位未展开完 → 不覆盖上一版 good config（宁可保持旧配置，也不给 APISIX 送坏 YAML）。
    # 排除 __SSL_SECTION__：模板顶部注释里作为说明文字出现过（非独立占位行），会被带进产物。
    leftover="$(
        { grep -o '__[A-Z_]*__' "$OUT.tmp" | grep -v '^__SSL_SECTION__$' || true
          grep -o '__[A-Z_]*__' "$OUT_CONFIG.tmp" || true
        } | sort -u
    )"
    if [ -n "$leftover" ]; then
        echo "[apisix-render] ERROR 仍有未展开占位，保留上一版配置：" >&2
        printf '%s\n' "$leftover" >&2
        return 1
    fi
    # 就地覆盖（不用 mv）：APISIX 以单文件方式挂载该卷内文件，替换 inode 会导致容器内
    # 挂载仍指向旧文件；同 inode 写入才能被 APISIX 的 yaml provider 监测到 mtime 变化并 reload。
    cat "$OUT.tmp" > "$OUT"
    cat "$OUT_CONFIG.tmp" > "$OUT_CONFIG"
    echo "[apisix-render] rendered $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

for d in $DOMAINS; do ensure_selfsigned "$d"; done
# 冷启动：展开失败时，只有在**没有**上一版 good config 可兜底的情况下才硬失败
# （否则 APISIX 无配置可加载；有旧配置则沿用，等下一轮重试）。
# 两个产物缺任一都算无兜底：APISIX 少 config.yaml 起不来，少 apisix.yaml 则无路由。
if ! render_once && { [ ! -s "$OUT" ] || [ ! -s "$OUT_CONFIG" ]; }; then
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
