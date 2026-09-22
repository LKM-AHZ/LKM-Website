#!/usr/bin/env bash
# 批 2：为**业务库**建 timescaledb 扩展（outbox_events / outbox_archived 是 hypertable）。
#
# 官方 timescale/timescaledb 镜像通常已在其主库(POSTGRES_DB)自动建好扩展；此处再叠一层
# 守卫，一是显式留痕（部署资产里看得见「引擎是 Timescale 而非裸 PG」），二是覆盖
# 「换镜像但沿用旧数据卷」的场景——initdb 脚本只在空数据卷首启执行，但应用侧
# init_db 每次启动都会幂等补建，两者互为兜底。
#
# **auth 独立库不建**：hypertable 只在业务库；扩展是库级对象，auth 库多建无益。
# 镜像不含 timescaledb（如误用 postgres:16-alpine）时只告警不中断——应用侧
# init_db._ensure_timescaledb 会同步降级为普通表，链路语义不变。
set -euo pipefail

_db="${POSTGRES_DB:-lkm}"

# 同 01-auth-db.sh：探测失败必须与「镜像里没有 timescaledb」区分开，
# 否则连接/凭据问题会被静默报成「该镜像不支持（已降级）」
if ! _avail="$(psql -U "${POSTGRES_USER}" -d "${_db}" -tAc \
    "SELECT 1 FROM pg_available_extensions WHERE name = 'timescaledb'")"; then
    echo "initdb: 探测 timescaledb 可用性失败（psql 非 0 退出），中止初始化" >&2
    exit 1
fi

if [ "$_avail" = "1" ]; then
    # 「扩展可用但未经 shared_preload_libraries 预加载」时 CREATE EXTENSION 会直接报错，
    # 而本文件承诺「只告警不中断」——故失败只告警，应用侧 init_db 会降级为普通表
    if psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${_db}" \
        -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"; then
        echo "initdb: timescaledb extension ensured on '${_db}'"
    else
        echo "initdb: WARN create extension timescaledb 失败（shared_preload_libraries/权限？），应用侧将降级为普通表" >&2
    fi
else
    echo "initdb: timescaledb not available on this image, skip (应用侧将降级为普通表)"
fi
