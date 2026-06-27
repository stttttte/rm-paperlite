#!/bin/bash
# 墨阅 · 持久化增量部署(①持久化:重启后字体/休眠屏不失效)
# 在 Mac 上运行,设备需在线(USB 默认 10.11.99.1,或传 WiFi IP)。
# 做三件事:
#   1) 推送新 bookbridge-arm(含 ensureFontMount 自愈)+ pre-start 持久化钩子
#   2) 把老的「整目录字体挂载」迁移成「单文件挂载」(不再遮挡其它原版 Noto 字体)
#   3) 打印验证:挂载状态 + 原版字体是否仍在 + 钩子是否就位
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
IP="${1:-10.11.99.1}"
KEY="$HOME/.ssh/id_ed25519_remarkable"
SSH=(ssh -i "$KEY" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@$IP")
SCP=(scp -i "$KEY" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

say "0/4 检查连接 ($IP)"
ping -c 1 -t 3 "$IP" >/dev/null 2>&1 || { echo "连不上 $IP(USB 请确认线已插+亮屏;WiFi 传设备 IP 作参数)"; exit 1; }
"${SSH[@]}" true || { echo "SSH 失败,先跑 install.sh 配免密"; exit 1; }

say "1/4 推送二进制 + 持久化钩子 + 屏保图库"
"${SSH[@]}" 'mkdir -p /home/root/paperlite /home/root/paperlite/screensavers /home/root/xovi/scripts/pre-start'
"${SCP[@]}" -q "$DIR/server/bookbridge-arm" "root@$IP:/home/root/paperlite/bookbridge"
"${SCP[@]}" -q "$DIR/device/payload/xovi/scripts/pre-start/paperlite-mounts.sh" \
    "root@$IP:/home/root/xovi/scripts/pre-start/paperlite-mounts.sh"
# 内置屏保图(若已生成)
if ls "$DIR"/device/payload/paperlite/screensavers/*.png >/dev/null 2>&1; then
    "${SCP[@]}" -q "$DIR"/device/payload/paperlite/screensavers/*.png "root@$IP:/home/root/paperlite/screensavers/"
    echo "✓ 已推送屏保图库"
fi
"${SSH[@]}" 'chmod +x /home/root/paperlite/bookbridge /home/root/xovi/scripts/pre-start/paperlite-mounts.sh'
# 零重启入库:强制 usb0 带 10.11.99.1,使 xochitl 启动绑定原生 :80 上传服务(详见该文件注释)
"${SSH[@]}" 'mkdir -p /etc/systemd/network'
"${SCP[@]}" -q "$DIR/device/payload/etc/systemd/network/09-usb0.network" \
    "root@$IP:/etc/systemd/network/09-usb0.network"
"${SSH[@]}" 'networkctl reload 2>/dev/null; networkctl reconfigure usb0 2>/dev/null; sleep 2
    if ip -o addr show usb0 2>/dev/null | grep -q "10.11.99.1"; then echo "✓ usb0 已带 10.11.99.1（零重启入库就绪，重启 xochitl 后 :80 生效）"; else echo "⚠ usb0 未带 IP，零重启入库可能不生效"; fi'
echo "✓ 已推送"

say "2/4 迁移整目录挂载→单文件挂载 + 重启(停 xochitl 期间换,避免 umount 占用失败)"
# 关键:迁移与重启放进同一远程块,且 xochitl 无论挂载成败都必定重新启动
# (否则一旦 mount 失败,本地 set -e 会在 xochitl 停止状态下中止脚本→设备卡死)。
"${SSH[@]}" '
    SRC=/home/root/ttf-noto/NotoSerifSC-VariableFont_wght.ttf
    TGT=/usr/share/fonts/ttf/noto/NotoSerifSC-VariableFont_wght.ttf
    NOTODIR=/usr/share/fonts/ttf/noto

    if [ ! -f "$SRC" ]; then
        echo "⚠ 没找到字体源 $SRC,跳过字体迁移(全新设备请走 install.sh 播种)"
    else
        systemctl stop xochitl
        # 兜底:即便 SSH 中途掉线(SIGHUP)或异常,也保证 xochitl 被重新拉起,绝不卡在停止态
        trap "systemctl start xochitl" EXIT HUP INT TERM
        # 先卸内层单文件挂载(子),再卸老的整目录挂载(父)——顺序反了父会被子占用而留孤儿
        if mountpoint -q "$TGT"; then umount "$TGT" 2>/dev/null || umount -l "$TGT"; fi
        if mountpoint -q "$NOTODIR"; then
            umount "$NOTODIR" 2>/dev/null || umount -l "$NOTODIR"
            echo "✓ 已卸载旧的整目录挂载"
        fi
        # 建立单文件挂载
        if mount --bind "$SRC" "$TGT"; then echo "✓ 已建立单文件挂载"; else echo "✗ 单文件挂载失败(将回退原版字体)"; fi
        # 正常路径:显式重启 xochitl 后撤销兜底 trap(避免重复触发)
        systemctl start xochitl
        trap - EXIT HUP INT TERM
    fi
    systemctl restart bookbridge.service 2>/dev/null || true
    sleep 1
    echo "bookbridge: $(systemctl is-active bookbridge.service 2>/dev/null)"
    echo "xochitl:    $(systemctl is-active xochitl 2>/dev/null)"
'

say "3/4 (已并入上一步:迁移+重启同块完成)"

say "4/4 验证"
"${SSH[@]}" '
    echo "--- noto 相关挂载(应只见单个 ttf 文件被 bind)---"
    grep noto /proc/mounts || echo "(无 noto 挂载!)"
    echo
    echo "--- 原版 Noto 字体是否仍在(单文件挂载不应遮挡)---"
    fc-list 2>/dev/null | grep -i noto | head -12
    echo
    echo "--- CJK 回退命中(应指向被挂载的 ttf)---"
    fc-match "Noto Serif SC" 2>/dev/null || true
    fc-match serif:lang=zh 2>/dev/null || true
    echo
    echo "--- pre-start 钩子就位 ---"
    ls -l /home/root/xovi/scripts/pre-start/paperlite-mounts.sh
'
cat <<'DONE'

================ 持久化部署完成 ================
现在重启设备验证:字体应保持你选的中文字体(不回退原版),
休眠屏也保留。重启后 xovi pre-start 钩子会自动重挂这两项。
(若验证里「原版 Noto 字体」列表为空,说明单文件挂载没生效,告诉我。)
================================================
DONE
