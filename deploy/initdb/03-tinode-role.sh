#!/usr/bin/env bash
# Tinode 聊天库的连接角色。
#
# 背景（2026-11-17 用 tinode/tinode-postgres v0.25.3 实测）：Tinode 的 postgres
# 适配器要求数据库用户名是 postgres——换成其它用户名后 DBName 会被忽略，
# 连接落到与用户名同名的库并报 `database "<user>" does not exist`。业务主用户
# 仍是 POSTGRES_USER；这里只为 Tinode 建一个名为 postgres 的登录角色，并复用
# POSTGRES_PASSWORD。权限只给 CREATEDB（tinode 库由 Tinode init-db 首启自建，
# 建库者即 owner），不给 SUPERUSER。
#
# 只在空数据卷首启执行（/docker-entrypoint-initdb.d）；已初始化的部署升级时
# 需手工执行同一 SQL（见 docs/DEPLOYMENT.md）。
set -euo pipefail

_owner="${POSTGRES_USER:?POSTGRES_USER 未设置（postgres 镜像主用户）}"

# 密码经 psql 变量 + %L 转义，避免单引号破坏语句。
psql -v ON_ERROR_STOP=1 -U "${_owner}" -d postgres -v pw="${POSTGRES_PASSWORD:-}" <<'SQL'
SELECT format('CREATE ROLE postgres WITH LOGIN CREATEDB PASSWORD %L', :'pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres')\gexec

SELECT format('ALTER ROLE postgres WITH LOGIN CREATEDB PASSWORD %L', :'pw')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres')\gexec
SQL
