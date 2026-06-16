--[[
纸镇开发工具 (仅开发期用，发布前删除)
后台每秒检查两个触发文件：
  /tmp/ko-shot      → 截当前屏到 /tmp/ko-screen.png
  /tmp/ko-eval.lua  → dofile() 热执行(实时注入代码,免重开)；结果写 /tmp/ko-eval.out
让 Mac 端可以：改补丁→scp→dofile 热加载→截图，完全自主迭代。
--]]
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")

local SHOT_TRIG = "/tmp/ko-shot"
local SHOT_OUT  = "/tmp/ko-screen.png"
local EVAL_TRIG = "/tmp/ko-eval.lua"
local EVAL_OUT  = "/tmp/ko-eval.out"

local function exists(p)
    local f = io.open(p, "r")
    if f then f:close(); return true end
    return false
end

local function writeFile(p, s)
    local f = io.open(p, "w")
    if f then f:write(s); f:close() end
end

local function poll()
    -- 热执行注入的 Lua
    if exists(EVAL_TRIG) then
        local chunk, lerr = loadfile(EVAL_TRIG)
        os.remove(EVAL_TRIG)
        if chunk then
            local ok, res = pcall(chunk)
            writeFile(EVAL_OUT, (ok and "OK\n" or "ERR\n") .. tostring(res))
            logger.info("[rM-devshot] eval", ok and "ok" or ("err: " .. tostring(res)))
        else
            writeFile(EVAL_OUT, "LOADERR\n" .. tostring(lerr))
        end
    end
    -- 截图
    if exists(SHOT_TRIG) then
        os.remove(SHOT_TRIG)
        local ok, err = pcall(function() Screen:shot(SHOT_OUT) end)
        logger.info("[rM-devshot] shot ->", SHOT_OUT, ok and "ok" or tostring(err))
    end
    UIManager:scheduleIn(1, poll)
end

UIManager:scheduleIn(3, poll)
logger.info("[rM-devshot] poller armed (shot + eval)")
