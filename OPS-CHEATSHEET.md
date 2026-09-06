# LKM 网站运维速查

针对部署在公网 Ubuntu 服务器(`docker compose` 编排)的常用运维命令。
如无特别说明,均在**服务器终端**(SSH 登录后)执行。

## 〇、连接与目录

| 事项 | 命令 |
|---|---|
| SSH 登录 | `ssh ubuntu@<公网IP>`(密码见部署信息) |
| 项目根目录 | `~/LKM-Website`(含 `docker-compose.yml` 与三个子仓库) |
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

# 健康检查(后端依赖 DB+Redis;astro 依赖后端就绪后才由 nginx 拉起)
curl http://127.0.0.1/api/v1/health
# 期望 {"code":0,"msg":"OK","data":{"status":"ok","db":{"status":"up"},"redis":{"status":"up"}}}
```

## 二、日志

```sh
# 列出当前容器名
docker compose ps --format "{{.Name}}"

# 实时跟踪某服务日志
docker compose logs -f backend
docker compose logs -f nginx
docker compose logs -f worker       # 任务队列消费
docker compose logs -f worker-send  # 发送队列
docker compose logs -f minio        # MinIO

# 只看最近 N 行 / 过滤
docker logs --tail 60 <容器名>
docker logs --tail 120 <容器名> 2>&1 | grep -iE "error|exception|traceback"
```

## 三、MinIO 对象存储

MinIO 仅内网(经 nginx `/lkm/` 转发给浏览器),不开放公网 9000。管理用容器内 `mc`:

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
- 手动建管理员(用后端 ORM + Argon2 哈希,勿手写 SQL 密码):
  ```sh
  docker compose exec backend python - <<'PY'
  import asyncio
  from sqlalchemy import select
  from app.db.session import new_session, get_async_engine
  from app.db.models import User, Profile
  from app.modules.auth.security import hashpwd
  async def main():
      get_async_engine(); db = await new_session()
      try:
          u = (await db.execute(select(User).where(User.username=='alma'))).scalars().first()
          if u:
              print('exists id', u.id); return
          h = await hashpwd('你的密码')
          user = User(username='alma', email='e@x.com', hashed_password=h, account_level='admin')
          db.add(user); db.add(Profile(user=user, role='admin'))
          await db.commit(); print('created user id', user.id)
      finally:
          await db.close()
  asyncio.run(main())
  PY
  ```
  > 密码必须用后端 `hashpwd`(Argon2id) 生成,勿手写明文;`account_level='admin'` 才可进后台。

## 六、证书 / HTTPS

- **有域名**:`docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot -d <域名>`;续期由 certbot 每 12h 自动 + nginx 每 6h reload。
- **无域名(自签)**:nginx entrypoint 自动生成自签占位证书(CN=公网 IP),443 可用但浏览器告警;80 是主入口直接反代。

## 七、常见故障速查(本次实战踩坑)

| 现象 | 大概率原因 | 处理 |
|---|---|---|
| 头像/文件上传 `404` | MinIO 桶未建(S3 不自动建) | `mc mb --ignore-existing m/lkm` |
| 上传 `403 SignatureDoesNotMatch` | boto3 对 MinIO 默认 SigV2 | s3.py 预签名 client 需 `signature_version="s3v4"`+path 寻址+region;公网 host 与 `LKM_S3_PUBLIC_ENDPOINT_URL` 一致 |
| 上传经 nginx `400 Bad Request`(直连正常) | ①proxy_pass 丢了签名 query ②Host 被 include 覆盖 | `/lkm/` 反代 `proxy_pass ...$request_uri`;单独设 Host,勿 include proxy-common-headers.conf |
| nginx 反复 `Restarting` | entrypoint.sh 是 CRLF 行尾 | `sed -i 's/\r$//' deploy/nginx/entrypoint.sh` 转 LF 后 `docker compose up -d --build nginx` 重建 |
| worker 反复重启,日志 `Insecure secrets...` | worker 服务缺三个密钥 env | compose 给 worker/worker-send 注入 `LKM_JWT_SECRET` 等 |
| worker 连 `localhost:6379` | `Worker()` 没传 `redis_settings` | `app/core/worker.py` 各 `Worker(...)` 加 `redis_settings=_redis_settings()` |
| worker `cron ValueError` | arq `weekday` 简写错 | `'thu'`→`'thurs'`(arq 的 WEEKDAYS 是三/四字母) |
| 首页 502 SSR 崩,`Cannot find package 'tailwind-merge'` | `tailwind-merge` 在 devDeps 但被 SSR 运行时 import;runner 用 `--prod` | 挪到 dependencies 并更新 pnpm-lock.yaml 后重建 |
| admin 登录后文件上传/危险操作被拒 | 见「管理员」节(需 2FA / 走 https) | 后台走 `https://<IP>`;危险操作需先验 2FA |

## 八、备份(数据持久化)

```sh
# 数据库
docker compose exec -T postgres pg_dump -U lkm lkm > backup_db_$(date +%F).sql

# MinIO 对象(含文件库 + 头像)
docker compose exec minio sh -c 'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc mirror --preserve m/lkm ./minio_backup_$(date +%F)'

# 后端卷(博客 git 仓库 blog_repos 等)
docker run --rm -v lkm_backend_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/backend_files_$(date +%F).tar.gz -C /data .
```
