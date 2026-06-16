#!/bin/bash
# 墨阅 · 取字体 —— 重建本地 fonts/ 工作目录
# 仓库为保持轻量未提交字体(都是第三方、体积大)。本脚本从各字体上游官方发布页
# 拉取常用 CJK 字体到 ./fonts/。设备端的 Noto Serif SC 安装时会从设备自带字体
# 播种(见 install.sh),并不强依赖本目录;本目录主要用于网页「切换字体」的可选项。
#
# 用法: ./fetch-fonts.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p fonts fonts/native-cjk

get() { # get <url> <目标路径>
  local url="$1" out="$2"
  if [ -f "$out" ]; then echo "✓ 已存在 $out"; return; fi
  echo "↓ $out"
  curl -fL --retry 3 -o "$out" "$url" || echo "✗ 下载失败(跳过): $url"
}

echo "== 霞鹜文楷 LXGW WenKai (OFL) =="
get https://github.com/lxgw/LxgwWenKai/releases/latest/download/LXGWWenKai-Regular.ttf fonts/native-cjk/LXGWWenKai-Regular.ttf
get https://github.com/lxgw/LxgwWenKai/releases/latest/download/LXGWWenKai-Light.ttf   fonts/native-cjk/LXGWWenKai-Light.ttf
get https://github.com/lxgw/LxgwWenKai/releases/latest/download/LXGWWenKai-Medium.ttf  fonts/native-cjk/LXGWWenKai-Medium.ttf

echo "== 霞鹜文楷 屏幕版 LXGW WenKai Screen (OFL) =="
get https://github.com/lxgw/LxgwWenKai-Screen/releases/latest/download/LXGWWenKaiScreen.ttf fonts/native-cjk/LXGWWenKaiScreen.ttf

echo "== 朱雀仿宋 ZhuqueFangsong (OFL) =="
get https://github.com/TrionesType/zhuque/releases/latest/download/ZhuqueFangsong-Regular.ttf fonts/native-cjk/ZhuqueFangsong-Regular.ttf

cat <<'NOTE'

== 思源宋体/黑体 Noto CJK SC (OFL) ==
Noto 体积大且发布形态多变,请按需自行下载放进 ./fonts/ :
  - 思源宋体 Noto Serif SC : https://fonts.google.com/noto/specimen/Noto+Serif+SC
  - 思源黑体 Noto Sans  SC : https://fonts.google.com/noto/specimen/Noto+Sans+SC
  (设备安装无需此步:install.sh 会从设备出厂自带的 Noto Serif SC 播种一份。)

== as-noto 合并字体 ==
fonts/native-cjk/as-noto/ 下的 *-as-noto.ttf 是把 LXGW 与 Noto 合并生成的本地产物,
非上游可下;需要可用 fonttools merge 自行合成,普通安装用不到。

字体到手后即可正常使用网页「切换字体」功能。
NOTE
echo "完成。"
