--[[--
Contents panel: table of contents, bookmarks and highlights on three tabs of
one full-screen sheet. Paged (swipe or pager), current chapter marked; tapping
an entry jumps there and closes the panel.
--]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local EgUI = require("egui")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen
local S = EgUI.S

local Contents = InputContainer:extend{
    plugin = nil,
    tab = "contents", -- "contents" | "bookmarks" | "highlights"
    covers_fullscreen = true,
}

function Contents:init()
    self.ui = self.plugin.ui
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
    self.dithered = true
    self:collect()
    self.page = self:startPage()
    self:build()
end

function Contents:currentPage()
    if self.ui.paging then return self.ui.paging.current_page end
    return self.ui.document:getCurrentPage()
end

function Contents:collect()
    local toc = {}
    if self.ui.toc then
        self.ui.toc:fillToc()
        for _, e in ipairs(self.ui.toc.toc or {}) do
            if e.title and e.title ~= "" then table.insert(toc, e) end
        end
    end
    self.toc = toc
    local here = self:currentPage()
    self.current_toc = nil
    for i, e in ipairs(toc) do
        if e.page and e.page <= here then self.current_toc = i end
    end

    self.bookmarks, self.highlights = {}, {}
    for _, item in ipairs(self.ui.annotation and self.ui.annotation.annotations or {}) do
        if item.drawer then
            table.insert(self.highlights, item)
        else
            table.insert(self.bookmarks, item)
        end
    end
end

function Contents:perPage()
    return self.tab == "highlights" and 7 or 13
end

function Contents:items()
    if self.tab == "contents" then return self.toc end
    if self.tab == "bookmarks" then return self.bookmarks end
    return self.highlights
end

function Contents:startPage()
    if self.tab == "contents" and self.current_toc then
        return math.floor((self.current_toc - 1) / self:perPage()) + 1
    end
    return 1
end

function Contents:build()
    if self[1] then self[1]:free() end
    local w = self.dimen.w
    local inner = w - 2 * S(16)
    local props = self.ui.doc_props or {}
    local title = props.display_title or props.title or ""
    local items = self:items()
    local per = self:perPage()
    self.pages = math.max(1, math.ceil(#items / per))
    self.page = math.max(1, math.min(self.page, self.pages))

    local body = VerticalGroup:new{ align = "left" }
    table.insert(body, EgUI.header(inner, title, function() self:close() end))
    table.insert(body, EgUI.vspan(4))
    table.insert(body, EgUI.row({
        EgUI.chip(_("Contents"), self.tab == "contents", function() self:setTab("contents") end),
        EgUI.chip(T(_("Bookmarks · %1"), #self.bookmarks), self.tab == "bookmarks", function() self:setTab("bookmarks") end),
        EgUI.chip(T(_("Highlights · %1"), #self.highlights), self.tab == "highlights", function() self:setTab("highlights") end),
    }))
    table.insert(body, EgUI.vspan(10))
    table.insert(body, EgUI.line(inner, EgUI.GRAY))

    if #items == 0 then
        table.insert(body, EgUI.vspan(40))
        local empty = {
            contents = _("This book has no table of contents."),
            bookmarks = _("Tap the bookmark icon at the top of a page to add one."),
            highlights = _("Long-press text and choose Highlight to add one."),
        }
        table.insert(body, EgUI.textbox(empty[self.tab], 16, inner, { color = EgUI.GRAY, align = "center" }))
    else
        for i = (self.page - 1) * per + 1, math.min(#items, self.page * per) do
            table.insert(body, self:row(items[i], i, inner))
        end
    end

    self[1] = EgUI.sheet(w, self.dimen.h, OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = self.dimen.h - S(26) },
        body,
        VerticalGroup:new{
            EgUI.vspan(0),
            require("ui/widget/verticalspan"):new{ width = self.dimen.h - S(26) - S(40) },
            EgUI.pager(inner, self.page, self.pages, function(d) self:turn(d) end),
        },
    }, true)
end

function Contents:row(item, index, w)
    if self.tab == "contents" then
        local depth = math.max(0, (item.depth or 1) - 1)
        local current = index == self.current_toc
        local label = string.rep("    ", depth) .. (current and "• " or "") .. item.title
        return EgUI.listRow(w, label, item.page and tostring(item.page), function() self:goTo(item) end,
            { bold = current, size = depth > 0 and 15 or 16 })
    end
    local pageno = item.pageno or (type(item.page) == "number" and item.page) or ""
    local where = T(_("Page %1"), pageno) .. (item.chapter and ("  ·  " .. item.chapter) or "")
    if self.tab == "bookmarks" then
        return EgUI.listRow(w, where, nil, function() self:goTo(item) end)
    end
    local detail = where
    if item.note and item.note ~= "" then detail = _("Note: ") .. item.note .. "\n" .. where end
    return EgUI.listRow(w, "“" .. (item.text or ""):gsub("%s+", " ") .. "”", nil,
        function() self:goTo(item) end, { size = 15, detail = detail })
end

---------------------------------------------------------------------------

function Contents:goTo(item)
    if self.ui.link then self.ui.link:addCurrentLocationToStack() end
    local target = item.xpointer or item.page
    if self.ui.rolling and type(target) == "string" then
        self.ui:handleEvent(Event:new("GotoXPointer", target, target))
    elseif type(target) == "number" then
        self.ui:handleEvent(Event:new("GotoPage", target))
    elseif item.page then
        self.ui:handleEvent(Event:new("GotoPage", item.page))
    end
    self:close()
end

function Contents:setTab(tab)
    self.tab = tab
    self.page = self:startPage()
    self:refresh()
end

function Contents:turn(d)
    local p = self.page + d
    if p < 1 or p > self.pages then return end
    self.page = p
    self:refresh()
end

function Contents:onSwipe(_, ges)
    if ges.direction == "west" then self:turn(1)
    elseif ges.direction == "east" then self:turn(-1)
    else return false end
    return true
end

function Contents:refresh()
    self:build()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function Contents:close()
    UIManager:close(self, "ui", self.dimen)
end

function Contents:onCloseWidget()
    if self.plugin.panel == self then self.plugin.panel = nil end
    if self[1] then self[1]:free() end
end

function Contents:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

return Contents
