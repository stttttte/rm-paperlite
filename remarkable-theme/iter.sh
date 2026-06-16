#!/bin/bash
# 自主迭代：推主题补丁 → 热加载(dofile) → 刷新 FileManager → 截图 → 拉回本地
# 用法: ./iter.sh [本地输出png名]   默认 /tmp/ko-iter.png
set -uo pipefail
KEY=~/.ssh/id_ed25519_remarkable
IP=10.11.99.1
D=/home/root/xovi/exthome/appload/koreader
OUT="${1:-/Users/liusidi/.claude/jobs/3eee097f/tmp/ko-iter.png}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# 1) 推主题补丁
scp -i "$KEY" -q "$DIR"/patches/2-remarkable-theme.lua "root@$IP:$D/patches/" 2>/dev/null

# 2) 注入: 重置 wrap 标志 → dofile 补丁(重新应用) → reinit FileManager
cat > /tmp/iter-eval.lua <<'LUA'
-- 清 wrap 标志,让补丁里的 monkey-patch 能重新包裹(取最新逻辑)
local ButtonDialog = package.loaded["ui/widget/buttondialog"]
local Menu = package.loaded["ui/widget/menu"]
local FM = package.loaded["apps/filemanager/filemanager"]
if Menu then Menu._rm_pageinfo_wrapped = nil end
if ButtonDialog then ButtonDialog._rm_drawer_wrapped = nil end
if FM then FM._rm_icons_wrapped = nil; FM._rm_plus_wrapped = nil; FM._rm_nav_wrapped = nil end
local ok, err = pcall(dofile, "/home/root/xovi/exthome/appload/koreader/patches/2-remarkable-theme.lua")
-- 重建文件管理器界面(让 setupLayout wrap / 新字号生效)
if FM and FM.instance then pcall(function() FM.instance:reinit(FM.instance.file_chooser.path) end) end
return (ok and "reapplied ok" or ("ERR " .. tostring(err)))
LUA
scp -i "$KEY" -q /tmp/iter-eval.lua "root@$IP:/tmp/ko-eval.lua" 2>/dev/null

# 3) 等热加载执行
sleep 3
echo "eval: $(ssh -i "$KEY" root@$IP 'cat /tmp/ko-eval.out 2>/dev/null' 2>/dev/null)"

# 4) 截图 + 拉回
ssh -i "$KEY" root@$IP "touch /tmp/ko-shot" 2>/dev/null
sleep 2
scp -i "$KEY" -q "root@$IP:/tmp/ko-screen.png" "$OUT" 2>/dev/null
echo "screenshot -> $OUT"
