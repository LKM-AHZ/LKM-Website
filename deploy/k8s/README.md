# LKM 全栈 k8s 清单（Kustomize）

把 `docker-compose.yml` 描述的整栈（网关 + 应用层 + 有状态中间件）搬到 Kubernetes。
清单与 compose **逐服务对应**，不是另一套架构；差异只在「compose 有而 k8s 没有」的机制上，
每一处都在下面「与 compose 的差异」列明。

## 目录

```
deploy/k8s/
├── gen-secret.sh              # 从根 .env 派生 Secret（不落盘、不进 git）
├── gen-tls.sh                 # 生成网关 TLS Secret（自签；生产可导入正式证书）
├── base/                      # 全栈清单（namespace lkm）
│   ├── kustomization.yaml     # 用 configMapGenerator 直接引用仓库既有部署资产
│   ├── app-config.yaml        # 非敏感配置（三张表：公共 / AUTH 库 / 分析+编排）
│   ├── infra/                 # postgres redis pulsar minio clickhouse vector otel prefect
│   ├── app/                   # backend auth workers(×10) frontend(astro+static)
│   └── gateway/               # apisix(+render init/sidecar) acme-webroot 网关配置
└── overlays/
    ├── kind/                  # 本地单节点验收（NodePort + 站点身份）
    └── prod/                  # 生产模板（域名 / LB / 站点身份）
```

## 单一来源：不复制仓库里的部署资产

`configMapGenerator` 直接引用 **base 目录之外**的既有文件，compose 与 k8s 共用同一份：

| 资产 | 来源文件 | 谁在用 |
|---|---|---|
| APISIX 路由模板 | `deploy/apisix/apisix.yaml` | compose 与 k8s |
| APISIX 自身配置模板 | `deploy/apisix/config.yaml` | 同上 |
| 渲染脚本 | `deploy/apisix/render.sh` | 同上 |
| ACME responder 配置 | `deploy/apisix/acme-webroot.conf` | 同上 |
| PostgreSQL 首启脚本 | `deploy/initdb/01-auth-db.sh` | 同上 |
| ClickHouse DDL | `deploy/clickhouse/init.sql` | 同上 |
| OTel Collector 配置 | `deploy/otel/otel-collector.yaml` | 同上 |

因此构建时**必须**放开 kustomize 的加载限制。注意 `kubectl apply -k` **不接受**
该标志（只有 `kubectl kustomize` 接受），所以统一走「先渲染、再 apply」：

```sh
kubectl kustomize deploy/k8s/overlays/kind --load-restrictor LoadRestrictionsNone \
  | kubectl apply -f -
```

本地验收可直接用封装好的脚本：`sh deploy/k8s/overlays/kind/setup.sh`。

> 两处**刻意不复用**的文件：`infra/vector.toml`（k8s 读 CRI 日志，compose 读 docker
> json-file，日志格式不同故 source 段必然不同）与 `infra/vector.yaml`（DaemonSet vs 单容器）。
> 解析意图与 sink 语义保持一致，差异已在《执行路线图》§8 登记。

## 部署

### 1. 前置：命名空间、Secret 与证书

Secret 必须落在目标命名空间里，故命名空间要先存在（清单里也含 Namespace，但那在下一步）：

```sh
kubectl apply -f deploy/k8s/base/namespace.yaml

# 应用密钥（三个主密钥 / PG 密码 / MinIO 密码 / AUTH seam token …）——从根 .env 派生
sh deploy/k8s/gen-secret.sh | kubectl apply -f -

# 网关 TLS 证书（本地/验收用自签；生产换正式证书，见脚本注释）
sh deploy/k8s/gen-tls.sh | kubectl apply -f -
```

> 首次仍需先建命名空间——`deploy/k8s/overlays/kind/setup.sh` 已按此顺序编排好，可直接用它。

`.env` 缺失或必填项为空时 `gen-secret.sh` 会直接报错退出，不会生成半截 Secret。

### 2. 应用

```sh
kubectl kustomize deploy/k8s/overlays/kind --load-restrictor LoadRestrictionsNone \
  | kubectl apply -f -
```

**首次部署的启动顺序**：k8s 没有 compose 的 `depends_on`，应用层不会等中间件就绪。
一次性 Job 只有 `minio-init`（建桶）；Pulsar 的租户/namespace 由 **Pod 内 sidecar** 建，
无需在这里等：

```sh
kubectl -n lkm wait --for=condition=complete job/minio-init --timeout=10m
# 若应用 Pod 在 Job 完成前就起来并因连不上而崩溃重启，让它们重连一次：
kubectl -n lkm rollout restart deployment
```

后续部署（Job 已 completed 时 apply 是 no-op）不需要这一步。

### 3. 验收

```sh
kubectl -n lkm get pods                      # 期望：除 prefect-* 外全部 Running/Completed
kubectl -n lkm get jobs                      # minio-init / prefect-init 完成
```

网关冒烟（复用 compose 的同一脚本，13 项断言）：

```sh
# kind：宿主机 80/443 已映射到 NodePort，脚本按 SNI 走域名
sh deploy/apisix/smoke.sh 127.0.0.1
```

探针分级（M6.2）在 k8s 下的实测：

```sh
kubectl -n lkm exec deploy/backend -- python -c \
  "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/api/v1/readiness').read().decode())"
```

## 与 compose 的差异（逐条）

| 机制 | compose | k8s | 说明 |
|---|---|---|---|
| 启动顺序 | `depends_on: condition` | initContainer / Job / 探针 | 网关用 initContainer 先渲染配置；数据初始化用 Job |
| 网关配置 | 挂仓库 `config.yaml` | 挂 `apisix-render` **渲染产物** | DNS 解析需随运行时变化，改为占位展开（见下） |
| upstream DNS | Docker 内嵌 DNS `127.0.0.11`，服务短名 | CoreDNS ClusterIP + **FQDN** | lua-resty-dns 是裸查询，CoreDNS 不补 search domain |
| TLS 证书 | certbot 写共享卷 | Secret `lkm-tls`（外部签发/续期） | k8s 里跨 Pod 共享证书应以 Secret 为载体 |
| 日志采集 | 挂 docker.sock 读 json-file | DaemonSet 读 `/var/log/pods`（CRI） | 日志格式不同，source 段必然不同 |
| 可选组件开关 | `--profile` | 副本数（prefect 默认 0） | k8s 无 profile，用 0 副本表达「默认不启用」 |
| Pulsar 数据 | `pulsar_data` 卷持久化 | **emptyDir（不持久化）** | 见上节：账本跨不了 Pod 重建，改以「每次干净启动」换自愈；租户/namespace 由 Pod 内 sidecar 建 |
| 探针 | healthcheck | liveness / readiness / startup **三分** | 语义沿用 M6.2 的 `/liveness` 与 `/readiness` |

### 探针为什么用 `exec` 而不是 `httpGet`

M6.1 的 `TrustedHostMiddleware` 会校验 Host 头，而 kubelet 的 `httpGet` 探针把 Host 设为
**Pod IP**（动态、无法进白名单）→ 一律 400 → 探针长期失败把 Pod 判死。`exec` 探针从容器内
打 `127.0.0.1`，Host 命中白名单里的回环，与 compose healthcheck 同款。
**因此 `LKM_ALLOWED_HOSTS` 必须始终包含 `127.0.0.1` 与 `localhost`。**

## Pulsar：刻意做成「无状态」，Pod 重建即自愈

k8s 侧的 Pulsar **不挂持久卷**（数据目录是 `emptyDir`），这是刻意取舍而非疏漏。

**为什么不能持久化**：ledger 元数据里记的是 bookie 的 **IP:端口**；Pod 重建后 IP 会变
（StatefulSet 只固定名字不固定 IP），且 embedded bookie **每次进程启动都随机取端口**
（实测三次登记为 `:37145` / `:34811` / `:38119`）。任一变化都会让旧 ledger 不可读
（`Failed to read entry` / `Bookie handle is not available`）→ broker 不健康 → 依赖它的
backend 与 9 个 worker 全部起不来。**这就是 compose 上复发两次的那个故障，k8s 下同样复现**
（实测：删 Pod 后 45 处 ledger 读失败）。

三条「钉住 bookie 位置」的路都试过且**无效**，不要再走：`PULSAR_PREFIX_advertisedAddress`
环境变量（standalone 不读该前缀）、`--advertised-address/--bookkeeper-port` CLI（只作用于
broker）、改写 `standalone.conf`（`advertisedAddress` 被解析成列表 `[, <dns>]`，
`bookiePort` 被启动器覆盖回随机值）。

**于是改为**：既然账本跨不了重启，就让每次启动都是干净的。效果（已实测）——删除 `pulsar-0`
后：broker 起来即 healthcheck ok、**0 处 ledger 读失败**、租户与 `biz/auth/system`
namespace 由**同 Pod 的 `pulsar-init` sidecar** 自动重建（不再依赖一次性 Job，故 Pod 重建
也自愈）、消费者自动重连并重建 topic、`/readiness` 回 200。全程无需人工干预。

**代价（明确写入语义变更）**：Pulsar 内**已发布但未被消费**的消息在 Pod 重建时丢失。
未发布的事件由 PG 的 `outbox_events` 经 relay 重新投递（消费者按 `event_id` 幂等），
但「已发布→未消费」这一窗口没有兜底。这与 compose 侧「持久化但可能脏 ledger、需人工清卷」
是**等价强度的取舍**（都保不住那一窗口），只是把故障从「崩溃循环 + 人工介入」换成了
「自动恢复 + 丢在途消息」。

> **生产建议**：不要以「standalone StatefulSet」形态自托管 Pulsar。官方 Pulsar Helm chart
> （多 bookie、可显式配置端口与 advertised address）或托管 Pulsar 服务才能同时给到
> 跨重启持久化与多副本。该取舍已登记《执行路线图》§8 #29。

## 已知限制（部署前必读）

1. **`lkm-backend-data` 是 ReadWriteOnce 的共享 PVC**：backend 与 4 个 worker 都挂 `/data`
   （blog_repos 同卷同路径）。RWO 意味着这些 Pod **必须调度到同一节点**——单机 kind 天然满足，
   多节点生产集群需改用 ReadWriteMany 的 StorageClass，否则后调度的 Pod 卡 `ContainerCreating`。
2. **backend / auth 固定 1 副本**：两者在 lifespan 里跑 alembic 迁移，多副本会并发迁移。
   要横向扩展需先把迁移抽成独立 Job。
3. **证书签发/续期不在集群内**：compose 的 certbot 未移植为 Deployment。生产建议用
   cert-manager，或用定时任务把 certbot 产物按 `gen-tls.sh` 的键名重新导入 Secret。
   `acme-webroot` 仍保留（若走 cert-manager 可把其副本置 0）。
4. **ClickHouse 未设 `nofile` ulimit**：k8s 的 Pod spec 无对应字段（compose 设了 262144）。
   CH 会打 `max_open_files` 警告但不影响功能；真实负载出现 "Too many open files" 时再经
   容器运行时配置抬高。
5. **`worker-scheduler` 拿到了它不消费的 DB/Redis 变量**（共用公共配置表）。多余但无害
   （不读就不会连），换来少维护一张专属表。
6. **Job spec 不可变**：改 `minio-init` / `prefect-init` 的命令前需先
   `kubectl -n lkm delete job <name>`，否则 apply 报错。

## Prefect / ClickHouse 的启用方式

compose 用 `--profile`，k8s 用副本数：

```sh
# 1) server 与 worker 从 0 → 1
kubectl -n lkm scale deploy/prefect-server deploy/prefect-worker --replicas=1

# 2) 重跑注册 Job。它在「server 不可达」时会**成功退出并跳过**（k8s 无 profile，
#    要能表达「默认不启用」），而 Job 完成后不会自动再跑，故须先删再 apply：
kubectl -n lkm delete job prefect-init
kubectl kustomize deploy/k8s/overlays/kind --load-restrictor LoadRestrictionsNone | kubectl apply -f -
kubectl -n lkm wait --for=condition=complete job/prefect-init --timeout=10m

# 3) 把开关打开并重建消费方
kubectl -n lkm set env deploy/worker LKM_PREFECT_ENABLED=true
```

ClickHouse 同理：置 `LKM_CLICKHOUSE_ENABLED=true`，并让 `backend`（admin 只读查询）
与 `worker`（回落直调导出）重建。向量采集（vector DaemonSet）与 OTel collector
默认即在跑，无需开关。

回退：副本置 0 + 变量置 false。

## 回退到 compose

两套编排是并列的，互不依赖：

```sh
kubectl kustomize deploy/k8s/overlays/kind --load-restrictor LoadRestrictionsNone \
  | kubectl delete -f -
```

即清空 k8s 侧（PVC/Secret 需另删），compose 栈不受影响。
