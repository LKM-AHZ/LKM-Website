#!/bin/sh
# Pulsar standalone 启动包装 —— compose 侧「无状态化」根治（2026-09-17，见路线图 §8 #32）。
#
# 为什么每次启动都清空数据目录
# --------------------------
# standalone 的 embedded bookie **每次进程启动随机取端口**，容器重启后 IP 也会变，而 ledger
# 元数据里记的正是 bookie 的 `IP:端口` → 旧 ledger 必然不可读 → broker 起不来并崩溃循环，
# 而 backend 与 9 个 worker 因 `depends_on: pulsar: service_healthy` 全部卡在 `Created`
# （本机已复发三次：2026-09-15 / 09-16 / 09-17）。三条「钉住 bookie 地址」的路——环境变量
# 前缀 `PULSAR_PREFIX_advertisedAddress`、CLI `--advertised-address/--bookkeeper-port`、改写
# `standalone.conf`——经 k8s 真机实测**全部无效**（standalone 启动器不读/覆盖这些值）。
# 故此处改用「每次启动都是干净 broker」从根上消除该故障类，与 k8s 清单的
# `emptyDir` + sidecar 是同一取舍（两侧语义一致）。
#
# 代价（务必知道）
# --------------
# pulsar 内「**已发布但未消费**」的消息会在每次重启时丢失。未发布事件仍在 PG `outbox_events`
# 里，由 relay 重投；消费端按 `event_id` 幂等去重，故业务侧可感知损失仅限该窗口。要真正持久，
# 应改用官方 Helm chart（多 bookie、显式端口）或托管服务，而不是在单机 compose 里自托管
# standalone —— 这也是 k8s 侧写下的结论（§8 #29）。
#
# 租户 / namespace
# ---------------
# 数据清空后 broker 是全新的，而 Pulsar 默认不允许自动建租户，故在本脚本内、broker 就绪后
# **幂等重建** `lkm` 租户与 `biz/auth/system` 三个 namespace（替代原先一次性 `pulsar-init`
# 服务：它只在首次 `up` 时跑一次，pulsar 重启后不会重跑，正是清卷后必须人工介入的原因）。
# 配套地，compose 里 pulsar 的 healthcheck 改为「验证 namespace 存在」，使 `healthy`
# 蕴含「初始化已完成」，依赖方（backend/auth/9 worker）据此启动即可安全订阅。
set -e

DATA_DIR=/pulsar/data
# 清空含隐藏项（. 开头的运行时状态）；`-f` 使 glob 不匹配时不报错
rm -rf "${DATA_DIR:?}"/* "${DATA_DIR:?}"/.[!.]* 2>/dev/null || true

# 前台语义：standalone 后台启动，脚本负责转发信号，保证 `docker stop` 能优雅关停 java 进程
# （否则要等 compose 的 stop 超时后被 SIGKILL）。
bin/pulsar standalone &
pulsar_pid=$!
trap 'kill -TERM "$pulsar_pid" 2>/dev/null || true' TERM INT

# 等 broker 就绪：探针用 `tenants list`（Admin REST 通即就绪；此时 namespace 尚未建，不能用它探）
attempt=0
until bin/pulsar-admin --admin-url http://127.0.0.1:8080 tenants list >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 90 ]; then
        echo "pulsar-entrypoint: broker 180s 内未就绪，跳过初始化（healthcheck 将持续失败）" >&2
        break
    fi
    sleep 2
done

if [ "$attempt" -lt 90 ]; then
    bin/pulsar-admin --admin-url http://127.0.0.1:8080 tenants create lkm || true
    for ns in biz auth system; do
        bin/pulsar-admin --admin-url http://127.0.0.1:8080 namespaces create "lkm/${ns}" || true
    done
    echo "pulsar-entrypoint: 干净启动完成，lkm 租户与 biz/auth/system namespace 已就绪"
fi

wait "$pulsar_pid"
