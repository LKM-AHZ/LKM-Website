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

if ! psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${_authdb}'" | grep -q 1; then
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres \
        -c "CREATE DATABASE \"${_authdb}\" OWNER \"${POSTGRES_USER}\";"
    echo "initdb: created auth database '${_authdb}' owner=${POSTGRES_USER}"
else
    echo "initdb: auth database '${_authdb}' already exists, skip"
fi
