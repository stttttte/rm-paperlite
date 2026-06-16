#!/bin/bash
# 推送 Claude 侧边栏入口 + 原生应用 + 插件更新到设备
set -euo pipefail
KEY=~/.ssh/id_ed25519_remarkable
IP="${1:-10.11.99.1}"
P=device/payload
ssh -i $KEY root@$IP 'mkdir -p /home/root/xovi/exthome/appload/claude'
scp -i $KEY -q $P/xovi/exthome/appload/claude/* root@$IP:/home/root/xovi/exthome/appload/claude/
scp -i $KEY -q $P/xovi/exthome/qt-resource-rebuilder/claude.qmd root@$IP:/home/root/xovi/exthome/qt-resource-rebuilder/
scp -i $KEY -q $P/paperlite/claude.json root@$IP:/home/root/paperlite/
scp -i $KEY -q $P/xovi/exthome/appload/koreader/plugins/clawd.koplugin/main.lua root@$IP:/home/root/xovi/exthome/appload/koreader/plugins/clawd.koplugin/main.lua
echo "✓ 文件就位，重启界面使 qmldiff 生效..."
ssh -i $KEY root@$IP 'nohup /home/root/xovi/start >/tmp/xovi-start-claude.log 2>&1 & sleep 1; echo done'
echo "✓ 完成。约 20 秒后看设备侧边栏。"
