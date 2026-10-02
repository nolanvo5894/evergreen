--[[--
Full-screen home: status bar, date, the book in progress, recent books and a
grid of app tiles. Shown by main.lua on top of the file manager.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local DocSettings = require("docsettings")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local ReadHistory = require("readhistory")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local GRAY = Blitbuffer.COLOR_DARK_GRAY
local LIGHT = Blitbuffer.COLOR_LIGHT_GRAY

---------------------------------------------------------------------------
-- Small building blocks

-- Anything tappable: wraps one child and calls back on tap / hold.
local Tappable = InputContainer:extend{
    callback = nil,
    hold_callback = nil,
}

function Tappable:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ w = size.w, h = size.h }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function Tappable:onTapSelect()
    if self.callback then
        -- run after the tap is fully handled, so closing the home is safe
        UIManager:nextTick(self.callback)
    end
    return true
end

function Tappable:onHoldSelect()
    if self.hold_callback then
        UIManager:nextTick(self.hold_callback)
        return true
    end
end

local function text(str, face, width, color)
    return TextWidget:new{
        text = str or "",
        face = face,
        max_width = width,
        fgcolor = color,
    }
end

local function bookInfo(file)
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    local info = ok and BookInfoManager:getBookInfo(file, true) or nil
    local props = {}
    local settings = DocSettings:hasSidecarFile(file) and DocSettings:open(file)
    if settings then
        props = settings:readSetting("doc_props") or {}
    end
    local title = (info and info.title) or props.title
    if not title or title == "" then
        title = file:match("([^/]+)$"):gsub("%.%w+$", "")
    end
    local authors = (info and info.authors) or props.authors
    if authors then authors = authors:gsub("\n.*", "") end -- first author only
    return {
        file = file,
        title = title,
        authors = authors,
        cover_bb = info and info.cover_bb,
        indexed = info ~= nil,
        percent = settings and settings:readSetting("percent_finished"),
        status = settings and (settings:readSetting("summary") or {}).status,
    }
end

local Covers = require("egcovers")

-- Cover in a w x h slot: fitted, rounded corners; title card when missing.
local function cover(book, w, h)
    return Covers.card(book, w, h)
end

---------------------------------------------------------------------------

local HomeWidget = InputContainer:extend{
    plugin = nil, -- the evergreen plugin (gives access to the file manager ui)
    covers_fullscreen = true,
}

function HomeWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.margin = Screen:scaleBySize(22)
    self.inner_w = self.dimen.w - 2 * self.margin
    self.to_index = {}
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self:build()
    if #self.to_index > 0 then
        UIManager:nextTick(function()
            local ok, BookInfoManager = pcall(require, "bookinfomanager")
            if ok then BookInfoManager:extractInBackground(self.to_index) end
        end)
    end
    self.clock_task = function() self:refreshStatus() end
    UIManager:scheduleIn(60 - os.date("*t").sec, self.clock_task)
end

function HomeWidget:build()
    local w = self.inner_w
    local body = VerticalGroup:new{ align = "left" }
    self.body = body
    table.insert(body, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    table.insert(body, self:statusBar()) -- body[2], swapped by refreshStatus
    table.insert(body, VerticalSpan:new{ width = Screen:scaleBySize(14) })
    table.insert(body, HorizontalGroup:new{
        align = "bottom",
        text(os.date("%A"), Font:getFace("tfont", 26), w),
        text(os.date("   %B %-d"), Font:getFace("cfont", 18), w, GRAY),
    })
    table.insert(body, VerticalSpan:new{ width = Screen:scaleBySize(12) })

    -- most recent first; one entry per title (the same book can exist twice)
    local books, seen = {}, {}
    for _, entry in ipairs(ReadHistory.hist) do
        -- skip missing files and the bundled help (quickstart guide)
        local bundled = entry.file:match("/help/") or entry.file:match("quickstart")
        if not entry.dim and not bundled and lfs.attributes(entry.file, "mode") == "file" then
            local key = entry.text:lower():gsub("%.%w+$", ""):gsub("[^%w]", "")
            local props = DocSettings:hasSidecarFile(entry.file)
                and DocSettings:open(entry.file):readSetting("doc_props")
            if props and props.title then key = props.title:lower() end
            if not seen[key] then
                seen[key] = true
                table.insert(books, entry.file)
                if #books >= 6 then break end
            end
        end
    end

    if books[1] then
        table.insert(body, self:sectionLabel(_("CONTINUE READING")))
        table.insert(body, self:continueCard(bookInfo(books[1])))
    else
        table.insert(body, self:sectionLabel(_("NOTHING OPEN YET")))
        table.insert(body, text(_("Open a book from Library or Bookie."), Font:getFace("cfont", 18), w, GRAY))
    end
    table.insert(body, VerticalSpan:new{ width = Screen:scaleBySize(14) })

    if books[2] then
        table.insert(body, self:sectionLabel(_("RECENT")))
        local row = HorizontalGroup:new{ align = "top" }
        local n = 5
        local gap = Screen:scaleBySize(12)
        local cw = math.floor((w - (n - 1) * gap) / n)
        local ch = math.floor(cw * 1.45)
        for i = 2, math.min(#books, n + 1) do
            local book = bookInfo(books[i])
            self:queueIndex(book, cw, ch)
            if i > 2 then table.insert(row, HorizontalSpan:new{ width = gap }) end
            table.insert(row, Tappable:new{
                callback = function() self:openBook(book.file) end,
                VerticalGroup:new{
                    align = "left",
                    cover(book, cw, ch),
                    VerticalSpan:new{ width = Screen:scaleBySize(4) },
                    text(book.title, Font:getFace("cfont", 13), cw),
                    text(book.percent and T(_("%1%"), math.floor(book.percent * 100)) or _("new"),
                         Font:getFace("cfont", 11), cw, GRAY),
                },
            })
        end
        table.insert(body, row)
        table.insert(body, VerticalSpan:new{ width = Screen:scaleBySize(14) })
    end

    table.insert(body, self:sectionLabel(_("APPS")))
    table.insert(body, self:tiles())

    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        padding_left = self.margin,
        padding_right = self.margin,
        body,
    }
end

function HomeWidget:queueIndex(book, w, h)
    if not book.indexed then
        table.insert(self.to_index, {
            filepath = book.file,
            cover_specs = { max_cover_w = w, max_cover_h = h },
        })
    end
end

function HomeWidget:sectionLabel(str)
    return VerticalGroup:new{
        align = "left",
        text(str, Font:getFace("tfont", 13), self.inner_w, GRAY),
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
    }
end

function HomeWidget:statusBar()
    local w = self.inner_w
    local powerd = Device:getPowerDevice()
    local batt = powerd:getCapacity()
    local charging = powerd:isCharging() and " +" or ""
    local wifi
    if NetworkMgr:isWifiOn() then
        wifi = NetworkMgr:isConnected() and _("Wi-Fi") or _("Wi-Fi …")
    else
        wifi = _("Wi-Fi off")
    end
    local right = T("%1    %2%%3", wifi, batt, charging)
    local face = Font:getFace("cfont", 15)
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = Screen:scaleBySize(26) },
        LeftContainer:new{
            dimen = Geom:new{ w = w, h = Screen:scaleBySize(26) },
            text(os.date("%-I:%M %p"), face, w / 2),
        },
        RightContainer:new{
            dimen = Geom:new{ w = w, h = Screen:scaleBySize(26) },
            text(right, face, w / 2),
        },
    }
end

function HomeWidget:refreshStatus()
    -- swap in a fresh status line and repaint just that strip
    self.body[2]:free()
    self.body[2] = self:statusBar()
    self.body:resetLayout()
    UIManager:setDirty(self, function()
        return "fast", Geom:new{ x = 0, y = 0, w = self.dimen.w, h = Screen:scaleBySize(40) }
    end)
    UIManager:scheduleIn(60, self.clock_task)
end

function HomeWidget:continueCard(book)
    local w = self.inner_w
    local cw = math.floor(w * 0.24)
    local ch = math.floor(cw * 1.5)
    self:queueIndex(book, cw, ch)
    local gap = Screen:scaleBySize(16)
    local tw = w - cw - gap
    local info = VerticalGroup:new{ align = "left" }
    -- title: natural height, capped so a long title can't push the rest off
    local title_args = { text = book.title, face = Font:getFace("tfont", 24), width = tw }
    local title = TextBoxWidget:new(title_args)
    local max_h = math.floor(ch * 0.40)
    if title:getSize().h > max_h then
        title:free()
        title_args.height = max_h
        title_args.height_overflow_show_ellipsis = true
        title = TextBoxWidget:new(title_args)
    end
    table.insert(info, title)
    if book.authors then
        table.insert(info, VerticalSpan:new{ width = Screen:scaleBySize(4) })
        table.insert(info, text(book.authors, Font:getFace("cfont", 17), tw, GRAY))
    end
    table.insert(info, VerticalSpan:new{ width = Screen:scaleBySize(18) })
    local pct = book.percent or 0
    table.insert(info, ProgressWidget:new{
        width = tw,
        height = Screen:scaleBySize(8),
        percentage = pct,
        margin_h = 0,
        margin_v = 0,
        radius = Screen:scaleBySize(3),
        bordersize = Size.border.thin,
        fillcolor = Blitbuffer.COLOR_BLACK,
    })
    table.insert(info, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(info, text(T(_("%1% read"), math.floor(pct * 100)), Font:getFace("cfont", 15), tw, GRAY))
    table.insert(info, VerticalSpan:new{ width = Screen:scaleBySize(18) })
    table.insert(info, text(_("Tap to continue  ›"), Font:getFace("tfont", 16), tw))

    return Tappable:new{
        callback = function() self:openBook(book.file) end,
        HorizontalGroup:new{
            align = "top",
            cover(book, cw, ch),
            HorizontalSpan:new{ width = gap },
            info,
        },
    }
end

---------------------------------------------------------------------------
-- Tiles

function HomeWidget:tileDefs()
    local p = self.plugin
    local ui = p.ui
    local defs = {
        { _("Library"), _("All books"), function() self:closeThen(function() p:showLibrary(p:libraryDir(), _("Library")) end) end },
        { _("Bookie"), T(_("%1 books"), p:countBooks(p.BOOKIE_DIR)), function() self:closeThen(function() p:showLibrary(p.BOOKIE_DIR, _("Bookie")) end) end },
        { _("History"), _("Recently read"), function() self:closeThen(function() ui.history:onShowHist() end) end },
        { _("Favorites"), _("Collections"), function() self:closeThen(function() ui.collections:onShowColl() end) end },
        { _("Notes"), _("notes.txt"), function()
            self:closeThen(function() ui.texteditor:checkEditFile(p.NOTES_FILE, false, true) end)
        end },
        { _("Terminal"), _("Shell"), function() self:closeThen(function() ui.terminal:onTerminalStart() end) end },
        { _("Wi-Fi"), NetworkMgr:isWifiOn() and _("On – tap to turn off") or _("Off – tap to turn on"),
          function() p:toggleWifi(self) end },
        { _("SSH"), (ui.SSH and ui.SSH:isRunning()) and _("Running :2222") or _("Stopped"),
          function() p:toggleSSH(self) end },
        { _("Settings"), _("All settings"), function() self:closeThen(function() ui.menu:onShowMenu() end) end },
        { _("Sleep"), _("Suspend"), function() UIManager:suspend() end },
        { _("Files"), _("File browser"), function() p:openFolder(p:libraryDir()) end },
        { _("Kindle"), _("Exit to Amazon UI"), function() p:exitToKindle() end },
    }
    return defs
end

function HomeWidget:tiles()
    local cols = 4
    local gap = Screen:scaleBySize(10)
    local tw = math.floor((self.inner_w - (cols - 1) * gap) / cols)
    local th = Screen:scaleBySize(54)
    local grid = VerticalGroup:new{ align = "left" }
    local row
    for i, def in ipairs(self:tileDefs()) do
        if (i - 1) % cols == 0 then
            if row then
                table.insert(grid, row)
                table.insert(grid, VerticalSpan:new{ width = gap })
            end
            row = HorizontalGroup:new{ align = "top" }
        else
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        table.insert(row, self:tile(def[1], def[2], def[3], tw, th))
    end
    if row then table.insert(grid, row) end
    return grid
end

function HomeWidget:tile(label, sub, callback, w, h)
    local pad = Screen:scaleBySize(8)
    local bw = Size.border.button
    local cw = w - 2 * pad - 2 * bw
    return Tappable:new{
        callback = callback,
        FrameContainer:new{
            width = w,
            height = h,
            bordersize = bw,
            radius = Size.radius.button,
            padding = pad,
            LeftContainer:new{
                dimen = Geom:new{ w = cw, h = h - 2 * pad - 2 * bw },
                VerticalGroup:new{
                    align = "left",
                    text(label, Font:getFace("tfont", 18), cw),
                    VerticalSpan:new{ width = Screen:scaleBySize(2) },
                    text(sub, Font:getFace("cfont", 12), cw, GRAY),
                },
            },
        },
    }
end

---------------------------------------------------------------------------

function HomeWidget:openBook(file)
    self:closeThen(function()
        require("apps/reader/readerui"):showReader(file)
    end)
end

function HomeWidget:closeThen(fn)
    UIManager:close(self)
    if fn then UIManager:nextTick(fn) end
end

function HomeWidget:onClose()
    UIManager:close(self)
    return true
end

function HomeWidget:onCloseWidget()
    UIManager:unschedule(self.clock_task)
    self:free() -- releases cover blitbuffers
    if self.plugin.home == self then self.plugin.home = nil end
end

function HomeWidget:onShow()
    UIManager:setDirty(self, function() return "full", self.dimen end)
end

return HomeWidget
