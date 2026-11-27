# LKM 运维速查

> 配置核对：2026-11-28。适用于已部署的 Compose 环境，命令从部署仓库根目录执行。
> 首次部署、密钥、迁移和恢复演练见 [部署手册](./DEPLOYMENT.md)；集群操作见
> [Kubernetes 说明](../deploy/k8s/README.md)。

## 状态、日志与探针

```sh
docker compose config --quiet
docker compose ps --all
docker compose logs --tail 100 backend auth worker worker-outbox
docker compose logs -f apisix

# 经正式域名检查，避免 Host 白名单或 TLS/SNI 导致误判
curl --fail https://community.example/api/v1/liveness
curl --fail https://community.example/api/v1/readiness
sh deploy/apisix/smoke.sh <网关IP>
```

`liveness` 检查进程存活；`readiness` 检查已配置的外部依赖，未就绪返回 503。
业务响应字段为 `code`、`message`、`data`、`request_id`。静态官网独立部署，
本栈不提供旧网页客户端的 `/forum/`、`/qa/` 或 `/_astro/` 资源。

## 更新与重启

Git 部署先保存各仓库的本地改动，再同步根仓库及其固定的子模块提交：

```sh
git status --short
git pull --ff-only
git submodule update --init --recursive
```

源码包部署需同时包含三个子模块；根仓库的 `git archive` 不包含子模块内容。
更新前保留旧镜像标签、配置和数据备份。应用镜像与重建范围：

| 改动 | 构建 | 更新服务 |
|---|---|---|
| LKM-service | `docker compose build backend` | backend、auth、所有 worker、Prefect server/worker |
| LKM-bot | `docker compose --profile bot build lkmbot` | lkmbot |
| 网关模板或环境变量 | 无需构建 | apisix-render；必要时重启 apisix |

```sh
# 后端与 worker 共用镜像，须一起更新
docker compose up -d backend auth worker worker-send worker-notify   worker-notification worker-content-index worker-outbox worker-dlq   worker-points-reward worker-points-stats worker-points-tasks   prefect-server prefect-worker

# 更新可选 Bot 面板
docker compose --profile bot up -d lkmbot
# 只停 Bot；带 profile 的 down 会停止整个项目
docker compose stop lkmbot shipyard

# 环境变量变更用 up 重建；单纯 restart 不会读取新的 .env
docker compose up -d apisix-render
# 仅证书文件变化时可让现有渲染容器立即重新读取
docker compose restart apisix-render
```

APISIX 使用动态 DNS，当前配置的解析有效期为 30 秒。后端重建后若持续 502，
先查 `backend`/`auth` 健康状态与网关日志，必要时 `docker compose restart apisix`。
升级完成后重新运行探针与网关冒烟；成功构建镜像不等于服务已完成更新。

## 数据库与对象存储

```sh
# 业务库；AUTH 使用独立 lkm_auth 库
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d lkm_auth'

# 自动建桶任务完成后应显示 Exited (0)
docker compose ps --all minio-init
docker compose logs minio-init

# 容器内展开凭据，列出默认 lkm 桶；自定义桶名时替换末尾路径
docker compose exec minio sh -c 'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc ls m/lkm'
```

schema 变更按部署手册的双迁移链流程处理；修改模型或更换数据库地址不需要删除数据卷。
Tinode 数据库与 AUTH 库独立，聊天附件位于 `tinode_media` 卷。

## 管理员与 Bot SSO

管理员脚本在 AUTH 容器内执行：

```sh
docker compose exec auth python scripts/admin_ops.py list
docker compose exec auth python scripts/admin_ops.py create <用户名> <邮箱> <手机>
docker compose exec auth python scripts/admin_ops.py unlock <用户名>
docker compose exec auth python scripts/admin_ops.py revoke <用户名>
docker compose exec auth python scripts/admin_ops.py reset-2fa <用户名> --yes
```

`create` 省略密码时交互输入。后台危险操作要求有效的 2FA 信任；管理员 cookie 使用
Secure 属性，应通过 HTTPS 访问。Bot 换票额外要求 `admin.bot_panel` 权限，默认授予
`admin:super_admin`；以 `/api/v1/admin/auth/me` 返回的权限为准。
Bot 面板使用社群域的 `/bot/`，无需独立域名或证书。

## 证书

```sh
# 按实际域名替换；多个域名追加 -d
docker compose run --rm --entrypoint certbot certbot certonly --webroot   -w /var/www/certbot -d community.example
docker compose restart apisix-render
docker compose logs --tail 100 certbot apisix-render
```

certbot 每 12 小时续期，apisix-render 每 6 小时读取证书并重新渲染。
缺正式证书时使用自签占位证书；生产验收应使用受客户端信任的证书。

## 常见故障

| 现象 | 核查与处理 |
|---|---|
| 启动报缺少密钥 | 对照 `.env.example` 补齐必填项，生成 RS256 文件，再运行 `docker compose config --quiet` |
| 容器持续重启 | 查对应服务日志；确认挂载脚本为 LF、密钥路径与容器内路径一致 |
| readiness 返回 503 | 查看响应中的失败依赖，并检查数据库、Redis、AUTH、公钥及所选 broker |
| 上传或头像失败 | 先查 `minio-init`、桶名与存储凭据；建桶由编排自动完成 |
| 上传 `SignatureDoesNotMatch` | 核对 `LKM_S3_PUBLIC_ENDPOINT_URL` 与访问 origin；检查网关 MinIO 路由的 Host 改写 |
| 上传 413 | 修改 `.env` 的 `LKM_MAX_UPLOAD_BYTES`，重建 backend 与 apisix-render；Bot 独立使用 `LKM_BOT_MAX_UPLOAD_BYTES` |
| `/bot/` 502/503 | 确认启用了 bot profile，并检查 lkmbot 状态 |
| Bot 面板白屏或资源 404 | 核对 `LKM_BOT_BASE_PATH` 与镜像构建参数；检查是否存在覆盖内置资源的 `LKM-bot/data/dist` |
| Bot SSO 回到登录页 | 核对权限、公钥、AUTH 可达性及两侧 SSO issuer/audience/type 配置；查看 lkmbot 日志 |
| 沙箱无法启动 | 核对 Docker socket、`LKM_BOT_SHIP_DATA_DIR` 绝对路径和 access token；旧 Bay 对应 `sandbox.booter=shipyard` |

## 备份与恢复

```sh
python3 tools/backup.py backup --keep 14
python3 tools/backup.py list
systemctl status lkm-backup.timer
journalctl -u lkm-backup.service --since today
```

当前工具只备份 **业务库、MinIO 和 backend_data**。AUTH 库、Tinode 数据库/附件、
Prefect 数据库及可选 Bot 数据需另行备份；单个 `pg_dump` 不会包含同实例的其他数据库。
完整范围与恢复演练见 [部署手册的备份与恢复](./DEPLOYMENT.md#备份与恢复)。
恢复前停止目标环境写入，核对项目名、库名和备份日期；演练在独立环境执行。

## 事件重放与诊断

| 工具或接口 | 用途 |
|---|---|
| `python3 tools/preflight.py --static-only` | 静态配置预检；去掉参数可检查运行环境 |
| `python3 tools/diagnose.py --quick` | Pulsar/worker 专项诊断，适用于启用 Pulsar 的环境 |
| `docker compose exec backend python scripts/check_storage.py` | 文件库与对象存储对账 |
| `GET /api/v1/admin/dlq` | 消费侧死信 |
| `POST /api/v1/admin/dlq/{id}/requeue` | 修复后重新入队 |
| `GET /api/v1/admin/event-failures` | relay 发布失败归档 |
| `POST /api/v1/admin/event-failures/{id}/replay` | 沿用原 event_id 写回 outbox |

重放成功表示已可靠入队，后续仍由 relay 投递；原失败记录保留并标记重放时间。
可在请求体传修正后的 `routing_key` 和 `payload`，先修复根因再重放。
