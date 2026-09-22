#!/bin/sh
# LKM certbot 入口:循环执行 renew,自动续期
trap exit TERM
while :; do
    # 记录每次尝试与结果：这个 cron 式的静默循环里，运维只能靠 docker logs 判断续期
    # 是否真的在跑（certbot 缺失/ACME 调用立即失败时，原样重试 12h 一次毫无痕迹）
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if certbot renew; then
        echo "$ts certbot renew ok"
    else
        rc=$?
        echo "$ts certbot renew FAILED (exit $rc)" >&2
    fi
    sleep 12h &
    wait $!
done
