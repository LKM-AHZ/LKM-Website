#!/usr/bin/env bash
# 金路径验收脚本：注册 → 登录 → 发帖 → 评论 → 文件审核 → 通知查询。
#
# 注册有两条路径：
#   1) 真实验证码注册（推荐）：后端开 LKM_DEV_CODE_SINK=1（仅 dev/local/test 允许），脚本设
#      DEMO_REGISTER_EMAIL + AUTH_INTERNAL_TOKEN：/reg/normal → /auth/internal/dev-code 取码
#      → /reg/normal/verify，再用新账号登录；验证码仍只以哈希落库，明文仅出现在该内部响应。
#   2) 未配置 dev-code 时：只跑 /reg/local 做接口级 smoke，内容路径使用 DEMO_USER。
#      发帖需要 normal 权限，local 账号不能发帖。
#
# 前置（真实服务，建议 dev/预发）：
#   export BASE_URL=http://127.0.0.1:8000
#   export DEMO_USER=demo DEMO_PASSWORD=...            # normal 账号（或走路径 1）
#   export DEMO_ADMIN=admin DEMO_ADMIN_PASSWORD=...    # 管理员
#   # 可选：第二个普通账号，给帖子评论以产生通知
#   export DEMO_USER2=demo2 DEMO_PASSWORD2=...
#   # 可选：管理员 TOTP base32 secret；提供则自动 step-up 完成文件审核
#   export DEMO_TOTP_SECRET=JBSWY3DPEHPK3PXP
#   # 可选：指定板块；默认取板块列表第一个
#   export DEMO_BOARD_ID=...
#   # 可选（路径 1）：真实验证码注册
#   export LKM_DEV_CODE_SINK=1        # 后端环境变量，需与下面 token 配套
#   export DEMO_REGISTER_EMAIL=demo@example.com
#   export AUTH_INTERNAL_TOKEN=<LKM_AUTH_HTTP_TOKEN>
#
# 用法：./scripts/demo_golden_path.sh
# 输出：docs/acceptance/golden-path-<UTC>.log（逐步骤 HTTP 状态 + pass/fail/skip）
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
BASE_URL="${BASE_URL%/}"
DEMO_USER="${DEMO_USER:-}"
DEMO_PASSWORD="${DEMO_PASSWORD:-}"
DEMO_USER2="${DEMO_USER2:-}"
DEMO_PASSWORD2="${DEMO_PASSWORD2:-}"
DEMO_ADMIN="${DEMO_ADMIN:-}"
DEMO_ADMIN_PASSWORD="${DEMO_ADMIN_PASSWORD:-}"
DEMO_TOTP_SECRET="${DEMO_TOTP_SECRET:-}"
DEMO_BOARD_ID="${DEMO_BOARD_ID:-}"
DEMO_REGISTER_EMAIL="${DEMO_REGISTER_EMAIL:-}"
AUTH_INTERNAL_TOKEN="${AUTH_INTERNAL_TOKEN:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/docs/acceptance"
mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$OUT_DIR/golden-path-$STAMP.log"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
COOKIE_JAR="$TMP_DIR/admin.cookies"

FAILED=0
STATUS=""
BODY=""

log() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }
section() { log ""; log "== $* =="; }

check() { # name expected actual
    if [[ "$2" == "$3" ]]; then
        log "PASS  $1 (http $3)"
    else
        log "FAIL  $1 (expected $2, got $3)"
        FAILED=1
    fi
}

skip() {
    log "SKIP  $1：$2"
}

pyjson() { # 从 stdin 读 JSON，按点路径取值（不支持下表索引）
    python3 -c '
import json, sys
path = sys.argv[1].split(".")
try:
    cur = json.loads(sys.stdin.read())
    for key in path:
        cur = cur[key]
except Exception:
    print("")
else:
    print("" if cur is None else cur)
' "$1" 2>/dev/null || true
}

request() { # METHOD PATH [TOKEN] [JSON_BODY]
    local method="$1" path="$2" token="${3:-}" data="${4:-}"
    local args=(-sS -X "$method" -H 'Accept: application/json')
    [[ -n "$token" ]] && args+=(-H "Authorization: Bearer $token")
    [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' -d "$data")
    STATUS="$(curl "${args[@]}" -o "$TMP_DIR/body" -w '%{http_code}' "$BASE_URL$path" 2>"$TMP_DIR/curl.err")"
    BODY="$(cat "$TMP_DIR/body" 2>/dev/null || true)"
}

request_admin() { # METHOD PATH [TOKEN] [JSON_BODY] —— 带 admin cookie jar
    local method="$1" path="$2" token="${3:-}" data="${4:-}"
    local args=(-sS -X "$method" -H 'Accept: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR")
    [[ -n "$token" ]] && args+=(-H "Authorization: Bearer $token")
    [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' -d "$data")
    STATUS="$(curl "${args[@]}" -o "$TMP_DIR/body" -w '%{http_code}' "$BASE_URL$path" 2>"$TMP_DIR/curl.err")"
    BODY="$(cat "$TMP_DIR/body" 2>/dev/null || true)"
}

totp_now() { # base32 secret -> 6 位码（30s 窗口）
    python3 - "$1" <<'PY' 2>/dev/null || true
import base64, hashlib, hmac, struct, sys, time
secret = sys.argv[1].strip().replace(" ", "").upper()
key = base64.b32decode(secret + "=" * (-len(secret) % 8))
msg = struct.pack(">Q", int(time.time()) // 30)
digest = hmac.new(key, msg, hashlib.sha1).digest()
offset = digest[-1] & 0x0F
code = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000
print(f"{code:06d}")
PY
}

log "LKM 金路径验收"
log "base_url: $BASE_URL"
log "time(UTC): $STAMP"
log "要求: DEMO_USER/DEMO_PASSWORD，或 DEMO_REGISTER_EMAIL + AUTH_INTERNAL_TOKEN（后端开 dev-code）"

if [[ -z "$DEMO_USER" && ( -z "$DEMO_REGISTER_EMAIL" || -z "$AUTH_INTERNAL_TOKEN" ) ]]; then
    log ""
    log "缺少凭据：提供 DEMO_USER/DEMO_PASSWORD，或 DEMO_REGISTER_EMAIL + AUTH_INTERNAL_TOKEN"
    log "（后者需后端 LKM_DEV_CODE_SINK=1，仅 dev/local/test 允许）。"
    exit 2
fi

# ---------------------------------------------------------------- 1. 健康检查
section "1. 健康检查"
request GET "/api/v1/health"
check "GET /health" 200 "$STATUS"

# ---------------------------------------------------------------- 2. 注册
section "2. 注册"
REGISTERED_USER=""
REGISTERED_PASSWORD=""
if [[ -n "$DEMO_REGISTER_EMAIL" && -n "$AUTH_INTERNAL_TOKEN" ]]; then
    # 路径 1：真实验证码注册。邮箱用 plus-address 保唯一，避免重跑撞已存在账号。
    REG_STAMP="$(date +%s)"
    REG_EMAIL="$(python3 - "$DEMO_REGISTER_EMAIL" "$REG_STAMP" <<'PY'
import sys
base, suffix = sys.argv[1].lower(), sys.argv[2]
local, _, domain = base.partition("@")
print(f"{local}+golden{suffix}@{domain}")
PY
)"
    REG_USER="goldenreg$REG_STAMP"
    REG_PASSWORD="golden-pass-123456"
    request POST "/api/v1/auth/reg/normal" "" \
        "{\"username\":\"$REG_USER\",\"password\":\"$REG_PASSWORD\",\"email\":\"$REG_EMAIL\",\"apply_reason\":\"金路径自动注册\"}"
    check "POST /auth/reg/normal" 200 "$STATUS"
    TXN_ID="$(printf '%s' "$BODY" | pyjson data.txn_id)"
    if [[ -z "$TXN_ID" ]]; then
        log "FAIL  注册未返回 txn_id"
        FAILED=1
    else
        CONTACT_ENC="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$REG_EMAIL")"
        STATUS="$(curl -sS -H "Authorization: Bearer $AUTH_INTERNAL_TOKEN" \
            -o "$TMP_DIR/body" -w '%{http_code}' \
            "$BASE_URL/api/v1/auth/internal/dev-code?channel=email&contact=$CONTACT_ENC" 2>"$TMP_DIR/curl.err")"
        BODY="$(cat "$TMP_DIR/body" 2>/dev/null || true)"
        check "GET /auth/internal/dev-code" 200 "$STATUS"
        CODE="$(printf '%s' "$BODY" | pyjson code)"
        if [[ -n "$CODE" ]]; then
            request POST "/api/v1/auth/reg/normal/verify?txn_id=$TXN_ID&email_code=$CODE"
            check "POST /auth/reg/normal/verify" 200 "$STATUS"
            REG_ADMISSION="$(printf '%s' "$BODY" | pyjson data.admission_status)"
            if [[ "$REG_ADMISSION" == "pending" ]]; then
                log "PASS  验证码注册进入待审（LKM_ADMISSION_MODE=apply），内容路径改用 DEMO_USER"
            elif [[ -n "$(printf '%s' "$BODY" | pyjson data.access_token)" ]]; then
                REGISTERED_USER="$REG_USER"
                REGISTERED_PASSWORD="$REG_PASSWORD"
                log "PASS  验证码注册完成并发令牌"
            else
                log "FAIL  验证码注册既未发令牌也未进入待审"
                FAILED=1
            fi
        else
            log "FAIL  未取到 dev 验证码（确认后端 LKM_DEV_CODE_SINK=1 且 AUTH_INTERNAL_TOKEN 正确）"
            FAILED=1
        fi
    fi
else
    # 路径 2：未配置 dev-code，保留本地注册接口 smoke
    REG_USER="golden_$(date +%s)"
    request POST "/api/v1/auth/reg/local" "" "{\"username\":\"$REG_USER\",\"password\":\"golden-pass-123456\"}"
    check "POST /auth/reg/local" 200 "$STATUS"
    REG_ADMISSION="$(printf '%s' "$BODY" | pyjson data.admission_status)"
    if [[ "$REG_ADMISSION" == "pending" ]]; then
        log "PASS  注册进入待审（LKM_ADMISSION_MODE=apply）"
    elif [[ -n "$(printf '%s' "$BODY" | pyjson data.access_token)" ]]; then
        log "PASS  注册返回会话令牌"
    else
        log "FAIL  注册既未返回会话也未进入待审"
        FAILED=1
    fi
fi

# ---------------------------------------------------------------- 3. 登录
section "3. 登录"
LOGIN_USER="${REGISTERED_USER:-$DEMO_USER}"
LOGIN_PASSWORD="${REGISTERED_PASSWORD:-$DEMO_PASSWORD}"
if [[ -z "$LOGIN_USER" ]]; then
    log "FAIL  无可登录账号（注册进入待审且未提供 DEMO_USER）"
    exit 1
fi
request POST "/api/v1/auth/login/password" "" "{\"account\":\"$LOGIN_USER\",\"password\":\"$LOGIN_PASSWORD\"}"
check "POST /auth/login/password" 200 "$STATUS"
TOKEN="$(printf '%s' "$BODY" | pyjson data.access_token)"
if [[ -z "$TOKEN" ]]; then
    log "FAIL  登录未拿到 access_token，后续步骤中止"
    exit 1
fi
request GET "/api/v1/auth/me" "$TOKEN"
check "GET /auth/me" 200 "$STATUS"
ME_ID="$(printf '%s' "$BODY" | pyjson data.id)"
log "user_id: ${ME_ID:-<empty>}"

# ---------------------------------------------------------------- 4. 板块
section "4. 读取板块"
BOARD_ID="$DEMO_BOARD_ID"
if [[ -z "$BOARD_ID" ]]; then
    # 板块只读面只有 GraphQL（REST 无 list 端点）
    request POST "/graphql/v1" "" '{"query":"{ boards { id slug title } }"}'
    check "POST /graphql/v1 { boards }" 200 "$STATUS"
    BOARD_ID="$(printf '%s' "$BODY" | python3 -c '
import json,sys
try:
    rows = json.load(sys.stdin)["data"]["boards"]
    print(rows[0]["id"] if rows else "")
except Exception:
    print("")
' 2>/dev/null)"
else
    skip "GraphQL 板块查询" "已由 DEMO_BOARD_ID 指定"
fi
if [[ -z "$BOARD_ID" ]]; then
    log "FAIL  没有可用板块（设置 DEMO_BOARD_ID 或先建一个板块）"
    exit 1
fi
log "board_id: $BOARD_ID"

# ---------------------------------------------------------------- 5. 发帖
section "5. 发帖"
TITLE="金路径验收 $(date -u +%H:%M:%S)"
request POST "/api/v1/content/items" "$TOKEN" \
    "{\"content_type\":\"discussion\",\"board_id\":\"$BOARD_ID\",\"title\":\"$TITLE\",\"content\":\"自动化验收脚本生成的内容。\"}"
check "POST /content/items" 200 "$STATUS"
ITEM_ID="$(printf '%s' "$BODY" | pyjson data.id)"
log "item_id: ${ITEM_ID:-<empty>}"

# ---------------------------------------------------------------- 6. 评论
section "6. 评论（可选第二用户产生通知）"
if [[ -n "$DEMO_USER2" && -n "$DEMO_PASSWORD2" ]]; then
    request POST "/api/v1/auth/login/password" "" "{\"account\":\"$DEMO_USER2\",\"password\":\"$DEMO_PASSWORD2\"}"
    check "POST /auth/login/password (user2)" 200 "$STATUS"
    TOKEN2="$(printf '%s' "$BODY" | pyjson data.access_token)"
    COMMENT_TOKEN="$TOKEN2"
else
    skip "第二用户" "未设 DEMO_USER2/DEMO_PASSWORD2，用作者本人评论"
    COMMENT_TOKEN="$TOKEN"
fi
request POST "/api/v1/content/items/$ITEM_ID/comments" "$COMMENT_TOKEN" \
    "{\"content\":\"金路径验收评论\"}"
check "POST /content/items/{id}/comments" 200 "$STATUS"

# ---------------------------------------------------------------- 7. 文件上传
section "7. 上传待审文件"
printf 'golden path demo file %s\n' "$STAMP" >"$TMP_DIR/demo.txt"
STATUS="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
    -F "file=@$TMP_DIR/demo.txt;type=text/plain" \
    -F "description=golden-path" \
    -o "$TMP_DIR/body" -w '%{http_code}' "$BASE_URL/api/v1/files" 2>"$TMP_DIR/curl.err")"
BODY="$(cat "$TMP_DIR/body" 2>/dev/null || true)"
check "POST /files" 200 "$STATUS"
FILE_ID="$(printf '%s' "$BODY" | pyjson data.id)"
log "file_id: ${FILE_ID:-<empty>}"

# ---------------------------------------------------------------- 8. 管理员审核
section "8. 管理员审核（2FA step-up + 文件通过）"
if [[ -z "$DEMO_ADMIN" || -z "$DEMO_ADMIN_PASSWORD" ]]; then
    skip "管理员审核" "未设 DEMO_ADMIN/DEMO_ADMIN_PASSWORD"
else
    request_admin POST "/api/v1/admin/auth/login" "" \
        "{\"username\":\"$DEMO_ADMIN\",\"password\":\"$DEMO_ADMIN_PASSWORD\"}"
    check "POST /admin/auth/login" 200 "$STATUS"
    if [[ -n "$DEMO_TOTP_SECRET" ]]; then
        CODE="$(totp_now "$DEMO_TOTP_SECRET")"
        request_admin POST "/api/v1/admin/auth/2fa" "" "{\"code\":\"$CODE\"}"
        check "POST /admin/auth/2fa" 200 "$STATUS"
        STATUS="$(curl -sS -X POST -H "Accept: application/json" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
            --data-urlencode "status=approved" \
            --data-urlencode "review_comment=golden path" \
            -o "$TMP_DIR/body" -w '%{http_code}' \
            "$BASE_URL/api/v1/files/$FILE_ID/review" 2>"$TMP_DIR/curl.err")"
        BODY="$(cat "$TMP_DIR/body" 2>/dev/null || true)"
        check "POST /files/{id}/review" 200 "$STATUS"
        [[ "$(printf '%s' "$BODY" | pyjson data.status)" == "approved" ]] \
            && log "PASS  文件状态已通过" \
            || { log "FAIL  文件状态未变为 approved"; FAILED=1; }
    else
        skip "2FA step-up" "未设 DEMO_TOTP_SECRET，跳过审核（审核需 1h 内 2FA 信任）"
    fi
fi

# ---------------------------------------------------------------- 9. 通知
section "9. 通知查询"
request GET "/api/v1/notification/me?page=1&limit=20" "$TOKEN"
check "GET /notification/me" 200 "$STATUS"
TOTAL="$(printf '%s' "$BODY" | pyjson data.total)"
log "notifications total: ${TOTAL:-0}"
if [[ -n "$DEMO_USER2" ]]; then
    if [[ "${TOTAL:-0}" -ge 1 ]]; then
        log "PASS  第二用户评论已产生站内通知"
    else
        log "FAIL  未看到由评论产生的通知"
        FAILED=1
    fi
fi

# ---------------------------------------------------------------- 汇总
section "结果"
if [[ "$FAILED" -eq 0 ]]; then
    log "GOLDEN PATH: PASS"
else
    log "GOLDEN PATH: FAIL（详见上方 FAIL 行）"
fi
log "log file: $LOG_FILE"

exit "$FAILED"
