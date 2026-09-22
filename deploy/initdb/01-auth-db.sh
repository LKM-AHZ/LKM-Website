#!/usr/bin/env bash
# S5-A2 Step3：postgres 首启 initdb 时补建「独立 AUTH 库」lkm_auth。
#
# 背景：auth 独立进程(auth.main)的 DB 面须连独立的 auth 库(= S5 拆库目标)，
# 而非单体 biz 库 lkm。标准 postgres:16-alpine 镜像只按 POSTGRES_DB 建 lkm，
# 此脚本经 /docker-entrypoint-initdb.d 挂载，仅首次(空数据卷)初始化时执行一次
# (被 /usr/local/bin/docker-entrypoint.sh 顺序调用,见镜像文档)；此处再叠一层
# 存在性守卫保证幂等，即便二次挂载重跑也不产生 ERROR。
#
# owner 与 POSTGRES_USER(默认 lkm) 同用户：auth 进程以同主连接串直连 lkm_auth，
# 若 owner 不同该用户将无权访问元数据/schema，故显式指定 OWNER。
set -euo pipefail

_authdb="${LKM_AUTH_DB:-lkm_auth}"
# POSTGRES_USER 由 postgres 镜像/entrypoint 提供，set -u 下若缺失会抛一句没有上下文的
# unbound variable；显式给出来源，也让「库 owner == 连接用户」这个前提有据可查
_owner="${POSTGRES_USER:?POSTGRES_USER 未设置（auth 库 owner，需由 postgres 镜像提供）}"

# 库名会被拼进 SQL 字面量与双引号标识符：含引号/分号/换行即可改写语句
if [[ ! "${_authdb}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]]; then
    echo "initdb: 非法的 LKM_AUTH_DB '${_authdb}'（只允许 [A-Za-z_][A-Za-z0-9_]{0,62}）" >&2
    exit 1
fi

# 不用 `psql … | grep -q 1`：set -o pipefail 下「探测失败」（凭据错、库尚未接受连接、
# socket 不通）与「查无此库」都会让管道非 0，一律被读成「不存在」而多跑一次
# CREATE DATABASE。先取输出，把探测失败与真实否定区分开。
if ! _seen="$(psql -v ON_ERROR_STOP=1 -U "${_owner}" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${_authdb}'")"; then
    echo "initdb: 探测 '${_authdb}' 是否存在失败（psql 非 0 退出），中止初始化" >&2
    exit 1
fi
if [ "$_seen" != "1" ]; then
    # \gexec：让 PG 在**执行那一刻**再判一次存在性（format %I 顺带把标识符转义），
    # 关掉 check-then-create 的竞态窗口——并发/重跑撞上 duplicate_database 时不再
    # 因 ON_ERROR_STOP 中止整个 initdb，与文件头「重跑不产生 ERROR」的承诺一致
    psql -v ON_ERROR_STOP=1 -U "${_owner}" -d postgres <<SQL
SELECT format('CREATE DATABASE %I OWNER %I', '${_authdb}', '${_owner}')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${_authdb}')
\gexec
SQL
    echo "initdb: auth database '${_authdb}' ensured (owner=${_owner})"
else
    echo "initdb: auth database '${_authdb}' already exists, skip"
fi
