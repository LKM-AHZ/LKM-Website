#!/bin/sh
# 从根仓库 .env 生成 k8s Secret（不落盘、不进 git）。
#
# 为什么用脚本而不是提交一份 Secret YAML：Secret 的键集与 compose 的变量名高度重叠但
# 并非一一对应（如 LKM_S3_SECRET_KEY 只是 MINIO_ROOT_PASSWORD 的别名），提交一份 YAML
# 会随之腐烂成「第二真相源」。脚本从 .env 派生，.env 仍是唯一来源。
#
# 用法：
#   sh deploy/k8s/gen-secret.sh                     # 输出到 stdout，人工管道 apply
#   sh deploy/k8s/gen-secret.sh | kubectl apply -f -
#   NAMESPACE=lkm sh deploy/k8s/gen-secret.sh | kubectl -n lkm apply -f -
#   # 先干跑自检（能挡住 YAML 转义/键名类错误，真正 apply 前建议跑一次）：
#   sh deploy/k8s/gen-secret.sh | kubectl apply --dry-run=client -f -
#
# 输出含明文密钥：要落盘请自己收紧权限（重定向文件是**父 shell** 建的，脚本内 umask 管不到）：
#   umask 077 && sh deploy/k8s/gen-secret.sh > k8s-secret.yaml
#
# 前置：根目录 .env 需已按 .env.example 配齐（三个主密钥、POSTGRES_PASSWORD、
# MINIO_ROOT_PASSWORD、LKM_AUTH_HTTP_TOKEN 必填；下面 require() 会逐个断言）。
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
NS="${NAMESPACE:-lkm}"

if [ ! -f "$ENV_FILE" ]; then
    echo "找不到 $ENV_FILE —— 请先从 .env.example 复制并填值" >&2
    exit 1
fi

# 只读取需要的键；不 source 整个 .env（避免 .env 里任意命令被执行）。
get() {
    # get KEY [default]；取 .env 中最后一次赋值，去掉行内注释与首尾空白/引号
    key="$1"
    def="${2-}"
    line="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$ENV_FILE" | tail -1)"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$line" in
        # 整段被对称引号包裹 → 引号内一律是值，`#` 不剥成注释（`"abc#def"` 的 `#` 合法）
        \"*\") line="$(printf '%s' "$line" | sed 's/^"//; s/"$//')" ;;
        \'*\') line="$(printf '%s' "$line" | sed "s/^'//; s/'\$//")" ;;
        *)
            # 未加引号：只有「空白 + #」才是行内注释（`abc#def` 是值，与 compose 的 .env 口径一致）
            line="$(printf '%s' "$line" | sed 's/[[:space:]][[:space:]]*#.*$//; s/[[:space:]]*$//')"
            # 剥完注释后若剩下 `"值"` 形式，再去一次引号（`KEY="v" # 注释` 这种写法）
            case "$line" in
                \"*\") line="$(printf '%s' "$line" | sed 's/^"//; s/"$//')" ;;
                \'*\') line="$(printf '%s' "$line" | sed "s/^'//; s/'\$//")" ;;
            esac
            ;;
    esac
    if [ -z "$line" ]; then printf '%s' "$def"; else printf '%s' "$line"; fi
}

# YAML 双引号标量转义：不转义时值里的 `\` 会被 YAML 当转义引导符、`"` 会提前闭合标量，
# 写出的 Secret 会被静默改写（甚至 kubectl 解析失败）
yaml_dq() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# 取 .env 值 → YAML 标量内容（get 的输出只有一行，故无需处理换行）
get_dq() { yaml_dq "$(get "$1" "${2-}")"; }

# 可选组件凭据：缺配置时先告警再落回占位值。占位值是「看起来像密钥」的字符串，
# 静默写进集群 Secret 会让 change-me 变成线上真实凭据，故必须留痕
get_dq_opt() {
    v="$(get "$1")"
    if [ -n "$v" ]; then
        yaml_dq "$v"
    else
        echo "[gen-secret] 警告：$1 未在 .env 配置，将写入占位值 '$2'（启用该组件前请改为强随机）" >&2
        yaml_dq "$2"
    fi
}

require() {
    if [ -z "$(get "$1")" ]; then
        echo "必填项 $1 在 $ENV_FILE 中缺失或为空" >&2
        exit 1
    fi
}

for k in LKM_JWT_SECRET LKM_TOTP_ENCRYPTION_KEY LKM_VERIFICATION_CODE_PEPPER \
         LKM_AUTH_HTTP_TOKEN POSTGRES_PASSWORD MINIO_ROOT_PASSWORD; do
    require "$k"
done

PG_USER="$(get POSTGRES_USER lkm)"
MINIO_USER="$(get MINIO_ROOT_USER lkmadmin)"

# RS256 密钥 PEM（由 deploy/jwt/gen-keys.sh 生成；可用 *_PATH 覆盖）。
JWT_PUB_FILE="${JWT_PUBLIC_KEY_PATH:-$ROOT/deploy/jwt/keys/jwt-public.pem}"
JWT_PRIV_FILE="${JWT_PRIVATE_KEY_PATH:-$ROOT/deploy/jwt/keys/jwt-private.pem}"

jwt_public_block() {
    [ -f "$JWT_PUB_FILE" ] || return 0
    printf '  LKM_JWT_PUBLIC_KEY: |\n'
    sed 's/^/    /' "$JWT_PUB_FILE"
}

# Secret 的键集 = 应用/中间件消费的全部敏感项。POSTGRES_PASSWORD 与 LKM_DB_PASSWORD 等
# 同值多键是刻意的：让各 Pod 直接 envFrom 这一张表即可，不必在 Deployment 里到处写
# secretKeyRef 做逐键映射（少一层易漏的间接）。
# 输出含明文密钥：非终端（管道/重定向）时提醒一句 —— 重定向文件由父 shell 以调用方的
# umask 创建，脚本内 umask 对它无效（本脚本自身也不建任何文件），故不写 umask 以免给出错觉
if [ ! -t 1 ]; then
    echo "[gen-secret] 注意：stdout 不是终端，输出含明文密钥；重定向到文件请自行 umask 077" >&2
fi

cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: lkm-secrets
  namespace: $NS
  labels:
    app.kubernetes.io/part-of: lkm
type: Opaque
stringData:
  LKM_JWT_SECRET: "$(get_dq LKM_JWT_SECRET)"
  LKM_TOTP_ENCRYPTION_KEY: "$(get_dq LKM_TOTP_ENCRYPTION_KEY)"
  LKM_VERIFICATION_CODE_PEPPER: "$(get_dq LKM_VERIFICATION_CODE_PEPPER)"
  LKM_AUTH_HTTP_TOKEN: "$(get_dq LKM_AUTH_HTTP_TOKEN)"
  LKM_GITHUB_CLIENT_SECRET: "$(get_dq LKM_GITHUB_CLIENT_SECRET)"
  POSTGRES_USER: "$(yaml_dq "$PG_USER")"
  POSTGRES_PASSWORD: "$(get_dq POSTGRES_PASSWORD)"
  LKM_DB_PASSWORD: "$(get_dq POSTGRES_PASSWORD)"
  LKM_AUTH_DB_PASSWORD: "$(get_dq POSTGRES_PASSWORD)"
  MINIO_ROOT_USER: "$(yaml_dq "$MINIO_USER")"
  MINIO_ROOT_PASSWORD: "$(get_dq MINIO_ROOT_PASSWORD)"
  LKM_S3_ACCESS_KEY: "$(yaml_dq "$MINIO_USER")"
  LKM_S3_SECRET_KEY: "$(get_dq MINIO_ROOT_PASSWORD)"
  # 检索引擎：未配则不出值，search.yaml 的 secretKeyRef 是 optional=true
  SEARCH_MEILI_API_KEY: "$(get_dq LKM_SEARCH_MEILI_API_KEY)"
  CLICKHOUSE_USER: "$(get_dq CLICKHOUSE_USER lkm)"
  CLICKHOUSE_PASSWORD: "$(get_dq_opt CLICKHOUSE_PASSWORD change-me-clickhouse)"
  PREFECT_DB_PASSWORD: "$(get_dq_opt PREFECT_DB_PASSWORD change-me-prefect-db)"
  INFISICAL_DB_PASSWORD: "$(get_dq_opt INFISICAL_DB_PASSWORD change-me-infisical-db)"
  INFISICAL_ENCRYPTION_KEY: "$(get_dq_opt INFISICAL_ENCRYPTION_KEY change-me)"
  INFISICAL_AUTH_SECRET: "$(get_dq_opt INFISICAL_AUTH_SECRET change-me)"
  # bot 面板初始密码（可选组件）。**不 require**：未配就不出这个键，bot 的
  # secretKeyRef 是 optional=true → Pod 照常起，面板自生成随机密码打到日志。
  LKM_BOT_DASHBOARD_PASSWORD: "$(get_dq LKM_BOT_DASHBOARD_PASSWORD)"
$(jwt_public_block)
YAML

# ── RS256/JWKS（批 5）：公钥并入 lkm-secrets（非机密，各 Pod 都要能验签）；私钥单独成
#    Secret `lkm-jwt-signing`，**只**给 auth（签发方）。未生成密钥时两者都不出现：
#    应用沿用 HS256、网关不做 JWT 校验——与 compose 的「留空即降级」同一口径。
if [ -f "$JWT_PRIV_FILE" ] && [ -f "$JWT_PUB_FILE" ]; then
    # 两个都必须在：只有私钥时签发/验签会错配（auth 会以 RS256 签发，而 lkm-secrets 里没有
    # LKM_JWT_PUBLIC_KEY，网关与 backend 无从验签），故此时宁可什么都不发，见下方警告
    # 多文档须显式 `---` 分隔，否则它会被并进上一个文档（键重复 → kubectl 报错）
    cat <<YAML

---
apiVersion: v1
kind: Secret
metadata:
  name: lkm-jwt-signing
  namespace: $NS
  labels:
    app.kubernetes.io/part-of: lkm
type: Opaque
stringData:
  LKM_JWT_PRIVATE_KEY: |
$(sed 's/^/    /' "$JWT_PRIV_FILE")
YAML
fi

if [ ! -f "$JWT_PUB_FILE" ]; then
    if [ -f "$JWT_PRIV_FILE" ]; then
        # 只有私钥：绝不发 lkm-jwt-signing（否则 auth 会以 RS256 签发，而 lkm-secrets 里没有
        # 公钥 → 网关/backend 无从验签），并明确说清原因，别让上面的提示自相矛盾
        echo "[gen-secret] 警告：只有私钥没有公钥（缺 $JWT_PUB_FILE）——不生成 lkm-jwt-signing，" >&2
        echo "[gen-secret]        否则 auth 用 RS256 签发而验签方拿不到公钥。请重跑 deploy/jwt/gen-keys.sh" >&2
    else
        echo "[gen-secret] 未找到 $JWT_PUB_FILE：未启用 RS256（网关不做 JWT 验签）" >&2
    fi
fi
