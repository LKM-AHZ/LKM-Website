#!/bin/sh
# 告警投递配置渲染器：把 alertmanager.yml.tpl 的 __ALERT_RECEIVER_BODY__ 展开成实值。
#
# 与 deploy/apisix/render.sh 同源的「模板 + 运行时展开」模式（为什么不静态提交见 tpl 头部）。
# compose 与 k8s 跑的是**本文件同一份**：compose 用一次性容器 alertmanager-render，
# k8s 用 initContainer 写 emptyDir——两处都不留配置副本（第二真相源）。
#
# 产物属主提醒：输出写在宿主 bind 目录，属主是**容器内用户**。rootless/usrns-remap 的
#   Docker 下宿主机上会显示为 nobody（或 subuid），直接 `rm` 会 permission denied。
#   清理方式（与 apisix-render 的 rendered/ 同款问题）：
#     docker run --rm -v "$PWD/deploy/alertmanager/rendered:/out" alpine:3.19 rm -rf /out/*
#   该目录已 gitignore，残留不影响仓库。
#
# 未配置 LKM_ALERT_WEBHOOK_URL 时的行为：渲染出「只有 name 的接收器」。
#   Alertmanager 允许空接收器（no-op），因此告警仍进 Alertmanager（UI/amtool 可见、
#   可打 silence），只是不往外投递。
#   为什么不让它启动失败：告警落不了地是**降级**（告警仍在算、仍可在 UI 看到），
#   容器起不来是**故障**（连 UI 都没了，且会让整套 monitoring profile 起不来）。
#   降级比故障更容易被发现和补救，故这里选择降级 + stderr 大声警告。
set -eu

SRC="${ALERTMANAGER_SRC:-/src/alertmanager.yml.tpl}"
OUT="${ALERTMANAGER_OUT:-/out/alertmanager.yml}"
URL="${ALERT_WEBHOOK_URL:-}"

mkdir -p "$(dirname "$OUT")"

if [ -n "$URL" ]; then
    # YAML 单引号串里 ' 的转义方式是写成 ''。不转义会让含引号的 URL 渲染出非法配置，
    # 而那时 alertmanager 起不来、错误信息离成因很远——故在源头处理。
    ESCAPED=$(printf '%s' "$URL" | sed "s/'/''/g")
    BODY="    webhook_configs:
      - url: '$ESCAPED'
        send_resolved: true
        max_alerts: 0"
    echo "alertmanager: webhook 接收器已渲染 -> $OUT"
else
    BODY="    # LKM_ALERT_WEBHOOK_URL 未配置：本接收器不投递任何通知。
    # 告警仍可在 Alertmanager UI（:9093）或 amtool 查看。配置方法见 DEPLOYMENT.md「告警投递」。"
    echo "警告：LKM_ALERT_WEBHOOK_URL 未配置 —— 告警不会通知任何人（仅 UI 可见）" >&2
fi

# 整行匹配占位符（占位符独占一行），用 ENVIRON 传多行值：
# POSIX awk 的 -v 会解释值里的反斜杠转义，ENVIRON 是字节透明的，busybox/awk 行为一致。
BODY="$BODY" awk '
    $0 == "__ALERT_RECEIVER_BODY__" { print ENVIRON["BODY"]; next }
    { print }
' "$SRC" > "$OUT.tmp"

# 渲染自检：产物必须非空且含 receivers（占位符被误删/模板被写坏时早失败，
# 而不是把坏配置喂给 alertmanager）。
if [ ! -s "$OUT.tmp" ] || ! grep -q '^receivers:' "$OUT.tmp"; then
    echo "错误：渲染产物缺少 receivers 段，保留上一版配置" >&2
    rm -f "$OUT.tmp"
    exit 1
fi

# 原子替换：渲染中途失败绝不留下半截配置。
mv "$OUT.tmp" "$OUT"
