#!/bin/bash
# Tinode 容器入口：把配置模板中的 $VAR 占位替换成环境变量后启动。
#
# 为什么不直接用官方 entrypoint 的 config.template：它的 auth_config 没有 REST
# 认证段，而 LKM 的账号真身在 auth 库，必须让 Tinode 回调
# /api/v1/auth/internal/tinode/*（见 LKM-service/auth/router_internal_tinode.py）。
# 官方 entrypoint 的配置模板循环与本脚本同构（读取一行、替换 $NAME、写临时文件）。
#
# 运行目录就是镜像内 tinode/ 二进制所在目录（官方 entrypoint 同样用 ./tinode）。
set -euo pipefail

SRC="${TINODE_CONFIG_TEMPLATE:-/etc/tinode/tinode.conf.tmpl}"
CONFIG="${TINODE_CONFIG:-/tmp/tinode.conf}"

: > "$CONFIG"
while IFS= read -r line || [ -n "$line" ]; do
    # 捕获组含 `$` 本身：pattern 里拼 `\$` + 变量名在 bash 的 ${//} 中不匹配，
    # 会让 while 永不退出（实测 CPU 打满、容器卡在 entrypoint）。
    while [[ $line =~ (\$[A-Z_][A-Z_0-9]*) ]]; do
        ph="${BASH_REMATCH[1]}"
        name="${ph#\$}"
        line="${line//"$ph"/"${!name}"}"
    done
    printf '%s\n' "$line" >> "$CONFIG"
done < "$SRC"

# 首次启动建表；已有 schema 时只做版本校验/升级，幂等。
./init-db --config="$CONFIG" --reset=false --upgrade=true

exec ./tinode --config="$CONFIG" --static_data=./static
