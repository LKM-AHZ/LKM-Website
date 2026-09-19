#!/bin/sh
# APISIX 网关冒烟 + 运行时验收（M5 7.2.4）。在网关已启动的宿主机上跑：
#   sh deploy/apisix/smoke.sh [BASE_HOST] [COMMUNITY_DOMAIN] [OFFICIAL_DOMAIN] [BOT_DOMAIN]
# 默认 BASE_HOST=127.0.0.1（本机映射 80/443），域名 lkm-ahz.ltd / lkm-ahz.icu / bot.lkm-ahz.ltd。
#
# 连接方式（与旧脚本的关键差异，均为真机验收暴露的必要修正）：
#   --resolve <domain>:<port>:<host>  让 TLS SNI = 域名。APISIX 按 SNI 选 ssls 证书，
#                                     若直连 IP（无 SNI）握手会被拒（"failed to find SNI"）。
#   --noproxy '*'                     绕过宿主机 http(s)_proxy，否则域名请求会被代理解析。
# 证书可能是自签，故 -k。
#
# 环境变量：
#   SMOKE_HEAVY=1        追加 100m 上传边界检查（真的发 ~101MB，耗时/占带宽）
#   SMOKE_BOT=1          追加 bot 面板可达检查（需 `--profile bot` 已起 lkmbot，否则 503）
#   SMOKE_HTTP_PORT=N     网关 HTTP 端口（默认 80；k8s NodePort 场景指到映射后的宿主端口）
#   SMOKE_HTTPS_PORT=N    网关 HTTPS 端口（默认 443；同上）
#
# 覆盖：http→https 301（不含内部端口）、后端健康、GraphQL、官网分流、登录限流 429、
#       MinIO 路由（Host 改写后到达对象存储）、静态资源长缓存头、WS upgrade 转发、上传体上限、
#       bot 子域名 301（+ SMOKE_BOT=1 时的面板可达）。
# 仍需人工/独立手段：X-Real-IP 等转发头落上游的值（需 header echo 上游）、证书续期后 reload、
#       DNS discovery 在后端容器重启换 IP 后的自愈；见 ../执行路线图.md §7.2.4。
set -u

HOST="${1:-127.0.0.1}"
COMMUNITY="${2:-lkm-ahz.ltd}"
OFFICIAL="${3:-lkm-ahz.icu}"
BOT="${4:-bot.lkm-ahz.ltd}"
# 网关端口。默认 80/443（compose 直接映射）；k8s 下网关是 NodePort，
# 用 SMOKE_HTTP_PORT/SMOKE_HTTPS_PORT 指到映射后的宿主端口（如 8080/8443）。
# ⚠️ 非默认端口时 URL 必须显式带端口——`--resolve` 只改解析目标，不会改默认端口。
HTTP_PORT="${SMOKE_HTTP_PORT:-80}"
HTTPS_PORT="${SMOKE_HTTPS_PORT:-443}"
HP=""; [ "$HTTP_PORT" = "80" ] || HP=":$HTTP_PORT"
SP=""; [ "$HTTPS_PORT" = "443" ] || SP=":$HTTPS_PORT"
pass=0
fail=0

check() {
    name="$1"; shift
    if "$@"; then
        echo "PASS  $name"
        pass=$((pass + 1))
    else
        echo "FAIL  $name"
        fail=$((fail + 1))
    fi
}

# 带正确 SNI 的 curl：分别解析社区域名 https/http、官网 https
cc()  { curl -sk --noproxy '*' --resolve "$COMMUNITY:$HTTPS_PORT:$HOST" "$@"; }
cc80(){ curl -s  --noproxy '*' --resolve "$COMMUNITY:$HTTP_PORT:$HOST"  "$@"; }
oc()  { curl -sk --noproxy '*' --resolve "$OFFICIAL:$HTTPS_PORT:$HOST"  "$@"; }

# ── 1) http → https 301，且 Location 不得带内部监听端口 :9443 ──
loc=$(cc80 -o /dev/null -w '%{redirect_url}' "http://$COMMUNITY$HP/")
code=$(cc80 -o /dev/null -w '%{http_code}' "http://$COMMUNITY$HP/")
check "community http->https 301" test "$code" = "301"
if printf '%s' "$loc" | grep -q '^https://' && ! printf '%s' "$loc" | grep -q ':9443'; then
    echo "PASS  redirect location no internal port ($loc)"
    pass=$((pass + 1))
else
    echo "FAIL  redirect location no internal port ($loc)"
    fail=$((fail + 1))
fi

loc=$(curl -s --noproxy '*' --resolve "$OFFICIAL:$HTTP_PORT:$HOST" -o /dev/null -w '%{redirect_url}' "http://$OFFICIAL$HP/")
check "official http->https 301" sh -c 'printf "%s" "$1" | grep -q "^https://" && ! printf "%s" "$1" | grep -q ":9443"' _ "$loc"

# ── 2) 后端健康经网关 200 ──
code=$(cc -o /dev/null -w '%{http_code}' "https://$COMMUNITY$SP/api/v1/health")
check "backend health 200" test "$code" = "200"

# ── 3) GraphQL 可达（200 或 400=已到达后端；5xx 视为故障）──
code=$(cc -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -d '{"query":"{__typename}"}' "https://$COMMUNITY$SP/graphql")
if [ "$code" = "200" ] || [ "$code" = "400" ]; then
    echo "PASS  graphql reachable"
    pass=$((pass + 1))
else
    echo "FAIL  graphql reachable (code=$code)"
    fail=$((fail + 1))
fi

# ── 4) 官网域名分流：.icu 经 static 输出 200 ──
code=$(oc -o /dev/null -w '%{http_code}' "https://$OFFICIAL$SP/")
check "official site 200" test "$code" = "200"

# ── 5) 登录网关限流：60/min → 持续打应出现 429 ──
got429=0
i=1
while [ "$i" -le 80 ]; do
    code=$(cc -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
        -d '{"username":"smoke","password":"x"}' "https://$COMMUNITY$SP/api/v1/auth/login/password")
    if [ "$code" = "429" ]; then
        got429=1
        break
    fi
    i=$((i + 1))
done
check "login gateway rate-limit 429" test "$got429" = "1"

# ── 6) MinIO 路由：未签名 GET /lkm/ 应到达对象存储并回 403 + x-amz-request-id ──
#    （Host 被改写为 lkm-ahz.ltd，S3 XML 响应即证明路由与 host rewrite 生效）
hdr=$(cc -D - -o /dev/null "https://$COMMUNITY$SP/lkm/" | tr -d '\r')
code=$(printf '%s' "$hdr" | awk 'NR==1{print $2}')
check "minio route 403 (reached object store)" test "$code" = "403"
if printf '%s' "$hdr" | grep -qi '^x-amz-request-id:'; then
    echo "PASS  minio S3 response header present"
    pass=$((pass + 1))
else
    echo "FAIL  minio S3 response header present"
    fail=$((fail + 1))
fi

# ── 7) 静态资源长缓存头（response-rewrite 对 404 也应生效，故不依赖文件存在）──
hdr=$(cc -D - -o /dev/null "https://$COMMUNITY$SP/static/avatars/__smoke_nonexistent__" | tr -d '\r')
if printf '%s' "$hdr" | grep -i '^cache-control:' | grep -q 'max-age=31536000'; then
    echo "PASS  avatars long-cache header"
    pass=$((pass + 1))
else
    echo "FAIL  avatars long-cache header"
    fail=$((fail + 1))
fi

# ── 8) 100m 上传边界（可选，SMOKE_HEAVY=1）──
if [ "${SMOKE_HEAVY:-0}" = "1" ]; then
    # 100MB + 1 字节 → APISIX client-control 应回 413，且请求不到后端
    code=$(head -c 104857601 /dev/zero | cc -o /dev/null -w '%{http_code}' -X POST \
        --data-binary @- -H 'Content-Type: application/octet-stream' \
        "https://$COMMUNITY$SP/api/v1/files/upload-init")
    check "upload >100m rejected 413" test "$code" = "413"
    # 1MB → 不得 413（401/400/200 均说明穿过网关到达后端）
    code=$(head -c 1048576 /dev/zero | cc -o /dev/null -w '%{http_code}' -X POST \
        --data-binary @- -H 'Content-Type: application/octet-stream' \
        "https://$COMMUNITY$SP/api/v1/files/upload-init")
    if [ "$code" != "413" ]; then
        echo "PASS  upload <=100m passes gateway (code=$code)"
        pass=$((pass + 1))
    else
        echo "FAIL  upload <=100m passes gateway (got 413)"
        fail=$((fail + 1))
    fi
else
    echo "SKIP  upload body-limit checks (set SMOKE_HEAVY=1 to enable)"
fi

# ── 9) WebSocket upgrade：真实端点 /api/v1/ws/events 必须能穿网关到后端 ──
# 用 HTTP/1.1（HTTP/2 禁止 Connection/Upgrade 连接级头，会假失败）。
# 无效 token → 后端在 accept 前拒绝，表现为 403；若 APISIX 未转发 upgrade，后端按普通
# GET 处理返回 404（即本检查要抓的回归）。有效 token 时为 101。
code=$(curl -sk --http1.1 --noproxy '*' --resolve "$COMMUNITY:$HTTPS_PORT:$HOST" -o /dev/null -w '%{http_code}' \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "https://$COMMUNITY$SP/api/v1/ws/events?token=invalid")
case "$code" in
    101|401|403) echo "PASS  ws upgrade reaches backend (status=$code)"; pass=$((pass + 1)) ;;
    *)           echo "FAIL  ws upgrade reaches backend (status=$code, expected 403/101)"; fail=$((fail + 1)) ;;
esac

# ── 10) bot 面板子域名（bot.lkm-ahz.ltd）──
# 301 与 bot 容器在不在无关（APISIX 直接跳转），故**无条件**检查：它抓的是「bot 域名没进
# 网关 hosts 并集」这类配置回归——漏了的表现恰是 http 下 404 而非跳转。
loc=$(curl -s --noproxy '*' --resolve "$BOT:$HTTP_PORT:$HOST" -o /dev/null -w '%{redirect_url}' "http://$BOT$HP/")
check "bot http->https 301" sh -c 'printf "%s" "$1" | grep -q "^https://" && ! printf "%s" "$1" | grep -q ":9443"' _ "$loc"

# 面板可达需 lkmbot 已起（可选组件，默认不起）→ 用 SMOKE_BOT=1 显式开启，
# 否则上游 service_name=lkmbot:6185 解析不到，APISIX 回 503 会把冒烟判红。
if [ "${SMOKE_BOT:-0}" = "1" ]; then
    # 未登录访问面板根路径：登录页 200，或重定向到登录页 302/307
    code=$(curl -sk --noproxy '*' --resolve "$BOT:$HTTPS_PORT:$HOST" -o /dev/null -w '%{http_code}' "https://$BOT$SP/")
    case "$code" in
        200|302|307) echo "PASS  bot dashboard reachable (status=$code)"; pass=$((pass + 1)) ;;
        *)           echo "FAIL  bot dashboard reachable (status=$code, expected 200/302/307)"; fail=$((fail + 1)) ;;
    esac
else
    echo "SKIP  bot dashboard check (set SMOKE_BOT=1 and start --profile bot to enable)"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
