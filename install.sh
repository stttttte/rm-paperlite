#!/bin/bash
# 墨阅 (PaperLite) 一键安装 —— 在 Mac 上运行
# 用法: ./install.sh [设备IP]   (USB 连接默认 10.11.99.1)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$DIR/device/payload"
IP="${1:-10.11.99.1}"
KEY="$HOME/.ssh/id_ed25519_remarkable"
SSH_OPTS=(-i "$KEY" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*"; exit 1; }

[ -d "$PAYLOAD/xovi" ] || fail "payload 不完整，请先确认 device/payload 已组装"

say "0/6 检查连接 ($IP)"
ping -c 1 -t 3 "$IP" >/dev/null 2>&1 || fail "无法连到 $IP。USB 连接请确认线已插好且设备亮屏；WiFi 请用设备的 WiFi IP 作为参数。"

say "1/6 配置 SSH 免密（只需输一次设备密码）"
if [ ! -f "$KEY" ]; then
    ssh-keygen -t ed25519 -N "" -f "$KEY" -C "paperlite" >/dev/null
fi
if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@$IP" true 2>/dev/null; then
    echo "请输入设备 SSH 密码（在设备 Settings → Help → About → Copyrights 页面底部）:"
    ssh-copy-id -i "$KEY" -o StrictHostKeyChecking=accept-new "root@$IP" >/dev/null
fi
ssh "${SSH_OPTS[@]}" "root@$IP" true || fail "SSH 免密配置失败"
echo "✓ SSH 就绪"

say "2/6 核对设备型号与固件"
ssh "${SSH_OPTS[@]}" "root@$IP" '
    MODEL=$(cat /sys/devices/soc0/machine 2>/dev/null || echo unknown)
    VER=$(grep -o "[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+" /etc/version 2>/dev/null || cat /etc/version 2>/dev/null || echo unknown)
    echo "设备: $MODEL"
    echo "固件: $VER"
    case "$MODEL" in
        *reMarkable\ 2*|*reMarkable2*) ;;
        *) echo "警告: 不是 reMarkable 2，payload 是 arm32 版，继续可能失败"; ;;
    esac
'

say "3/6 传输文件（约 180MB，USB 下 1-2 分钟）"
# 确保打包的是当前构建的二进制(否则全新安装会装到旧版,缺新功能)
if [ -f "$DIR/server/bookbridge-arm" ]; then
    cp "$DIR/server/bookbridge-arm" "$PAYLOAD/paperlite/bookbridge"
    echo "✓ 已用最新构建同步 payload 二进制"
fi
ssh "${SSH_OPTS[@]}" "root@$IP" 'mkdir -p /home/root/shims /home/root/paperlite/units /home/root/books'
tar -C "$PAYLOAD" -cf - xovi shims paperlite | ssh "${SSH_OPTS[@]}" "root@$IP" 'tar -xf - -C /home/root/'
# 系统分区 (/) 出厂即接近 100% 满：先清旧 journal 腾空间，再写实体 unit 文件
# （unit 必须是 /etc 实体文件且带 RequiresMountsFor=/home——软链到 /home 开机时会因挂载时序加载不到）
ssh "${SSH_OPTS[@]}" "root@$IP" '
    journalctl --vacuum-size=2M >/dev/null 2>&1 || true
    cat > /etc/systemd/system/bookbridge.service <<EOF
[Unit]
Description=PaperLite bookbridge
After=network.target home.mount
RequiresMountsFor=/home

[Service]
ExecStart=/home/root/paperlite/bookbridge
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/xovi-autostart.service <<EOF
[Unit]
Description=Start xovi at boot
After=xochitl.service home.mount
RequiresMountsFor=/home
ConditionPathExists=/home/root/xovi/auto-start-enabled

[Service]
Type=oneshot
ExecStart=/bin/bash /home/root/xovi/start
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    # 空文件 = systemd 当 masked 处理，必须确认写进去了
    [ -s /etc/systemd/system/bookbridge.service ] || { echo "unit 写入失败：系统分区没空间"; exit 1; }
'
echo "✓ 传输完成"

say "4/6 安装传书服务 + 关闭系统自动更新"
ssh "${SSH_OPTS[@]}" "root@$IP" '
    chmod +x /home/root/xovi/start /home/root/xovi/stock /home/root/xovi/rebuild_hashtable /home/root/paperlite/bookbridge
    # 开机持久化钩子(字体/休眠屏重挂)需可执行
    chmod +x /home/root/xovi/scripts/pre-start/*.sh /home/root/xovi/scripts/post-start/*.sh 2>/dev/null || true
    # 字体单文件挂载需要源文件:全新安装时从系统原版播种一份(之后网页可随意切换)
    STOCK=/usr/share/fonts/ttf/noto/NotoSerifSC-VariableFont_wght.ttf
    if [ ! -f /home/root/ttf-noto/NotoSerifSC-VariableFont_wght.ttf ] && [ -f "$STOCK" ]; then
        mkdir -p /home/root/ttf-noto
        cp "$STOCK" /home/root/ttf-noto/
        echo "✓ 已播种字体源文件"
    fi
    # 同时把纯净系统原版备份一份,供"思源宋体(原版)"还原选项(须在任何覆盖之前)
    if [ ! -f /home/root/paperlite/font-backup/NotoSerifSC-VariableFont_wght.ttf.orig ] && [ -f "$STOCK" ]; then
        mkdir -p /home/root/paperlite/font-backup
        cp "$STOCK" /home/root/paperlite/font-backup/NotoSerifSC-VariableFont_wght.ttf.orig
    fi
    systemctl daemon-reload
    systemctl enable --now bookbridge.service
    # 关掉 OTA，防止升级抹掉一切并堵死安装路线
    systemctl disable --now update-engine 2>/dev/null && echo "✓ update-engine 已禁用" || echo "(未找到 update-engine，跳过)"
    systemctl disable --now swupdate 2>/dev/null || true
    touch /home/root/xovi/auto-start-enabled
    systemctl enable xovi-autostart.service >/dev/null 2>&1
    echo "✓ bookbridge 已启动，开机自启已配置"
'

say "5/6 重建 QML 哈希表（关键步骤，请看设备屏幕）"
echo "接下来设备界面会重启一次，期间【如果设备屏幕提示输密码请在设备上输入】。"
echo "脚本检测到完成标志后会自动继续。"
ssh -t "${SSH_OPTS[@]}" "root@$IP" '/home/root/xovi/rebuild_hashtable' || fail "哈希表重建失败，可重跑本脚本"

say "6/6 启动 xovi"
ssh "${SSH_OPTS[@]}" "root@$IP" '/home/root/xovi/start'
sleep 3
ssh "${SSH_OPTS[@]}" "root@$IP" 'systemctl is-active bookbridge.service'

cat <<'DONE'

================ 安装完成 ================
✅ 网页管理     手机/电脑同 WiFi 浏览器开 http://<设备IP>:8866
               → 传书 / 休眠屏(自传+图库) / 切换中文字体 / 推送 KOReader 词典 / RSS 新闻
✅ 传书         侧边栏「传书」弹二维码,微信/相机扫码即传(txt/epub/pdf 自动转格式进原生书库)
✅ 点击翻页     原生阅读器内 点左侧=上一页 / 点右侧=下一页
✅ 中文字体     网页「阅读字体」切换;字体与休眠屏重启后自动重挂、不回退
✅ KOReader     侧边栏 → KOReader(查词/拼音输入在此:设置→Keyboard layout 加拼音)
✅ 自动更新     已关闭（防止固件升级抹掉本安装）

常用命令:
  ./deploy-persist.sh [IP]       增量部署最新 bookbridge + 持久化 + 屏保图库
  ./screensaver.sh <图片> [IP]   命令行换待机屏保
  ./uninstall.sh [IP]            完整卸载恢复原状
==========================================
DONE
