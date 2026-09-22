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

# bin/pulsar 与 bin/pulsar-admin 都是相对路径，脚本原本隐含依赖「CWD == PULSAR_HOME」：
# 镜像 WORKDIR 或调用方式一变（compose 覆盖 working_dir、被别处 source），清空数据的绝对路径
# 仍会生效，而启动/探测全失败，排查成本很高。显式进目录。
PULSAR_HOME="${PULSAR_HOME:-/pulsar}"
cd "$PULSAR_HOME"

DATA_DIR=/pulsar/data
# 清空含隐藏项：三个 glob 分别覆盖普通项、`.foo` 与 `..foo`（`.[!.]*` 漏掉后者）；
# `-f` 使不匹配的字面量不报错。删除失败**不再静默**——残留旧 ledger 元数据会精确复现
# 上面描述的 `Failed to read entry` 崩溃循环，故交给 set -e 终止容器（fail fast 优于带脏数据启动）。
rm -rf "${DATA_DIR:?}"/* "${DATA_DIR:?}"/.[!.]* "${DATA_DIR:?}"/..?*

# 前台语义：standalone 后台启动，脚本负责转发信号，保证 `docker stop` 能优雅关停 java 进程
# （否则要等 compose 的 stop 超时后被 SIGKILL）。
bin/pulsar standalone &
pulsar_pid=$!
stopping=0
trap 'stopping=1; kill -TERM "$pulsar_pid" 2>/dev/null || true' TERM INT

# 等 broker 就绪：探针用 `tenants list`（Admin REST 通即就绪；此时 namespace 尚未建，不能用它探）
# 上限 = MAX_ATTEMPTS × 2s = 180s
MAX_ATTEMPTS=90
attempt=0
until bin/pulsar-admin --admin-url http://127.0.0.1:8080 tenants list >/dev/null 2>&1; do
    # broker 已崩溃 → 不必再白等满 180s
    if ! kill -0 "$pulsar_pid" 2>/dev/null; then
        if [ "$stopping" = 1 ]; then
            exit 0   # 收到 TERM 后进程退出属正常关停，别报成启动失败
        fi
        echo "pulsar-entrypoint: pulsar 进程已退出，启动失败" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        # 以非 0 退出：broker 活着但 Admin 始终不可用（healthcheck 永远红）时，
        # 原样阻塞在 wait 会让编排层完全无感
        echo "pulsar-entrypoint: broker 180s 内未就绪，初始化未执行" >&2
        kill -TERM "$pulsar_pid" 2>/dev/null || true
        wait "$pulsar_pid" 2>/dev/null || true
        exit 1
    fi
    sleep 2
done

# create 保留 `|| true`（每次启动都会重跑，已存在时报错属正常），但**不能就此收工**：
# 它同样会吞掉鉴权失败/admin-url 写错这类真实错误，然后照样打印「已就绪」，而 compose 的
# healthcheck 正是校验 namespace 存在 —— 失败会拖成依赖方无限等待、日志还误导人。
# 故 create 之后再查一次「资源确实在不在」：不在就报错并非 0 退出（在=幂等，放过）。
bin/pulsar-admin --admin-url http://127.0.0.1:8080 tenants create lkm || true
bin/pulsar-admin --admin-url http://127.0.0.1:8080 tenants list 2>/dev/null | grep -qx lkm || {
    echo "pulsar-entrypoint: 租户 lkm 不存在（create 未成功、且重查也没有）" >&2
    exit 1
}
for ns in biz auth system; do
    bin/pulsar-admin --admin-url http://127.0.0.1:8080 namespaces create "lkm/${ns}" || true
done
# namespaces list 一次就够（pulsar-admin 是 JVM 客户端，单次约 12s，别放进循环重复调）
_ns_list="$(bin/pulsar-admin --admin-url http://127.0.0.1:8080 namespaces list lkm 2>/dev/null || true)"
for ns in biz auth system; do
    printf '%s\n' "$_ns_list" | grep -qx "lkm/${ns}" || {
        echo "pulsar-entrypoint: namespace lkm/${ns} 不存在（create 未成功、且重查也没有）" >&2
        exit 1
    }
done
echo "pulsar-entrypoint: 干净启动完成，lkm 租户与 biz/auth/system namespace 已就绪"

wait "$pulsar_pid"
