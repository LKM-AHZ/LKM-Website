# LKM Kubernetes 部署（Kustomize）

> 配置核对：2026-11-28。清单首先用于 kind 单节点验证；生产需处理下面的存储、
> 消息持久化、证书及组件差异。基础配置与密钥说明见 [部署手册](../../docs/DEPLOYMENT.md)。

## 当前验证状态

2026-11-28 本轮静态检查中，kind overlay 渲染失败：应用清单
[`auth.yaml`](base/app/auth.yaml)、[`backend.yaml`](base/app/backend.yaml) 与
[`workers.yaml`](base/app/workers.yaml) 的同一容器映射内重复声明 `resources`。
修复这些重复键并重新渲染通过后，才能执行下面的部署流程；本轮未连接集群或执行 apply。

## 前置条件

- kubectl 与集群版本兼容，支持 Kustomize；本地验证另需 kind。
- 集群可拉取后端镜像；启用 Bot 时另准备 Bot 镜像。
- 配齐 `.env.example` 中的必填项并生成 RS256 密钥；生产可由 Infisical CLI 注入。
- 生产准备 StorageClass、镜像仓凭据、负载均衡、DNS、受信证书和备份方案。

## 目录与配置来源

| 路径 | 用途 |
|---|---|
| `base/` | 命名空间 lkm、配置、应用、基础设施与网关 |
| `overlays/kind/` | 本地 NodePort 与站点身份，含 setup/load-image 脚本 |
| `overlays/prod/` | 生产域名、站点身份、TLS 与 LoadBalancer 模板 |
| `overlays/rabbitmq/` | 继承 prod，以 RabbitMQ 替换 Pulsar |
| `components/redis-dragonfly/` | Redis 的 Dragonfly 替换组件 |
| `signoz/` | 可选 SigNoz 清单 |
| `gen-secret.sh`、`gen-tls.sh` | 应用 Secret 与网关证书 Secret |

`base/kustomization.yaml` 的 configMapGenerator 直接引用根 `deploy/` 中的
APISIX 模板、initdb、Tinode、ClickHouse、OTel、监控及告警配置。Vector 使用单独的
CRI 日志 source，输出与持久缓冲语义见 `base/infra/vector.toml`。

引用位于 base 目录外，渲染必须开启 `LoadRestrictionsNone`。
`kubectl apply -k` 不接受此参数，应先渲染，再 apply：

```sh
# 在根仓库执行；只渲染检查，不连接集群
kubectl kustomize deploy/k8s/overlays/kind --load-restrictor LoadRestrictionsNone > /tmp/lkm-kind.yaml
```

## 部署顺序

本地 kind 可直接运行 `sh deploy/k8s/overlays/kind/setup.sh`。
手工部署按以下顺序，先创建命名空间，再创建 Secret：

```sh
kubectl apply -f deploy/k8s/base/namespace.yaml
sh deploy/k8s/gen-secret.sh | kubectl apply -f -
sh deploy/k8s/gen-tls.sh | kubectl apply -f -
kubectl kustomize deploy/k8s/overlays/kind --load-restrictor LoadRestrictionsNone \
  | kubectl apply -f -
```

`gen-tls.sh` 默认生成自签证书，只用于验证；生产按脚本的键名导入正式证书。
生产还要修改 `overlays/prod/gateway-domains.yaml`、`site-identity.yaml` 和
`gateway-tls.yaml` 的示例地址、证书键和挂载路径，并选择对应 overlay。

若由 Infisical 注入配置，可用一个空的普通文件禁止本地 `.env` 回退。
`gen-secret.sh` 要求 ENV_FILE 是存在的普通文件，不能用 `/dev/null`：

```sh
# Bash；临时文件为空，不写入密钥
set -o pipefail
lkm_env_file=$(mktemp)
trap 'rm -f "$lkm_env_file"' EXIT
infisical run --env=prod -- sh deploy/infisical/check-env.sh \
  env ENV_FILE="$lkm_env_file" sh deploy/k8s/gen-secret.sh | kubectl apply -f -
```

生产注入仍需可读取的 RS256 PEM 文件；可用 `JWT_PRIVATE_KEY_PATH` / `JWT_PUBLIC_KEY_PATH`
指定生成 Secret 时读取的位置。不要保存或提交渲染出的 Secret 明文。

## 启动与验证

Kubernetes 不提供 Compose 的 depends_on 语义。数据服务就绪前应用可能重启；
`minio-init` 是建桶 Job，Pulsar 租户与 namespace 由 Pod 内 sidecar 初始化。

```sh
kubectl -n lkm get pods
kubectl -n lkm get jobs
kubectl -n lkm wait --for=condition=complete job/minio-init --timeout=10m
kubectl -n lkm rollout status deploy/auth
kubectl -n lkm rollout status deploy/backend

kubectl -n lkm exec deploy/backend -- python -c \
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/api/v1/readiness').read().decode())"

# kind 已映射宿主 80/443，域名需与网关配置一致
sh deploy/apisix/smoke.sh 127.0.0.1
```

若依赖已就绪而应用仍未恢复，先查看具体 Pod 日志和事件，再重启受影响的 Deployment。
不需要每次 apply 后重启全部应用。

## 与 Compose 的差异

| 事项 | 当前 K8s 行为 |
|---|---|
| 消息总线 | base/kind/prod 默认 Pulsar；rabbitmq overlay 才切到 RabbitMQ，Compose 默认 RabbitMQ |
| 镜像版本 | 各清单独立声明，部分与 Compose 不同；部署前核对，不假定同版本 |
| 组件覆盖 | 有 Tinode；未交付 Compose 的 ClamAV、Infisical、shipyard 部署单元 |
| 可选组件 | 搜索、监控、Bot 等以默认 0 副本表达，Prefect 常驻 |
| TLS | 使用 `lkm-tls` Secret；集群内未交付 certbot 自动签发/续期 |
| DNS | 网关使用 CoreDNS 与上游 FQDN；普通客户端可通过 namespace search domain 解析短名 |
| 日志 | Vector DaemonSet 读取 `/var/log/pods` 的 CRI 日志 |
| 应用探针 | backend/auth 使用 exec + urllib；worker 没有独立探针 |
| broker 探针 | Pulsar 探针只检查 broker；namespace/schema 初始化由 sidecar 负责，需另看其日志 |
| 告警地址 | 可选 Secret `lkm-alert-webhook` 的 `url`；模板和 render 脚本与 Compose 共用 |

backend/auth 的 exec 探针使用 `127.0.0.1`，避免 kubelet HTTP 探针的动态 Pod IP
被 TrustedHost 拒绝。`LKM_ALLOWED_HOSTS` 保留 `127.0.0.1`、`localhost` 与内部服务名。

## 生产前必须处理的限制

1. **Pulsar 不持久化**：数据用 emptyDir，Pod 重建时丢失已发布但未消费消息。
   容器重启不等于 Pod 重建，不能将 emptyDir 理解成每次进程启动都清空。
   未发布事件仍在 PG outbox；已发布事件不能靠 outbox 自动恢复。
   生产若要求消息跨重建保留，应另行部署可靠 broker，或评估持久化 RabbitMQ overlay。
2. **共享 backend PVC 为 ReadWriteOnce**：backend 与挂载该 PVC 的 worker 需调度到同节点，
   或使用满足应用共享语义的存储方案；多节点部署不能直接沿用 kind 假设。
3. **backend/auth 默认单副本且启动时迁移**：扩容前先解决并发迁移；Bot SSO 的一次性票据
   表在进程内存，也需保持单副本或改用共享存储。
4. **证书外部管理**：安排签发、续期和 Secret 更新。证书变更后验证网关实际加载的新证书。
5. **备份独立设计**：根 `tools/backup.py` 面向 Compose，不能直接用于 K8s。
   覆盖 PG 各库、MinIO、backend PVC、Tinode 附件与其他启用组件，实际演练恢复。
6. **可观测数据限制**：Prometheus 使用 emptyDir，Pod 重建丢历史；Vector 节点状态和缓冲
   位于 `/var/lib/lkm/vector`，换节点时需考虑采集位置和待写入日志。
7. **Job spec 不可变**：修改 minio-init 命令时需规划删除/重建 Job，不能指望 apply 覆盖。
8. **文件扫描与沙箱**：需要 ClamAV 时单独部署并配置应用；需要 Bot 沙箱时指向集群外 Bay，
   当前清单不提供 Docker socket 沙箱服务。

指标端点位于 backend。auth/worker 的业务指标通过 Redis 中继由 backend 聚合；
这不包含 auth 自身独立的 HTTP QPS/延迟指标。

## 可选功能

```sh
# 监控；启用告警时还需配置 webhook
kubectl -n lkm scale deploy/prometheus deploy/grafana deploy/alertmanager --replicas=1
# Grafana 通过本机转发访问，密码来自已配置的 Secret
kubectl -n lkm port-forward svc/grafana 3000:3000

# Bot 面板；镜像须可拉取，SSO 需 RS256 公钥及管理员权限
kubectl -n lkm scale deploy/lkmbot --replicas=1
# 对外地址：https://<社群域>/bot/
```

Prefect worker 启动时注册 cron 与 flow deployments；`LKM_PREFECT_ENABLED` 控制复杂任务转交。
ClickHouse 的开关与地址在 app-config 中配置，启用后重建对应 backend/worker。
配置应写回 overlay，避免只用 `kubectl set env` 后被下一次 apply 覆盖。

停用可选组件时将副本数写回 0，同时关闭应用侧相应开关。
切换 broker 前先停写、排空积压，不能自动迁移在途消息；apply 不会自动删除旧 broker 资源。

## 卸载与切换环境

```sh
# 仅在确认目标集群与 namespace 后执行
kubectl kustomize deploy/k8s/overlays/kind --load-restrictor LoadRestrictionsNone \
  | kubectl delete -f -
```

渲染结果包含 Namespace；删除 namespace 会删除其中的 Secret、PVC 等资源，存储回收还受
PV reclaim policy 影响。卸载前完成备份，不应将此命令当作无数据影响的“回退到 Compose”。
两套环境之间的数据迁移需要单独验证。
