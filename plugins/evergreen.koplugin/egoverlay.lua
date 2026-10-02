--[[--
Reader overlay: a slim top bar (home, title, chapter, bookmark) and a bottom
bar (position, time left in chapter, seek bar, five actions). Shown by a tap
in the middle of the page or on its top/bottom strips; tapping anywhere else
closes it. The page stays visible between the bars.
--]]

local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local EgUI = require("egui")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen
local S = EgUI.S

local Overlay = InputContainer:extend{
    plugin = nil, -- evergreen plugin instance (reader context)
}

function Overlay:init()
    self.ui = self.plugin.ui
    self.screen_w, self.screen_h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    self:build()
end

function Overlay:currentPage()
    if self.ui.paging then return self.ui.paging.current_page end
    return self.ui.document:getCurrentPage()
end

function Overlay:build()
    local w = self.screen_w
    local pad = S(14)
    local inner = w - 2 * pad
    local page = self:currentPage()
    local total = self.ui.document:getPageCount()
    local props = self.ui.doc_props or {}
    local title = props.display_title or props.title or self.ui.document.file:match("([^/]+)$")
    local chapter = self.ui.toc and self.ui.toc:getTocTitleByPage(page) or ""

    -- top bar ---------------------------------------------------------------
    local bar_h = S(52)
    local marked = self.ui.bookmark and self.ui.bookmark:isPageBookmarked()
    local home = EgUI.tap(CenterContainer:new{
        dimen = Geom:new{ w = S(80), h = bar_h },
        EgUI.text("‹ " .. _("Home"), 15, S(80)),
    }, function() self:goHome() end)
    local bookmark_icon = IconWidget:new{ icon = "bookmark", width = S(26), height = S(26) }
    local bookmark = EgUI.tap(FrameContainer:new{
        bordersize = marked and Size.border.thin or 0,
        radius = S(8),
        padding = S(6),
        background = marked and EgUI.LIGHT or EgUI.WHITE,
        bookmark_icon,
    }, function() self:toggleBookmark() end)
    local center_w = inner - 2 * S(80)
    local center = CenterContainer:new{
        dimen = Geom:new{ w = inner, h = bar_h },
        VerticalGroup:new{
            align = "center",
            EgUI.text(title, 15, center_w, { bold = true }),
            chapter ~= "" and EgUI.text(chapter, 12, center_w, { color = EgUI.GRAY }) or EgUI.vspan(0),
        },
    }
    self.top = FrameContainer:new{
        width = w,
        bordersize = 0,
        padding = 0,
        padding_left = pad,
        padding_right = pad,
        background = EgUI.WHITE,
        VerticalGroup:new{
            align = "left",
            require("ui/widget/overlapgroup"):new{
                dimen = Geom:new{ w = inner, h = bar_h },
                home,
                center,
                require("ui/widget/container/rightcontainer"):new{
                    dimen = Geom:new{ w = inner, h = bar_h },
                    bookmark,
                },
            },
        },
    }
    self.top_line = EgUI.line(w, EgUI.GRAY)

    -- bottom bar ------------------------------------------------------------
    local left_in_chapter = self.ui.toc and self.ui.toc:getChapterPagesLeft(page) or nil
    local remaining
    if left_in_chapter then
        local avg = self.ui.statistics and self.ui.statistics.avg_time
        if avg and avg > 0 then
            local mins = math.max(1, math.floor(left_in_chapter * avg / 60 + 0.5))
            remaining = T(_("%1 min left in chapter"), mins)
        else
            remaining = T(_("%1 pages left in chapter"), left_in_chapter)
        end
    end
    local info = EgUI.spread(inner, S(26),
        EgUI.text(T(_("Page %1 of %2"), page, total), 13, inner / 2, { color = EgUI.GRAY }),
        remaining and EgUI.text(remaining, 13, inner / 2, { color = EgUI.GRAY }) or nil)

    local seek = ProgressWidget:new{
        width = inner,
        height = S(10),
        percentage = total > 0 and page / total or 0,
        margin_h = 0,
        margin_v = 0,
        radius = S(5),
        bordersize = Size.border.thin,
        bgcolor = EgUI.WHITE,
        fillcolor = EgUI.BLACK,
    }
    -- generous tap target around the thin bar
    local seek_tap = EgUI.tap(CenterContainer:new{
        dimen = Geom:new{ w = inner, h = S(34) },
        seek,
    }, function(ges, dimen)
        local ratio = (ges.pos.x - dimen.x) / dimen.w
        ratio = math.max(0, math.min(1, ratio))
        self:gotoPage(math.max(1, math.floor(ratio * total + 0.5)))
    end)

    local actions = {
        { "appbar.navigation", _("Contents"), function() self:open("contents") end },
        { "appbar.search", _("Search"), function() self:open("search") end },
        { "appbar.textsize", _("Text"), function() self:open("text") end },
        { "edit", _("Notes"), function() self:open("notes") end },
        { "appbar.menu", _("More"), function() self:open("more") end },
    }
    local slot_w = math.floor(inner / #actions)
    local buttons = HorizontalGroup:new{ align = "top" }
    for _, a in ipairs(actions) do
        table.insert(buttons, EgUI.tap(CenterContainer:new{
            dimen = Geom:new{ w = slot_w, h = S(64) },
            VerticalGroup:new{
                align = "center",
                IconWidget:new{ icon = a[1], width = S(30), height = S(30) },
                EgUI.vspan(3),
                EgUI.text(a[2], 13, slot_w),
            },
        }, a[3]))
    end
    self.bottom = FrameContainer:new{
        width = w,
        bordersize = 0,
        padding = 0,
        padding_left = pad,
        padding_right = pad,
        padding_top = S(6),
        padding_bottom = S(6),
        background = EgUI.WHITE,
        VerticalGroup:new{
            align = "left",
            info,
            seek_tap,
            buttons,
        },
    }
    self.bottom_line = EgUI.line(w, EgUI.GRAY)
    self.top_h = self.top:getSize().h
    self.bottom_h = self.bottom:getSize().h
end

function Overlay:paintTo(bb, x, y)
    self.top:paintTo(bb, x, y)
    self.top_line:paintTo(bb, x, y + self.top_h)
    local by = y + self.screen_h - self.bottom_h
    self.bottom_line:paintTo(bb, x, by - Size.line.thin)
    self.bottom:paintTo(bb, x, by)
end

-- Taps go to the bars' own buttons first (they're children); anything that
-- reaches here landed on the page area between them.
function Overlay:onTapOutside(_, ges)
    local y = ges.pos.y
    if y > self.top_h and y < self.screen_h - self.bottom_h then
        self:close()
    end
    return true
end

function Overlay:handleEvent(event)
    -- route gestures to the bars (they aren't in self[1])
    if self.top:handleEvent(event) then return true end
    if self.bottom:handleEvent(event) then return true end
    return InputContainer.handleEvent(self, event)
end

function Overlay:barsRegion()
    return Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
end

function Overlay:refresh()
    self:build()
    UIManager:setDirty("all", function()
        return "ui", Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.top_h + Size.line.thin }
    end)
    UIManager:setDirty("all", function()
        local h = self.bottom_h + Size.line.thin
        return "ui", Geom:new{ x = 0, y = self.screen_h - h, w = self.screen_w, h = h }
    end)
end

---------------------------------------------------------------------------

function Overlay:close()
    UIManager:close(self, "ui", self:barsRegion())
end

function Overlay:onCloseWidget()
    if self.plugin.overlay == self then self.plugin.overlay = nil end
end

function Overlay:goHome()
    UIManager:close(self)
    -- onHome closes the book and shows the file manager, which puts up
    -- Evergreen's home (onClose alone would leave nothing on screen)
    self.ui:onHome()
end

function Overlay:toggleBookmark()
    self.ui.bookmark:onToggleBookmark()
    self:refresh()
end

function Overlay:gotoPage(page)
    if self.ui.link then self.ui.link:addCurrentLocationToStack() end
    self.ui:handleEvent(Event:new("GotoPage", page))
    self:refresh()
end

function Overlay:open(what)
    UIManager:close(self)
    UIManager:nextTick(function() self.plugin:openReaderPanel(what) end)
end

return Overlay
