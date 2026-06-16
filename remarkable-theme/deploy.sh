#!/bin/bash
# 墨阅 reMarkable 主题包部署器
#   ./deploy.sh           部署 patches/ 到设备 koreader/patches/ 并杀掉 KOReader(待重开生效)
#   ./deploy.sh --verify  额外把 size.lua 还原成原版(验证主题 patch 能独立生效)
#   ./deploy.sh --revert  移除主题 patch(恢复无主题)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KEY=~/.ssh/id_ed25519_remarkable
IP="${2:-10.11.99.1}"
SSH=(ssh -i "$KEY" -o ConnectTimeout=8 "root@$IP")
D=/home/root/xovi/exthome/appload/koreader

ping -c 1 -t 3 "$IP" >/dev/null 2>&1 || { echo "设备离线，先唤醒"; exit 1; }

if [ "${1:-}" = "--revert" ]; then
    "${SSH[@]}" "rm -f $D/patches/2-remarkable-theme.lua; killall -TERM luajit 2>/dev/null || true"
    echo "✓ 已移除主题 patch，重开 KOReader 恢复"
    exit 0
fi

echo "== 推送主题包 patches/ =="
"${SSH[@]}" "mkdir -p $D/patches"
scp -i "$KEY" -q "$DIR"/patches/*.lua "root@$IP:$D/patches/"
"${SSH[@]}" "ls $D/patches/"

if [ "${1:-}" = "--verify" ]; then
    echo "== Phase1 验证：还原 size.lua 为原版（让主题 patch 成为唯一来源）=="
    "${SSH[@]}" "[ -f $D/frontend/ui/size.lua.skinbak ] && cp $D/frontend/ui/size.lua.skinbak $D/frontend/ui/size.lua && echo '✓ size.lua 已还原原版' || echo '(无 size.lua.skinbak)'"
fi

echo "== 清字体缓存 + 关闭 KOReader（待你重开生效）=="
"${SSH[@]}" "rm -rf $D/cache/fontlist; killall -TERM luajit 2>/dev/null || true"
# 等 KOReader 真正退出
"${SSH[@]}" 'for i in $(seq 1 10); do [ "$(ps 2>/dev/null | grep -c [r]eader.lua)" = "0" ] && break; sleep 2; done; echo "KOReader 进程: $(ps 2>/dev/null | grep -c [r]eader.lua)"'

echo ""
echo "✅ 主题包已部署。请重新打开 KOReader。"
echo "   验证补丁是否执行: ssh root@$IP \"grep rM-theme $D/crash.log | tail\""
