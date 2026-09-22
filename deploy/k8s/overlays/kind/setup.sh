#!/bin/sh
# 一键在 kind 上把全栈铺起来（本地验收用）。
#
# 为什么要单独写脚本而不是让 kind 节点自己拉镜像：本机出网要经代理，大镜像（pulsar、
# clickhouse）经代理会中途断流。宿主机 docker 已经有 compose 构建/拉取的全部镜像，
# 直接 `kind load docker-image` 注入节点最稳（不出网）。
#
# 用法：
#   sh deploy/k8s/overlays/kind/setup.sh              # 建集群 + 注入镜像 + apply + 等 Job
#   SKIP_CLUSTER=1 sh .../setup.sh                    # 集群已存在，只重铺清单
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
CLUSTER="${CLUSTER:-lkm}"
KUBECTL="${KUBECTL:-kubectl}"
KIND="${KIND:-kind}"
LOADRESTRICTOR="--load-restrictor LoadRestrictionsNone"

# 本地构建的镜像（不存在任何 registry，必须注入）。
# lkm-bot 属可选组件（base 里 replicas: 0）：镜像不存在时只提示，主栈验收不受影响；
# 要验收 bot 先 `docker compose --profile bot build lkmbot`。
LOCAL_IMAGES="lkm-service:latest lkm-official-website:latest lkm-official-static:latest"
OPTIONAL_IMAGES="lkm-bot:latest"
# 中间件镜像：宿主机 docker 已有 compose 拉过的那份，注入即免出网
# 主库用 TimescaleDB 版（hypertable）；prefect 自带的 prefect-postgres 仍是 postgres:16-alpine，
# 故两者都要注入。
INFRA_IMAGES="apachepulsar/pulsar:3.3.0 timescale/timescaledb:latest-pg16 postgres:16-alpine redis:7-alpine \
minio/minio:latest clickhouse/clickhouse-server:24.8-alpine timberio/vector:0.43.0-alpine \
otel/opentelemetry-collector-contrib:0.109.0 apache/apisix:3.9.0-debian alpine:3.19 nginx:1.27-alpine"

cd "$ROOT"

if [ -z "${SKIP_CLUSTER:-}" ]; then
    if "$KIND" get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
        echo "== kind 集群 $CLUSTER 已存在，跳过创建"
    else
        echo "== 创建 kind 集群 $CLUSTER"
        "$KIND" create cluster --config "$HERE/kind-cluster.yaml" --wait 120s
    fi
fi

# 集群名一致性核对：kind-cluster.yaml 里写死 `name: lkm`，而 kind create 以配置文件为准 ——
# 用 CLUSTER=xxx 覆盖时创建出来的仍是配置里那个名字，NODE=${CLUSTER}-control-plane 就会指向
# 不存在的节点（load-image.sh 的 docker exec 直接失败）。SKIP_CLUSTER 路径同样受这道检查保护。
if ! "$KIND" get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    echo "!! kind 集群 $CLUSTER 不存在（kind-cluster.yaml 的 name 与 CLUSTER 不一致？）" >&2
    exit 1
fi

# 镜像注入交给 load-image.sh（按平台裁剪 OCI 索引；原因见该脚本头部）
# 节点名从集群实际查（kind get nodes），别再按 CLUSTER 猜
NODE="${NODE:-$("$KIND" get nodes --name "$CLUSTER" 2>/dev/null | head -n 1)}"
[ -n "$NODE" ] || NODE="${CLUSTER}-control-plane"
export NODE

echo "== 注入镜像到节点（跳过缺失的）"
present=""
missing=""
for img in $LOCAL_IMAGES $OPTIONAL_IMAGES $INFRA_IMAGES; do
    if docker image inspect "$img" >/dev/null 2>&1; then
        present="$present $img"
    else
        missing="$missing $img"
    fi
done
[ -n "$present" ] && sh "$HERE/load-image.sh" $present
# 必需镜像缺失 → 节点会走「大镜像经代理拉取中途断流」那条已知不可靠的路（见文件头），
# 得到的是半成品集群，而脚本还打印成功。可选组件（lkm-bot）缺失只提示。
missing_required=""
for img in $missing; do
    case " $OPTIONAL_IMAGES " in *" $img "*) ;; *) missing_required="$missing_required $img" ;; esac
done
if [ -n "$missing_required" ]; then
    echo "!! 以下必需镜像宿主机不存在：$missing_required" >&2
    echo "!! 请先 docker pull / docker compose build 后重跑（节点经代理拉取不可靠）" >&2
    exit 1
fi
if [ -n "$missing" ]; then
    echo "!! 以下可选镜像宿主机不存在，将由节点自行拉取：$missing" >&2
fi

echo "== 建命名空间（Secret/TLS 要先落进来，故先于 apply -k）"
"$KUBECTL" apply -f deploy/k8s/base/namespace.yaml

echo "== 生成 Secret 与 TLS 证书"
# POSIX sh 没有 pipefail：生成器失败时管道退出码由 kubectl 决定，半份文档还会被 apply 进去，
# 后续 Pod 因缺 Secret 反复 CrashLoop。故先捕获输出、显式校验非空。
for gen in deploy/k8s/gen-secret.sh deploy/k8s/gen-tls.sh; do
    if ! out="$(sh "$gen")" || [ -z "$out" ]; then
        echo "!! $gen 生成失败（或以空输出退出），终止" >&2
        exit 1
    fi
    printf '%s\n' "$out" | "$KUBECTL" apply -f -
done

echo "== 应用清单"
# 用 `kustomize | apply -f -` 而非 `apply -k`：后者不接受 --load-restrictor，
# 而清单引用了 base 目录之外的既有资产（见 deploy/k8s/base/kustomization.yaml 顶部）
"$KUBECTL" kustomize deploy/k8s/overlays/kind $LOADRESTRICTOR | "$KUBECTL" apply -f -

# 注：Pulsar 的租户/namespace 由 **Pod 内的 sidecar** 建（Pod 重建即重跑，自愈），
# 不再是 Job —— 故这里只需等 MinIO 建桶这一个一次性 Job。
echo "== 等一次性 Job（建 MinIO 桶）"
if ! "$KUBECTL" -n lkm wait --for=condition=complete job/minio-init --timeout=10m; then
    echo "!! minio-init Job 未在超时内完成，查日志：$KUBECTL -n lkm logs job/minio-init" >&2
    exit 1
fi

echo "== 让先于 Job 起来、可能已崩溃重启的应用 Pod 重连一次"
# 只重启应用层（component ∈ app/frontend/worker）：中间件（component=infra）不依赖 minio-init
# Job，重启它们只会拖长就绪时间、并在数据面刚拉起时制造抖动
"$KUBECTL" -n lkm rollout restart deployment -l 'app.kubernetes.io/component in (app,frontend,worker)'

echo "== 等待 rollout"
# 从集群枚举而不是写死名单：清单增删 Deployment 时等待循环不会悄悄漏等
failed=""
for d in $("$KUBECTL" -n lkm get deploy -o jsonpath='{.items[*].metadata.name}'); do
    if ! "$KUBECTL" -n lkm rollout status "deploy/$d" --timeout=10m; then
        failed="$failed $d"
    fi
done
if [ -n "$failed" ]; then
    echo "!! 以下 Deployment 未在超时内 rollout 完成：$failed" >&2
    exit 1
fi

echo
echo "== 完成。查看："
echo "   $KUBECTL -n lkm get pods"
echo "   冒烟：SMOKE_HTTP_PORT=8080 SMOKE_HTTPS_PORT=8443 sh deploy/apisix/smoke.sh 127.0.0.1"
