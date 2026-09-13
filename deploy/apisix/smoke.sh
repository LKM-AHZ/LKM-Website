#!/bin/sh
# APISIX 网关冒烟（M5 7.2.4）。在网关已启动的宿主机上跑：
#   sh deploy/apisix/smoke.sh [BASE_HOST]
# 默认 BASE_HOST=127.0.0.1（本机映射 80/443）。证书可能是自签，故用 -k。
# 覆盖：http→https 301、健康、GraphQL、登录网关限流 429、官网分流。
# 需人工验证（脚本无法自足）：WebSocket upgrade、100m 上传、MinIO 预签名 GET/PUT、
# 证书续期后 APISIX reload、X-Real-IP 传递；见 ../执行路线图.md §7.2.4。
set -u

HOST="${1:-127.0.0.1}"
COMMUNITY="lkm-ahz.ltd"
OFFICIAL="lkm-ahz.icu"
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

# 1) http → https 301
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $COMMUNITY" "http://$HOST/" 2>/dev/null)
check "http->https 301 (community)" test "$code" = "301"

# 2) 后端健康经网关 200
code=$(curl -ks -o /dev/null -w '%{http_code}' -H "Host: $COMMUNITY" "https://$HOST/api/v1/health")
check "backend health 200" test "$code" = "200"

# 3) GraphQL 可经网关调用（200 或 400=已到达后端；5xx 视为网关/后端故障）
code=$(curl -ks -o /dev/null -w '%{http_code}' -H "Host: $COMMUNITY" -H 'Content-Type: application/json' \
    -d '{"query":"{__typename}"}' "https://$HOST/graphql")
if [ "$code" = "200" ] || [ "$code" = "400" ]; then
    echo "PASS  graphql reachable"
    pass=$((pass + 1))
else
    echo "FAIL  graphql reachable (code=$code)"
    fail=$((fail + 1))
fi

# 4) 官网域名分流：.icu 经 static 输出 200
code=$(curl -ks -o /dev/null -w '%{http_code}' -H "Host: $OFFICIAL" "https://$HOST/")
check "official site 200" test "$code" = "200"

# 5) 登录网关限流：60/min → 持续打应出现 429
got429=0
i=1
while [ "$i" -le 80 ]; do
    code=$(curl -ks -o /dev/null -w '%{http_code}' -H "Host: $COMMUNITY" -H 'Content-Type: application/json' \
        -d '{"username":"smoke","password":"x"}' "https://$HOST/api/v1/auth/login/password")
    if [ "$code" = "429" ]; then
        got429=1
        break
    fi
    i=$((i + 1))
done
check "login gateway rate-limit 429" test "$got429" = "1"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
