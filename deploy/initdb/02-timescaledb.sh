#!/usr/bin/env bash
# 为业务库和独立 auth 库建 timescaledb 扩展。
#
# 官方 timescale/timescaledb 镜像通常已在其主库(POSTGRES_DB)自动建好扩展；此处再叠一层
# 守卫，一是显式留痕（部署资产里看得见「引擎是 Timescale 而非裸 PG」），二是覆盖
# 「换镜像但沿用旧数据卷」的场景——initdb 脚本只在空数据卷首启执行，但应用侧
# 业务/auth 各自的初始化过程每次启动都会幂等补建，两者互为兜底。
#
# auth 库的 audit_logs 也使用 hypertable，扩展必须分别装在两个库中。
# 镜像不含 timescaledb（如误用 postgres:16-alpine）时只告警不中断——应用侧
# 初始化过程会同步降级为普通表，链路语义不变。
set -euo pipefail

_biz_db="${POSTGRES_DB:-lkm}"
_auth_db="${LKM_AUTH_DB:-lkm_auth}"

# 同 01-auth-db.sh：探测失败必须与「镜像里没有 timescaledb」区分开，
# 否则连接/凭据问题会被静默报成「该镜像不支持（已降级）」
if ! _avail="$(psql -U "${POSTGRES_USER}" -d "${_biz_db}" -tAc \
    "SELECT 1 FROM pg_available_extensions WHERE name = 'timescaledb'")"; then
    echo "initdb: 探测 timescaledb 可用性失败（psql 非 0 退出），中止初始化" >&2
    exit 1
fi

if [ "$_avail" = "1" ]; then
    # 「扩展可用但未经 shared_preload_libraries 预加载」时 CREATE EXTENSION 会直接报错，
    # 而本文件承诺「只告警不中断」——故失败只告警，应用侧 init_db 会降级为普通表
    for _db in "${_biz_db}" "${_auth_db}"; do
        if psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${_db}" \
            -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"; then
            echo "initdb: timescaledb extension ensured on '${_db}'"
        else
            echo "initdb: WARN create extension timescaledb on '${_db}' 失败，应用侧将降级为普通表" >&2
        fi
    done
else
    echo "initdb: timescaledb not available on this image, skip (应用侧将降级为普通表)"
fi
