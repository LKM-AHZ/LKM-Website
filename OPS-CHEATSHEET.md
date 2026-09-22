# LKM 网站运维速查

本文档用于**已经完成部署**的环境。首次安装、变量说明和架构原理见
[DEPLOYMENT.md](./DEPLOYMENT.md)；Kubernetes 环境使用 [deploy/k8s/README.md](./deploy/k8s/README.md)。

> 执行重启、迁移、恢复或删除命令前，先运行 `docker compose ps` 和 `docker compose config --services`
> 确认目标。本文不把 `down -v`、清空数据目录等破坏性命令列为日常操作。

针对部署在公网 Ubuntu 服务器(`docker compose` 编排)的常用运维命令。
如无特别说明,均在**服务器终端**(SSH 登录后)执行。

## 〇、连接与目录

| 事项 | 命令 |
|---|---|
| SSH 登录 | `ssh ubuntu@<公网IP>`(密码见部署信息) |
| 项目根目录 | `~/LKM-Website`(含 `docker-compose.yml` 与四个子仓库,其中 bot 仅 `--profile bot` 用到) |
| 容器日志 | 见下方「日志」小节 |

> 提示:服务器对密码 SSH 有 fail2ban 限速,短时间多次失败会封禁来源 IP 一段时间;
> 建议改用 SSH 公钥免密,并用密钥登录做脚本化操作。

## 一、Docker / Compose 常态运维

```sh
cd ~/LKM-Website

docker compose ps                  # 查看全部容器状态
docker compose ps --format "{{.Name}}: {{.Status}}"   # 只看状态行

# 更新代码后重建并重启
git -C LKM-official-website pull && git -C LKM-service pull
docker compose up -d --build

# 仅重建单个服务(改后端源码后只需重建 backend,worker 复用其镜像):
docker compose up -d --build backend
docker compose up -d --force-recreate worker worker-send   # 让 worker 吃到新镜像

# 重启 / 停止单服务
docker compose restart backend
docker compose stop certbot        # 无域名时 certbot 空跑,可停掉减日志噪音

# 机器人面板(可选组件,主栈 up 不会起它)
docker compose --profile bot up -d --build    # 起面板(含 shipyard 沙箱)
docker compose --profile bot down             # 收掉;bot 数据在宿主机目录,不受 -v 影响
docker compose --profile bot logs -f lkmbot

# 健康检查(后端依赖 DB+Redis;astro 依赖后端就绪后才由 APISIX 拉起)
curl http://127.0.0.1/api/v1/health
# 期望 {"code":0,"msg":"OK","data":{"status":"ok","db":{"status":"up"},"redis":{"status":"up"}}}
# 探针分级(M6.2):/api/v1/liveness 零外部依赖(进程心跳);/api/v1/readiness 复合四项(未就绪 503)
```

## 二、日志

```sh
# 列出当前容器名
docker compose ps --format "{{.Name}}"

# 实时跟踪某服务日志
docker compose logs -f backend
docker compose logs -f apisix       # 网关(唯一对外入口,访问日志在此)
docker compose logs -f worker       # 任务队列消费
docker compose logs -f worker-send  # 发送队列
docker compose logs -f minio        # MinIO
docker compose --profile bot logs -f lkmbot   # 机器人面板(可选组件)

# 只看最近 N 行 / 过滤
docker logs --tail 60 <容器名>
docker logs --tail 120 <容器名> 2>&1 | grep -iE "error|exception|traceback"
```

## 三、MinIO 对象存储

MinIO 仅内网(经 APISIX `/lkm/` 转发给浏览器),不开放公网 9000。管理用容器内 `mc`:

```sh
mc(){ docker exec lkm-website-minio-1 sh -c 'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc '"$@"; }

mc ls m/                            # 全部桶
mc ls --recursive m/lkm/files/      # 桶内文件(files 前缀)
mc ls --recursive m/lkm/files/avatars/   # 成员头像
mc find m/lkm --name "*.webp"       # 按名查找对象

# 建桶(新部署必做!S3 不自动建桶;文件库/头像对象都在其中)
mc mb --ignore-existing m/lkm

# 管理控制台:临时映射 9001 后访问 http://<IP>:9001(用完删除映射)
#   docker-compose.yml minio 服务加 ports:['9001:9001'] 后 docker compose up -d minio
```

## 四、数据库(PostgreSQL)

```sh
# 进 psql(在宿主机的 docker 网络内)
docker compose exec postgres psql -U lkm -d lkm

# 常用 SQL(容器内 psql 交互)
#   \dt                   列出表
#   \d users              看表结构
#   SELECT id, username, account_level FROM users;
#   SELECT id, original_name, status, storage_path FROM library_files;

# 跑了测试残留想删:DELETE FROM library_files WHERE original_name LIKE '测试前缀%';

# 备份
docker compose exec -T postgres pg_dump -U lkm lkm > backup_db_$(date +%F).sql
# 恢复
docker compose exec -T postgres psql -U lkm -d lkm < backup_db.sql
```

## 五、管理员 / 认证(本次部署后的策略)

- **登录不再强制 2FA**:普通登录只验密码并签发 token;仅后台**危险操作**(板块/项目审核等)需 2FA。
- **2FA 信任 1 小时**:验证后 1h 内危险操作不再重复要求;信任窗口由 admin cookie 的 `mfa`/`mfa_at` claim 承载。
- **admin cookie 带 Secure**:纯 HTTP(80)下浏览器不发送 → **后台请走 `https://<IP>`** 访问(自签证书,首次手动信任)。普通前台走 JWT,HTTP 正常。
- 管理员运维(建号/解锁/吊销会话/重置 2FA)统一走脚本,**在 auth 容器内执行**——
  拆库后管理员真值在 `lkm_auth` 库,只有 auth 服务配了 `LKM_AUTH_DB_*`;backend 容器只有
  biz 库,旧版 heredoc 建号命令已失效:
  ```sh
  docker compose exec auth python scripts/admin_ops.py list
  docker compose exec auth python scripts/admin_ops.py create <用户名> <邮箱> <手机> <密码>
  docker compose exec auth python scripts/admin_ops.py unlock <用户名>
  docker compose exec auth python scripts/admin_ops.py revoke <用户名>        # 吊销全部会话(前台+后台)
  docker compose exec auth python scripts/admin_ops.py reset-2fa <用户名> --yes
  ```
  > 密码由脚本内部 `hashpwd`(Argon2id) 生成,勿手写明文;`account_level='admin'` 才可进后台。

## 六、证书 / HTTPS

- **有域名**:`docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot -d <域名>`;续期由 certbot 每 12h 自动 + `apisix-render` 每 6h 重渲染触发 APISIX reload。
- **bot 面板**:已并入社群域子路径 `/bot/`(无独立子域名),证书随社群域那一份,**无需**单独首签或额外 DNS。
- **无域名(自签)**:`apisix-render` 缺证书时自动生成自签占位(CN=域名),443 可用但浏览器告警;http 由 APISIX 301 到 https。

## 七、常见故障速查(本次实战踩坑)

| 现象 | 大概率原因 | 处理 |
|---|---|---|
| 头像/文件上传 `404` | MinIO 桶未建(S3 不自动建) | `mc mb --ignore-existing m/lkm` |
| 上传 `403 SignatureDoesNotMatch` | boto3 对 MinIO 默认 SigV2 | s3.py 预签名 client 需 `signature_version="s3v4"`+path 寻址+region;公网 host 与 `LKM_S3_PUBLIC_ENDPOINT_URL` 一致 |
| 上传经 APISIX `400 Bad Request`(直连正常) | MinIO 路由 Host 未改写为公网站点(SigV4 预签名按公网 host 签) | `deploy/apisix/apisix.yaml` 的 `minio` 路由用 `pass_host: rewrite` + `upstream_host`,勿用 `proxy-rewrite.host`(会被 pass_host 以 nil 覆盖) |
| 容器反复 `Restarting` | 挂载进去的 `.sh` 是 CRLF 行尾 | `sed -i 's/\r$//' <脚本>` 转 LF 后重建;仓根 `deploy/**` 已由 `.gitattributes` 强制 LF |
| worker 反复重启,日志 `Insecure secrets...` | worker 服务缺三个密钥 env | compose 给 worker/worker-send 注入 `LKM_JWT_SECRET` 等 |
| worker 连 `localhost:6379` | `Worker()` 没传 `redis_settings` | `app/core/worker.py` 各 `Worker(...)` 加 `redis_settings=_redis_settings()` |
| worker `cron ValueError` | arq `weekday` 简写错 | `'thu'`→`'thurs'`(arq 的 WEEKDAYS 是三/四字母) |
| 首页 502 SSR 崩,`Cannot find package 'tailwind-merge'` | `tailwind-merge` 在 devDeps 但被 SSR 运行时 import;runner 用 `--prod` | 挪到 dependencies 并更新 pnpm-lock.yaml 后重建 |
| admin 登录后文件上传/危险操作被拒 | 见「管理员」节(需 2FA / 走 https) | 后台走 `https://<IP>`;危险操作需先验 2FA |
| `https://<社群域>/bot/` 502/503 | lkmbot 未起(可选组件,主栈 up 不含它) | `docker compose --profile bot up -d lkmbot` |
| `https://<社群域>/bot/` 404(被前台接走) | `/bot` 路由未加载(proxy-rewrite 写法非法会让整条路由被 APISIX 丢弃) | `docker compose logs apisix \| grep -i schema`;`docker compose exec apisix-render grep -n bot /out/apisix.yaml` 确认三条路由在产物里,再 `docker compose restart apisix` |
| 面板白屏/资源 404,Network 里 JS 打到 `/assets/...` | 面板 dist 是**根 base** 的:要么被「WebUI 在线更新」覆盖,要么**旧部署遗留的 `LKM-bot/data/dist`**(旧版会从上游下载)在优先级上盖过镜像内置 dist | 删掉遗留产物 `sudo rm -rf LKM-bot/data/dist` 后重启 `lkmbot`;不要再在面板里点在线更新。内置 dist 由镜像构建(带 `/bot` base),版本与 Core 一致时不会触发下载 |
| 打开 `/admin/bot/*` 停在面板登录页 | SSO 未生效(未配 RS256 公钥 / auth 不可达 / 票据被重放) | 确认 `deploy/jwt/keys/jwt-public.pem` 存在且已挂进 lkmbot(compose 卷);看 `docker compose logs lkmbot \| grep -i sso`;不修也不影响使用——手动登录一次即可 |
| 同上,且日志里是 `InvalidIssuerError`/`InvalidAudienceError`/`type` 校验失败 | 签发侧 auth 与消费侧 lkmbot 读到的 `LKM_BOT_SSO_AUDIENCE`/`LKM_BOT_SSO_ISSUER`/`LKM_BOT_SSO_TYPE`/`LKM_BOT_SSO_ACCOUNT_LEVEL` 不一致(四项由**同一处**下发,只有手工改过一侧才会发生) | `docker compose config \| grep LKM_BOT_SSO` 看两个服务是否同值;不要单独改某一侧,改 compose 的 `x-bot-sso-env` 锚点(或 k8s 的 `lkm-config-botsso`)。`LKM_BOT_SSO_TTL_SECONDS` 例外:只有 auth 有它 |
| bot 面板上传大文件被 413 | 网关 `LKM_BOT_MAX_UPLOAD_BYTES` 被改小(独立于社群站的 100MB) | 恢复默认 `550000000` 并 `docker compose up -d apisix-render apisix` |
| shipyard 起不来沙箱,日志找不到 bind 源 | `LKM_BOT_SHIP_DATA_DIR` 不是宿主机**绝对**路径(或 compose 不在仓库根执行) | 在 `.env` 写绝对路径后 `docker compose --profile bot up -d shipyard` |
| bot 沙箱功能不生效(无报错) | 默认 `booter=shipyard_neo` 与旧 Bay 不匹配,且 `computer_use_runtime=none` | 面板「配置 → 沙箱」把 booter 改 `shipyard`、endpoint 填 `http://shipyard:8156` |
| bot 数据目录删不掉/权限拒绝 | `./LKM-bot/data` 由容器以 root 写入(bind 而非命名卷,沙箱需宿主路径) | 用 `sudo rm -rf` 或 `docker compose --profile bot down` 后清理 |
| `apisix-render` 反复退出,日志停在证书生成 | 新并入的 bot 域需 `apk add openssl` 而容器出不了网(与「删卷后需预置自签证书」同坑) | 宿主 `openssl` 预生成 `bot.<域名>/{fullchain,privkey}.pem` 写入 `certbot_conf` 卷;或先放行该容器出网 |

## 八、备份(数据持久化)

```sh
# 数据库
docker compose exec -T postgres pg_dump -U lkm lkm > backup_db_$(date +%F).sql

# MinIO 对象(含文件库 + 头像)
docker compose exec minio sh -c 'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc mirror --preserve m/lkm ./minio_backup_$(date +%F)'

# 后端卷(博客 git 仓库 blog_repos 等)
docker run --rm -v lkm_backend_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/backend_files_$(date +%F).tar.gz -C /data .

# 机器人数据(面板 sqlite/插件/配置,宿主机 bind 目录;shipyard 卷另算)
tar czf bot_data_$(date +%F).tar.gz -C LKM-bot/data . 2>/dev/null || true

## 九、运维工具箱(tools/ 与 scripts/)

把上文靠手敲的命令固化成可执行工具。宿主机侧只依赖标准库(有 python3 即可),
容器侧复用 app 的配置与 ORM。

| 工具 | 用途 | 运行位置 |
|---|---|---|
| `python3 tools/preflight.py` | 上线前体检:主密钥强度/互异、Host 白名单、`deploy/**` CRLF、容器状态、健康端点、MinIO 桶、两库 alembic 到 head、证书有效期;`--static-only` 跳过依赖容器的检查 | 宿主机 |
| `python3 tools/diagnose.py` | Pulsar/worker 诊断:worker 卡 Created、broker 就绪、订阅 backlog、ledger 占用、近期错误 + 处置建议;`--quick` 跳过 backlog | 宿主机 |
| `python3 tools/backup.py backup` | 一条命令备份 DB + MinIO + backend 卷并校验产物;`list` 列备份、`restore --from <目录> --yes` 恢复 | 宿主机 |
| `python3 scripts/admin_ops.py <子命令>` | 管理员与会话运维(list/unlock/revoke/reset-2fa/create) | auth 容器 |
| `python3 scripts/check_storage.py` | `library_files` ↔ MinIO 对账(缺失/孤儿对象);`--fix --yes` 清理孤儿 | backend 容器 |

后台管理页面新增 **`/admin/dlq`**(死信队列):按状态查看死信、重投、丢弃,消息体
JSON 可展开;对应 `/api/v1/admin/dlq` 端点。该端点本次补齐了统一的 `{code,msg,data}`
包络(此前返回裸 JSON,前端 `readAdminResp` 无法解析)。
```
