#!/bin/bash
# 墨阅 · 完整卸载，恢复设备原状
# 用法: ./uninstall.sh [设备IP]
set -euo pipefail

KEY="$HOME/.ssh/id_ed25519_remarkable"
IP="${1:-10.11.99.1}"
SSH_OPTS=(-i "$KEY" -o ConnectTimeout=8)

echo "将卸载: xovi / AppLoad / KOReader / 传书服务，并重新打开系统自动更新。"
echo "书库 /home/root/books 里的书会保留。"
read -rp "确认卸载？(y/N) " ans
[ "$ans" = "y" ] || exit 0

ssh "${SSH_OPTS[@]}" "root@$IP" '
    set -x
    # 停掉 xovi 注入，恢复原生界面
    [ -x /home/root/xovi/stock ] && /home/root/xovi/stock || true
    systemctl disable --now bookbridge.service 2>/dev/null || true
    systemctl disable xovi-autostart.service 2>/dev/null || true
    systemctl daemon-reload
    # 恢复屏保（bind-mount 方案，卸载即还原）
    umount /usr/share/remarkable/suspended.png 2>/dev/null || true
    rm -rf /home/root/xovi /home/root/shims /home/root/paperlite
    # 重新打开自动更新
    systemctl enable --now update-engine 2>/dev/null || true
    systemctl restart xochitl
'
echo "✓ 卸载完成，设备已恢复原状（书库保留在 /home/root/books）"
