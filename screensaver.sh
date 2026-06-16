#!/bin/bash
# 墨阅 · 更换待机屏保（bind-mount 方案：系统分区出厂即满，不能直接写）
# 用法: ./screensaver.sh <图片文件> [设备IP]
#       ./screensaver.sh --restore [设备IP]   恢复原版屏保
set -euo pipefail

KEY="$HOME/.ssh/id_ed25519_remarkable"
IMG="${1:?用法: ./screensaver.sh <图片|--restore> [设备IP]}"
IP="${2:-10.11.99.1}"
SSH_OPTS=(-i "$KEY" -o ConnectTimeout=8)
TARGET=/usr/share/remarkable/suspended.png
CUSTOM=/home/root/paperlite/suspended.png
HOOK=/home/root/xovi/scripts/post-start/screensaver.sh

if [ "$IMG" = "--restore" ]; then
    ssh "${SSH_OPTS[@]}" "root@$IP" "
        umount $TARGET 2>/dev/null || true
        rm -f $CUSTOM $HOOK
        systemctl restart xochitl
        echo '✓ 已恢复原版屏保'
    "
    exit 0
fi

[ -f "$IMG" ] || { echo "找不到图片 $IMG"; exit 1; }

# rM2 屏幕 1404x1872，转成 PNG
TMP=$(mktemp /tmp/paperlite-ss-XXXX).png
sips -s format png --resampleHeightWidthMax 1872 "$IMG" --out "$TMP" >/dev/null
sips -z 1872 1404 "$TMP" --out "$TMP" >/dev/null

scp "${SSH_OPTS[@]}" -q "$TMP" "root@$IP:$CUSTOM"
ssh "${SSH_OPTS[@]}" "root@$IP" "
    umount $TARGET 2>/dev/null || true
    mount --bind $CUSTOM $TARGET
    # 重启后由 xovi post-start 钩子重新挂载
    mkdir -p \$(dirname $HOOK)
    printf '#!/bin/bash\nmountpoint -q $TARGET || mount --bind $CUSTOM $TARGET\n' > $HOOK
    chmod +x $HOOK
    systemctl restart xochitl
"
rm -f "$TMP"
echo "✓ 屏保已更换（按电源键休眠即可看到），恢复: ./screensaver.sh --restore"
