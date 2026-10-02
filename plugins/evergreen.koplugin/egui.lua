--[[--
Small UI kit shared by Evergreen's reader screens: tappable wrappers, chips,
panel frames, list rows and a pager. Grayscale, one type family, sizes in
scaleBySize units so they track the screen DPI.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local S = function(n) return Screen:scaleBySize(n) end

local EgUI = {
    BLACK = Blitbuffer.COLOR_BLACK,
    WHITE = Blitbuffer.COLOR_WHITE,
    GRAY = Blitbuffer.COLOR_DARK_GRAY,
    LIGHT = Blitbuffer.COLOR_LIGHT_GRAY,
    S = S,
}

function EgUI.face(size, bold)
    return Font:getFace(bold and "tfont" or "cfont", size)
end

function EgUI.text(str, size, width, opts)
    opts = opts or {}
    return TextWidget:new{
        text = str or "",
        face = EgUI.face(size, opts.bold),
        max_width = width,
        fgcolor = opts.color,
    }
end

function EgUI.textbox(str, size, width, opts)
    opts = opts or {}
    return TextBoxWidget:new{
        text = str or "",
        face = EgUI.face(size, opts.bold),
        width = width,
        height = opts.height,
        height_overflow_show_ellipsis = opts.height ~= nil,
        fgcolor = opts.color,
        alignment = opts.align,
    }
end

-- Wraps one child; calls `callback(ges)` on tap and `hold_callback(ges)` on hold.
local Tappable = InputContainer:extend{ callback = nil, hold_callback = nil }
EgUI.Tappable = Tappable

function Tappable:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ w = size.w, h = size.h }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function Tappable:onTapSelect(_, ges)
    if self.callback then
        local cb = self.callback
        UIManager:nextTick(function() cb(ges, self.dimen) end)
    end
    return true
end

function Tappable:onHoldSelect(_, ges)
    if self.hold_callback then
        local cb = self.hold_callback
        UIManager:nextTick(function() cb(ges, self.dimen) end)
        return true
    end
end

function EgUI.tap(widget, callback, hold_callback)
    return Tappable:new{ callback = callback, hold_callback = hold_callback, widget }
end

--- Pill-shaped choice. Selected = black fill, white text.
function EgUI.chip(label, selected, callback, opts)
    opts = opts or {}
    local size = opts.size or 15
    local pad_h = S(opts.pad or 12)
    local t = TextWidget:new{
        text = label,
        face = EgUI.face(size, opts.bold),
        fgcolor = selected and EgUI.WHITE or EgUI.BLACK,
    }
    local frame = FrameContainer:new{
        bordersize = Size.border.thin,
        radius = S(18),
        padding = 0,
        padding_left = pad_h,
        padding_right = pad_h,
        padding_top = S(5),
        padding_bottom = S(5),
        background = selected and EgUI.BLACK or EgUI.WHITE,
        color = selected and EgUI.BLACK or EgUI.GRAY,
        opts.min_w and CenterContainer:new{
            dimen = Geom:new{ w = math.max(opts.min_w - 2 * pad_h, t:getSize().w), h = t:getSize().h },
            t,
        } or t,
    }
    return EgUI.tap(frame, callback)
end

function EgUI.row(items, gap)
    local g = HorizontalGroup:new{ align = "center" }
    for i, w in ipairs(items) do
        if i > 1 then table.insert(g, HorizontalSpan:new{ width = gap or S(8) }) end
        table.insert(g, w)
    end
    return g
end

function EgUI.vspan(n) return VerticalSpan:new{ width = S(n) } end
function EgUI.hspan(n) return HorizontalSpan:new{ width = S(n) } end

function EgUI.line(w, color)
    return LineWidget:new{ dimen = Geom:new{ w = w, h = Size.line.thin }, background = color or EgUI.LIGHT }
end

--- Left and right content on one line of width w.
function EgUI.spread(w, h, left, right)
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, left },
        right and RightContainer:new{ dimen = Geom:new{ w = w, h = h }, right } or nil,
    }
end

--- Panel header: title on the left, close "✕" on the right.
function EgUI.header(w, title, on_close)
    local h = S(40)
    return EgUI.spread(w, h,
        EgUI.text(title, 19, w - S(60), { bold = true }),
        EgUI.tap(CenterContainer:new{
            dimen = Geom:new{ w = S(44), h = h },
            EgUI.text("✕", 19, S(44)),
        }, on_close))
end

--- A list row: label (and optional detail) left, value right, divider below.
function EgUI.listRow(w, label, value, callback, opts)
    opts = opts or {}
    local pad = S(opts.pad or 10)
    local value_w = 0
    if value then
        local probe = TextWidget:new{ text = value, face = EgUI.face(14) }
        value_w = math.min(math.floor(w * 0.35), probe:getSize().w + S(4))
        probe:free()
    end
    local left = VerticalGroup:new{ align = "left" }
    table.insert(left, EgUI.text(label, opts.size or 16, w - value_w - S(12), { bold = opts.bold, color = opts.color }))
    if opts.detail then
        table.insert(left, EgUI.vspan(2))
        table.insert(left, EgUI.textbox(opts.detail, 13, w - value_w - S(12),
            { color = EgUI.GRAY, height = opts.detail_lines and nil }))
    end
    local h = left:getSize().h + 2 * pad
    local content = VerticalGroup:new{
        align = "left",
        EgUI.spread(w, h, left, value and EgUI.text(value, 14, value_w, { color = EgUI.GRAY }) or nil),
        EgUI.line(w),
    }
    return callback and EgUI.tap(content, callback, opts.hold) or content
end

--- "‹  2 / 5  ›" pager.
function EgUI.pager(w, page, pages, on_turn)
    local h = S(40)
    local arrow_w = S(70)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{
            align = "center",
            EgUI.tap(CenterContainer:new{ dimen = Geom:new{ w = arrow_w, h = h },
                EgUI.text("‹", 22, arrow_w, { bold = true, color = page > 1 and EgUI.BLACK or EgUI.LIGHT }) },
                function() on_turn(-1) end),
            CenterContainer:new{ dimen = Geom:new{ w = S(90), h = h },
                EgUI.text(page .. " / " .. pages, 15, S(90)) },
            EgUI.tap(CenterContainer:new{ dimen = Geom:new{ w = arrow_w, h = h },
                EgUI.text("›", 22, arrow_w, { bold = true, color = page < pages and EgUI.BLACK or EgUI.LIGHT }) },
                function() on_turn(1) end),
        },
    }
end

--- White sheet with a top border (and rounded top corners when it doesn't
-- fill the screen).
function EgUI.sheet(w, h, content, full)
    return FrameContainer:new{
        width = w,
        height = h,
        bordersize = full and 0 or Size.border.thin,
        radius = full and 0 or S(14),
        background = EgUI.WHITE,
        padding = S(16),
        padding_bottom = S(10),
        content,
    }
end

return EgUI
