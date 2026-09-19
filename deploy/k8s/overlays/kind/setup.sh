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

# 四个本地构建的镜像（不存在任何 registry，必须注入）。
# lkm-bot 属可选组件（base 里 replicas: 0）：镜像不存在时脚本只提示「由节点自行拉取」，
# 主栈验收不受影响；要验收 bot 先 `docker compose --profile bot build lkmbot`。
LOCAL_IMAGES="lkm-service:latest lkm-official-website:latest lkm-official-static:latest lkm-bot:latest"
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

# 镜像注入交给 load-image.sh（按平台裁剪 OCI 索引；原因见该脚本头部）
NODE="${CLUSTER}-control-plane"
export NODE

echo "== 注入镜像到节点（跳过缺失的）"
present=""
missing=""
for img in $LOCAL_IMAGES $INFRA_IMAGES; do
    if docker image inspect "$img" >/dev/null 2>&1; then
        present="$present $img"
    else
        missing="$missing $img"
    fi
done
[ -n "$present" ] && sh "$HERE/load-image.sh" $present
if [ -n "$missing" ]; then
    echo "!! 以下镜像宿主机不存在，将由节点自行拉取：$missing" >&2
fi

echo "== 建命名空间（Secret/TLS 要先落进来，故先于 apply -k）"
"$KUBECTL" apply -f deploy/k8s/base/namespace.yaml

echo "== 生成 Secret 与 TLS 证书"
sh deploy/k8s/gen-secret.sh | "$KUBECTL" apply -f -
sh deploy/k8s/gen-tls.sh | "$KUBECTL" apply -f -

echo "== 应用清单"
# 用 `kustomize | apply -f -` 而非 `apply -k`：后者不接受 --load-restrictor，
# 而清单引用了 base 目录之外的既有资产（见 deploy/k8s/base/kustomization.yaml 顶部）
"$KUBECTL" kustomize deploy/k8s/overlays/kind $LOADRESTRICTOR | "$KUBECTL" apply -f -

# 注：Pulsar 的租户/namespace 由 **Pod 内的 sidecar** 建（Pod 重建即重跑，自愈），
# 不再是 Job —— 故这里只需等 MinIO 建桶这一个一次性 Job。
echo "== 等一次性 Job（建 MinIO 桶）"
"$KUBECTL" -n lkm wait --for=condition=complete job/minio-init --timeout=10m || true

echo "== 让先于 Job 起来、可能已崩溃重启的应用 Pod 重连一次"
"$KUBECTL" -n lkm rollout restart deployment

echo "== 等待 rollout"
for d in backend auth astro static apisix; do
    "$KUBECTL" -n lkm rollout status "deploy/$d" --timeout=10m || true
done

echo
echo "== 完成。查看："
echo "   $KUBECTL -n lkm get pods"
echo "   冒烟：SMOKE_HTTP_PORT=8080 SMOKE_HTTPS_PORT=8443 sh deploy/apisix/smoke.sh 127.0.0.1"
