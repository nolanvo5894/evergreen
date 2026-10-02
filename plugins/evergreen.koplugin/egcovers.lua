--[[--
Book covers drawn as slightly rounded cards.

`Covers.card(book, w, h)` returns a w x h slot holding the cover scaled to fit
(never cropped), centred and sitting on the slot's bottom edge, with rounded
corners and a thin border. Books without a cover get a grey rounded card with
the title.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local Covers = {
    RADIUS = Screen:scaleBySize(6),
    BORDER = Size.border.thin,
    BORDER_COLOR = Blitbuffer.COLOR_DARK_GRAY,
    PLACEHOLDER_BG = Blitbuffer.COLOR_LIGHT_GRAY,
}

-- An image with its corners masked to a radius and a rounded border on top.
-- ImageWidget can't clip, so the corners outside the arc are painted over
-- with the page background.
local RoundedImage = WidgetContainer:extend{
    radius = 0,
    border = 0,
    border_color = Blitbuffer.COLOR_BLACK,
    bg = Blitbuffer.COLOR_WHITE,
}

function RoundedImage:getSize()
    return self[1]:getSize()
end

function RoundedImage:paintTo(bb, x, y)
    local size = self[1]:getSize()
    local w, h = size.w, size.h
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    self[1]:paintTo(bb, x, y)
    local r = math.min(self.radius, math.floor(math.min(w, h) / 2))
    for j = 0, r - 1 do
        local dy = r - j - 0.5
        local inset = math.floor(r - math.sqrt(r * r - dy * dy) + 0.5)
        if inset > 0 then
            bb:paintRect(x, y + j, inset, 1, self.bg)
            bb:paintRect(x + w - inset, y + j, inset, 1, self.bg)
            bb:paintRect(x, y + h - 1 - j, inset, 1, self.bg)
            bb:paintRect(x + w - inset, y + h - 1 - j, inset, 1, self.bg)
        end
    end
    if self.border > 0 then
        bb:paintBorder(x, y, w, h, self.border, self.border_color, r)
    end
end

--- Cover slot of exactly w x h.
-- @param book table with `title` and optionally `cover_bb` (a Blitbuffer
--   this widget takes ownership of)
function Covers.card(book, w, h)
    local inner
    if book.cover_bb then
        local bb = book.cover_bb
        local iw, ih = bb:getWidth(), bb:getHeight()
        local scale = math.min(w / iw, h / ih)
        local dw = math.max(1, math.floor(iw * scale))
        local dh = math.max(1, math.floor(ih * scale))
        inner = RoundedImage:new{
            radius = Covers.RADIUS,
            border = Covers.BORDER,
            border_color = Covers.BORDER_COLOR,
            ImageWidget:new{
                image = bb,
                image_disposable = true,
                width = dw,
                height = dh,
                scale_factor = scale,
            },
        }
    else
        local pad = Screen:scaleBySize(8)
        local tw = w - 2 * pad - 2 * Covers.BORDER
        inner = FrameContainer:new{
            width = w,
            height = h,
            radius = Covers.RADIUS,
            bordersize = Covers.BORDER,
            color = Covers.BORDER_COLOR,
            background = Covers.PLACEHOLDER_BG,
            padding = pad,
            CenterContainer:new{
                dimen = Geom:new{ w = tw, h = h - 2 * pad - 2 * Covers.BORDER },
                TextBoxWidget:new{
                    text = book.title or "",
                    face = Font:getFace("tfont", w > Screen:scaleBySize(110) and 13 or 10),
                    width = tw,
                    alignment = "center",
                    bgcolor = Covers.PLACEHOLDER_BG,
                },
            },
        }
    end
    -- bottom-aligned, horizontally centred in the slot
    local size = inner:getSize()
    return VerticalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = w },
        VerticalSpan:new{ width = h - size.h },
        inner,
    }
end

return Covers
