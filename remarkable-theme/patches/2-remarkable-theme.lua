--[[
纸镇 · reMarkable 主题包  (KOReader userpatch, priority = late)
非侵入式：只做 monkey-patch / 令牌覆写，不改 KOReader 核心源码 → 升级可存活。
文件名前缀 2 = late 优先级（reader.lua 在 UIManager 就绪后执行，Screen 可用）。

分阶段累加（每阶段独立可验证）：
  [Phase 1] 全局设计令牌：直角 / 1px 细线 / reMarkable 留白 / Inter 字体   ← 当前
  [Phase 2] 主屏：reMarkable 式顶栏 + 标签 + 封面网格
  [Phase 3] 阅读界面：隐藏式顶栏 + 极简底栏
  [Phase 4] 菜单 / 设置 / 对话框重皮
  [Phase 5] 图标全套替换
--]]

local logger = require("logger")
local Screen = require("device").screen

logger.info("[rM-theme] ===== applying (phase1: global tokens) =====")

-- ---------- Phase 1: 全局设计令牌 ----------
do
    local Size = require("ui/size")

    -- 直角（reMarkable 方正，无圆角）
    Size.radius.default = 0
    Size.radius.window  = 0
    Size.radius.button  = 0

    -- 1px 发丝细线（reMarkable 的细分隔线）
    local hair = Screen:scaleBySize(1)
    Size.border.default = hair
    Size.border.button  = hair
    Size.border.window  = hair
    Size.border.thin    = hair

    logger.info("[rM-theme] phase1 tokens applied (radius=0, border=1px)")
end

-- ---------- Phase 1: 界面字体 → Inter（中文回退思源黑体）----------
-- 放进主题包，使核心 font.lua 可还原为原版。
do
    local ok, Font = pcall(require, "ui/font")
    if ok and Font and Font.fontmap then
        local fm = Font.fontmap
        local INTER       = "Inter-Regular.ttf"
        local INTER_BOLD  = "Inter-SemiBold.ttf"
        -- 正文/页脚/信息等无衬线项 → Inter Regular
        for _, k in ipairs({ "cfont","ffont","smallffont","largeffont","rifont","pgfont",
                             "hfont","infofont","smallinfofont","x_smallinfofont","xx_smallinfofont" }) do
            if fm[k] then fm[k] = INTER end
        end
        -- 标题/加粗项 → Inter SemiBold
        for _, k in ipairs({ "tfont","smalltfont","x_smalltfont","smallinfofontbold" }) do
            if fm[k] then fm[k] = INTER_BOLD end
        end
        -- 让 Inter 的“加粗变体”解析到 SemiBold
        local okv, _ = pcall(function()
            Font._bold_font_variant = Font._bold_font_variant or {}
        end)
        logger.info("[rM-theme] phase1 UI font -> Inter")
    else
        logger.warn("[rM-theme] phase1 font: ui/font not patchable")
    end
end

logger.info("[rM-theme] ===== phase1 done =====")

-- ---------- Phase 2b: 瘦身（标题栏 + 底部翻页都太大）----------
-- 必须在 require FileManager(会连带加载 titlebar/menu) 之前改图标尺寸，
-- 因为 titlebar/menu 在模块加载时就把 DGENERIC_ICON_SIZE 捕获成局部变量。
do
    -- 1) 全局图标缩小 40 -> 26：缩小顶栏 home/加号 + 底部翻页 chevron
    if G_defaults then
        G_defaults:saveSetting("DGENERIC_ICON_SIZE", 26)
        logger.info("[rM-theme] phase2b icon size 40->26")
    end
    -- 2) 标题字号缩小，让标题栏更扁(reMarkable 式)
    local ok, Font = pcall(require, "ui/font")
    if ok and Font and Font.sizemap then
        Font.sizemap.smalltfont   = 18   -- 全屏标题栏标题(原24)
        Font.sizemap.x_smalltfont = 16    -- 原22
        logger.info("[rM-theme] phase2b title font 24->18")
    end
end

-- ---------- Phase 2a: 主屏顶栏品牌化（KOReader → 书库）+ 2d 换图标 ----------
-- 注意：此处 require 会加载 titlebar，必须放在 Phase 2b 改完图标尺寸之后。
do
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok and FileManager then
        FileManager.title = "书库"
        logger.info("[rM-theme] phase2a FileManager title -> 书库")
        -- Phase 2d: 顶栏图标 左=文件柜, 右=菜单(包裹 setupLayout,建完顶栏后换)
        if not FileManager._rm_icons_wrapped then
            local orig_setup = FileManager.setupLayout
            function FileManager:setupLayout()
                orig_setup(self)
                if self.title_bar then
                    if self.title_bar.setLeftIcon  then self.title_bar:setLeftIcon("appbar.filebrowser") end
                    if self.title_bar.setRightIcon then self.title_bar:setRightIcon("appbar.menu") end
                end
            end
            FileManager._rm_icons_wrapped = true
            logger.info("[rM-theme] phase2d icons -> filebrowser/menu")
        end
    else
        logger.warn("[rM-theme] phase2a: filemanager not patchable")
    end
end

-- ---------- Phase 2c: 底部页码 → reMarkable 式细线 (——— 4 ———) ----------
-- 包裹 Menu:updatePageInfo：保留原逻辑(焦点等)，再隐藏 chevron、改成细线+页码。
-- 翻页仍可用左右滑动；点页码仍可"跳到第N页"。
do
    local ok, Menu = pcall(require, "ui/widget/menu")
    if ok and Menu and Menu.updatePageInfo and not Menu._rm_pageinfo_wrapped then
        local orig = Menu.updatePageInfo
        function Menu:updatePageInfo(select_number)
            orig(self, select_number)
            -- 隐藏四个 chevron 翻页箭头
            if self.page_info_left_chev then self.page_info_left_chev:hide() end
            if self.page_info_right_chev then self.page_info_right_chev:hide() end
            if self.page_info_first_chev then self.page_info_first_chev:hide() end
            if self.page_info_last_chev then self.page_info_last_chev:hide() end
            -- 页码改成细线样式（短线 + 小字号）
            if self.page_info_text and self.item_table and #self.item_table > 0 then
                local dash = string.rep("—", 5)
                local label
                if self.page_num and self.page_num > 1 then
                    label = dash .. "  " .. self.page .. " / " .. self.page_num .. "  " .. dash
                else
                    label = dash .. "  " .. (self.page or 1) .. "  " .. dash
                end
                self.page_info_text.text_font_size = 13  -- 数字+线都变小
                self.page_info_text:setText(label)
            end
        end
        Menu._rm_pageinfo_wrapped = true
        logger.info("[rM-theme] phase2c footer -> thin line style")
    end
end

-- ---------- Phase 2e: 右图标菜单 → reMarkable 式右侧抽屉 + 小字号 ----------
do
    local okb, ButtonDialog = pcall(require, "ui/widget/buttondialog")
    local okl, LeftContainer = pcall(require, "ui/widget/container/leftcontainer")
    -- 1) 给 ButtonDialog 加 rm_drawer 模式：贴【左边】(reMarkable 侧栏从左滑出)
    if okb and okl and ButtonDialog and not ButtonDialog._rm_drawer_wrapped then
        local VerticalSpan = require("ui/widget/verticalspan")
        local orig_init = ButtonDialog.init
        function ButtonDialog:init()
            orig_init(self)
            if self.rm_drawer then
                local screenH = Screen:getHeight()
                local frame = self.movable and self.movable[1]   -- FrameContainer
                if frame then
                    frame.radius = 0                              -- 直角(贴边面板)
                    local vg = frame[1]                           -- 内部 VerticalGroup
                    if vg and vg.getSize then
                        local fh = screenH - frame:getSize().h    -- 需要补足的高度
                        if fh > 0 then
                            table.insert(vg, VerticalSpan:new{ width = fh })
                            if vg.resetLayout then vg:resetLayout() end
                        end
                    end
                end
                self[1] = LeftContainer:new{
                    dimen = Screen:getSize(),
                    self.movable,
                }
            end
        end
        ButtonDialog._rm_drawer_wrapped = true
        logger.info("[rM-theme] phase2e ButtonDialog rm_drawer mode (LEFT) added")
    end
    -- ---- Phase 4: reMarkable 式单栏设置(用 KOReader 原生 Menu,最稳,不手搓 widget 树)----
    -- 教训:手搓 VerticalGroup 全屏组件,一个 nil 子项就崩全机,且 qtfb 无法 SSH 重启。
    -- 改用被测最多的 Menu 控件:叶子项走 onMenuSelect→onMenuChoice→item.callback,零 nil 风险;
    -- 标题栏自带 ✕ 关闭;close_callback 留空 → 信息类项在列表之上弹 InfoMessage,关掉即回列表。
    rmShowSettings = function(fm)
        local UIManager   = require("ui/uimanager")
        local Menu        = require("ui/widget/menu")
        local InfoMessage = require("ui/widget/infomessage")

        local function info(text)
            UIManager:show(InfoMessage:new{ text = text })
        end
        local function aboutText()
            local ver = "KOReader"
            pcall(function()
                local V = require("version")
                if V and V.getCurrentRevision then ver = "KOReader " .. tostring(V:getCurrentRevision()) end
            end)
            local fw = "3.22"
            pcall(function()
                local f = io.open("/etc/version", "r")
                if f then local s = f:read("*l"); f:close(); if s and #s > 0 then fw = s end end
            end)
            return "纸镇 · reMarkable 风\n\n基于 " .. ver .. "\n固件 " .. fw
        end
        local function storageText()
            local out = "存储信息读取失败"
            pcall(function()
                local p = io.popen("df -h /home/root 2>/dev/null | tail -n +2")
                if p then local s = p:read("*a"); p:close()
                    if s and #s > 0 then out = "可用空间:\n\n" .. s end
                end
            end)
            return out
        end

        local settings_menu
        settings_menu = Menu:new{
            title = "设置",
            is_borderless = true,
            is_popout = false,
            item_table = {
                { text = "存储空间", callback = function() info(storageText()) end },
                { text = "关于本机", callback = function() info(aboutText()) end },
                { text = "全部设置(亮度·字体·网络…)", callback = function()
                    UIManager:close(settings_menu)
                    if fm and fm.menu then pcall(function() fm.menu:onShowMenu() end) end
                end },
            },
        }
        UIManager:show(settings_menu)
    end

    -- 2) ☰ 菜单 → reMarkable 式左侧导航栏(全部/PDF/电子书/收藏/设置)+ 真实筛选
    local okf, FileManager = pcall(require, "apps/filemanager/filemanager")
    local okd, DocumentRegistry = pcall(require, "document/documentregistry")
    if okf and okb and FileManager and not FileManager._rm_nav_wrapped then
        local UIManager = require("ui/uimanager")
        -- 按扩展名筛选并刷新文件列表
        local function applyFilter(fm, matchfn)
            local fc = fm.file_chooser
            if not fc then return end
            if matchfn then
                fc.file_filter = function(fn) return matchfn(fn:lower()) end
            else
                fc.file_filter = function(fn) return DocumentRegistry:hasProvider(fn) end
            end
            pcall(function() fc:refreshPath() end)
        end
        function FileManager:onShowPlusMenu()
            local fm = self
            local function nav(label, matchfn)
                return { text = label, font_size = 18, align = "left",
                    callback = function()
                        if fm.nav_dialog then UIManager:close(fm.nav_dialog) end
                        applyFilter(fm, matchfn)
                    end }
            end
            local buttons = {
                { nav("全部", nil) },
                { nav("PDF", function(s) return s:match("%.pdf$") end) },
                { nav("电子书", function(s)
                    return s:match("%.epub$") or s:match("%.mobi$") or s:match("%.azw3?$")
                        or s:match("%.fb2$") or s:match("%.txt$") or s:match("%.cbz$") end) },
                { { text = "收藏", font_size = 18, align = "left", callback = function()
                    if fm.nav_dialog then UIManager:close(fm.nav_dialog) end
                    if fm.collections then pcall(function() fm.collections:onShowColl() end) end
                end } },
                { { text = "设置", font_size = 18, align = "left", callback = function()
                    if fm.nav_dialog then UIManager:close(fm.nav_dialog) end
                    -- 单栏设置(原生 Menu,稳)
                    pcall(function() rmShowSettings(fm) end)
                end } },
            }
            fm.nav_dialog = ButtonDialog:new{
                title = "书库",
                title_align = "center",
                buttons = buttons,
                rm_drawer = true,     -- 左侧栏
                width_factor = 0.32,  -- 窄侧栏
            }
            UIManager:show(fm.nav_dialog)
            return true
        end
        FileManager._rm_nav_wrapped = true
        logger.info("[rM-theme] phase3 left nav sidebar (filters+settings)")
    end
end

logger.info("[rM-theme] ===== phase2 done =====")
