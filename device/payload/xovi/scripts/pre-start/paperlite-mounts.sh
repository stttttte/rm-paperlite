#!/bin/bash
# 墨阅 · 开机持久化挂载(xovi pre-start 钩子)
# 执行时机:xovi/start 在「重启 xochitl 读字体」之前先跑本目录所有 *.sh,
#           因此这里挂好后,被 xovi 重启的 xochitl 启动时即读到自定义字体。
# 设计要点:
#   - 单文件 bind-mount —— 只覆盖目标文件本身,不会遮住同目录其它原版 Noto 字体
#     (整目录挂载会让拉丁/等宽/emoji 变方框,坑)。
#   - 源全在 /home/root 下 —— 扛 OS 更新(根分区会被整块替换,/home 保留)。
#   - bind-mount 是内核运行时状态,重启即失 —— 故每次开机由本钩子重挂。
#   - 幂等:查 /proc/mounts 已挂则跳过。注意 busybox `mountpoint -q` 对【文件】
#     挂载点判断失效(只认目录),会导致每次重启重复堆叠 —— 故必须用 /proc/mounts。

# 已挂载判断(对文件挂载点可靠;mountpoint -q 对文件失效)
is_mounted() { grep -qF " $1 " /proc/mounts; }

# 1) EPUB 中文阅读字体:把用户选定的字体覆盖到系统 CJK 回退文件
FONT_SRC=/home/root/ttf-noto/NotoSerifSC-VariableFont_wght.ttf
FONT_TGT=/usr/share/fonts/ttf/noto/NotoSerifSC-VariableFont_wght.ttf
if [ -f "$FONT_SRC" ] && [ -f "$FONT_TGT" ]; then
    is_mounted "$FONT_TGT" || mount --bind "$FONT_SRC" "$FONT_TGT"
fi

# 2) 自定义休眠屏(休眠时才读,时机不敏感,但一并在此重挂最省心)
SS_SRC=/home/root/paperlite/suspended.png
SS_TGT=/usr/share/remarkable/suspended.png
if [ -f "$SS_SRC" ] && [ -f "$SS_TGT" ]; then
    is_mounted "$SS_TGT" || mount --bind "$SS_SRC" "$SS_TGT"
fi
