#!/bin/sh
# LKM certbot 入口:循环执行 renew,自动续期
trap exit TERM
while :; do
    certbot renew
    sleep 12h &
    wait $!
done
