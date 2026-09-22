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
# 域名清单须与网关的 APISIX_{COMMUNITY,OFFICIAL}_DOMAINS 一致；
# 少一个域名的表现是该域名在 render.sh 里退回自签占位（不致命，但浏览器会报证书不受信）。
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

# NS 会被直接内插进 YAML：含换行/冒号的值能改写清单、甚至往 Secret 里塞额外字段
case "$NS" in
    ''|*[!a-z0-9-]*|-*|*-)
        echo "非法 NAMESPACE：$NS（只允许小写字母/数字/连字符，且首尾不得为连字符）" >&2
        exit 1
        ;;
esac
if [ "${#NS}" -gt 63 ]; then
    echo "非法 NAMESPACE：$NS（长度 ${#NS} 超过 63）" >&2
    exit 1
fi

command -v openssl >/dev/null 2>&1 || { echo "需要本机 openssl" >&2; exit 1; }

# 输出里含 RSA 私钥：非终端（管道/重定向/CI 日志）时提醒落点可见性
if [ ! -t 1 ]; then
    echo "[gen-tls] 注意：stdout 不是终端，输出含 RSA 私钥，请确认落点（日志/文件权限）的可见性" >&2
fi

# 私钥/临时证书只落在 mktemp 目录（本身 700），再显式收紧 umask 兜底
umask 077

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

{
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: lkm-tls\n  namespace: %s\n  labels:\n    app.kubernetes.io/part-of: lkm\ntype: Opaque\nstringData:\n' "$NS"
    # 关 glob：DOMAINS 里的 `*.lkm-ahz.ltd` 这类通配域否则会被当前目录的同名文件展开
    set -f
    for d in $DOMAINS; do
        case "$d" in
            '')
                echo "空域名" >&2
                exit 1
                ;;
            # 通配域在本脚本里根本用不了（`*` 不是合法 K8s Secret 键名，`*.x:` 也不是合法 YAML 键
            # ——会被当锚点别名，清单直接解析失败），显式拒绝比生成坏 YAML 好
            *'*'*)
                echo "不支持通配域：$d（Secret 键名不允许 *，YAML 键亦不能以 * 开头）" >&2
                exit 1
                ;;
            # $d 会变成临时文件名与 Secret 键名：限定字符集，挡住 `/`、`..`、换行造成的路径逃逸/YAML 注入
            *[!a-z0-9.-]*|*..*|.*|*.)
                echo "非法域名：$d" >&2
                exit 1
                ;;
        esac
        # SAN：已带 www 前缀的域不能再加一层（render.sh 的 hosts 列表本就含 www.<域>，
        # 故普通域补 www 变体是刻意的；但 www.www.x 这种非法名会让 openssl 直接失败）
        case "$d" in
            www.*) san="DNS:$d" ;;
            *)     san="DNS:$d,DNS:www.$d" ;;
        esac
        # 失败时把 openssl 的 stderr 原样重放（旧版本无 -addext、非法 DAYS/域名的真实原因都在里面），
        # 成功时吞掉：openssl 把进度点也写在 stderr 上，直通会刷屏
        if ! openssl req -x509 -nodes -newkey rsa:2048 -days "$DAYS" \
            -keyout "$TMP/$d.key" -out "$TMP/$d.crt" \
            -subj "/CN=$d" -addext "subjectAltName=$san" >/dev/null 2>"$TMP/$d.err"; then
            echo "openssl 生成证书失败：$d" >&2
            cat "$TMP/$d.err" >&2
            exit 1
        fi
        echo "  ${d}_fullchain.pem: |"
        sed 's/^/    /' "$TMP/$d.crt"
        echo "  ${d}_privkey.pem: |"
        sed 's/^/    /' "$TMP/$d.key"
    done
    set +f
}

trap - EXIT
rm -rf "$TMP"
