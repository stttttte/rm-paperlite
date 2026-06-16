#!/bin/bash
# 墨阅 · KOReader 改 reMarkable 风（批次1：Inter 界面字体 + 书库封面网格）
# 用法: ./apply-skin.sh [设备IP]   USB 默认 10.11.99.1
# 回滚: ./apply-skin.sh --revert [IP]
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KEY=~/.ssh/id_ed25519_remarkable
IP="${2:-10.11.99.1}"
[ "${1:-}" = "--revert-ip" ] && IP="${1}"
SSH=(ssh -i "$KEY" -o ConnectTimeout=8 "root@$IP")
D=/home/root/xovi/exthome/appload/koreader
FONT=$D/frontend/ui/font.lua
CB=$D/plugins/coverbrowser.koplugin/main.lua

if [ "${1:-}" = "--revert" ]; then
    "${SSH[@]}" "
        [ -f $FONT.skinbak ] && cp $FONT.skinbak $FONT && echo '✓ 还原 font.lua'
        [ -f $CB.skinbak ] && cp $CB.skinbak $CB && echo '✓ 还原 coverbrowser'
        rm -rf $D/cache/fontlist
    "
    echo "已还原。重启界面: ssh root@$IP /home/root/xovi/start"
    exit 0
fi

echo "== 0/4 备份要改的文件（仅 2 个，回滚用）=="
"${SSH[@]}" "
    [ -f $FONT.skinbak ] || cp $FONT $FONT.skinbak
    [ -f $CB.skinbak ]   || cp $CB $CB.skinbak
    echo '✓ font.lua / coverbrowser main.lua 已备份'
"

echo "== 1/4 推送 Inter 字体 =="
scp -i "$KEY" -q "$DIR"/fonts/Inter-Regular.ttf "$DIR"/fonts/Inter-Medium.ttf "$DIR"/fonts/Inter-SemiBold.ttf "root@$IP:$D/fonts/"
echo "✓ Inter ×3 已就位"

echo "== 2/4 界面字体 NotoSans → Inter（只改 fontmap 区,保留 fallback 与等宽）=="
"${SSH[@]}" "
    # fontmap 块在 40-84 行：正文/标题/页脚等换 Inter，等宽(DroidSansMono)不动
    sed -i '40,84 s/NotoSans-Regular.ttf/Inter-Regular.ttf/g' $FONT
    sed -i '40,84 s/NotoSans-Bold.ttf/Inter-SemiBold.ttf/g'   $FONT
    # 让 Inter 的加粗用 SemiBold 变体
    grep -q 'Inter-Regular.ttf.*Inter-SemiBold' $FONT || \
      sed -i '/_bold_font_variant\[\"NotoSans-Italic.ttf\"\]/a _bold_font_variant[\"Inter-Regular.ttf\"] = \"Inter-SemiBold.ttf\"' $FONT
    echo '✓ 界面字体已切 Inter（中文自动回退思源黑体）'
"

echo "== 3/4 书库默认封面网格（coverbrowser mosaic_image）=="
"${SSH[@]}" "
    sed -i 's#setupFileManagerDisplayMode(BookInfoManager:getSetting(\"filemanager_display_mode\"))#setupFileManagerDisplayMode(BookInfoManager:getSetting(\"filemanager_display_mode\") or \"mosaic_image\")#' $CB
    grep -q 'or \"mosaic_image\"' $CB && echo '✓ 书库默认网格已设' || echo '⚠ 网格默认未匹配到(可能已改过)'
    rm -rf $D/cache/fontlist
"

echo "== 4/4 重启界面（约 20 秒生效）=="
"${SSH[@]}" "nohup /home/root/xovi/start >/tmp/xovi-skin.log 2>&1 & echo 触发完成"
echo ""
echo "✅ 批次1 完成。打开 KOReader 看：①界面字体变 Inter 几何无衬线 ②书库变封面网格"
echo "   回滚: ./apply-skin.sh --revert"
