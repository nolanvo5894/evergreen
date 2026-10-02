--[[--
Reading-position dots, as in Bookie's reader (ChapterProgress.tsx):
  - a strip along the top edge, one dot per chapter of the book
  - a rail down the right edge, one dot per page of the current chapter
Read = gray, here = black (a little larger), not yet read = light gray. When
there are more items than fit, several share a dot (same bucketing as Bookie).

Registered as a ReaderView view module, so it's painted with every page.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local DOT = 6        -- px
local HERE = 10      -- px, current position
local GAP = 7        -- min px between dots
local EDGE = 24      -- px from the screen edge when the margins are unknown

local READ = Blitbuffer.COLOR_DARK_GRAY
local AHEAD = Blitbuffer.COLOR_LIGHT_GRAY
local CURRENT = Blitbuffer.COLOR_BLACK

local Dots = WidgetContainer:extend{
    plugin = nil,
}

-- Map `total` items onto at most `max_dots` dots; returns the dot count and
-- the dot (0-based) holding `current` (0-based).
local function bucket(current, total, max_dots)
    local dots = math.max(1, math.min(total, max_dots))
    if total <= 1 or dots <= 1 then return dots, 0 end
    local index = math.floor(current / (total - 1) * (dots - 1) + 0.5)
    return dots, math.max(0, math.min(dots - 1, index))
end
Dots.bucket = bucket

local function dot(bb, cx, cy, size, color)
    local x0, y0 = cx - math.floor(size / 2), cy - math.floor(size / 2)
    if size >= 5 then
        -- clip the corners so it reads as round
        bb:paintRect(x0 + 1, y0, size - 2, size, color)
        bb:paintRect(x0, y0 + 1, size, size - 2, color)
    else
        bb:paintRect(x0, y0, size, size, color)
    end
end

function Dots:currentPage()
    local ui = self.plugin.ui
    if ui.paging then return ui.paging.current_page end
    return ui.document:getCurrentPage()
end

--- Top-level chapters (shallowest TOC depth), each { page = n }.
function Dots:chapters()
    local toc = self.plugin.ui.toc
    if not toc then return {} end
    toc:fillToc()
    local entries = toc.toc or {}
    local min_depth
    for _, e in ipairs(entries) do
        if e.page and (not min_depth or (e.depth or 1) < min_depth) then min_depth = e.depth or 1 end
    end
    local out = {}
    for _, e in ipairs(entries) do
        if e.page and (e.depth or 1) == min_depth then table.insert(out, e) end
    end
    return out
end

--- The page's margins in screen px (left, top, right, bottom). The dots sit
-- in the middle of the margins, between the screen edge and the text.
function Dots:margins()
    local doc = self.plugin.ui.document
    if doc and doc.getPageMargins and self.plugin.ui.rolling then
        local m = doc:getPageMargins()
        if m and m.left then return m.left, m.top, m.right, m.bottom end
    end
    return EDGE * 2, EDGE * 2, EDGE * 2, EDGE * 2
end

function Dots:stripGeometry()
    local w = Screen:getWidth()
    local ml, mt, mr = self:margins()
    -- spans the text column; vertically centred in the top margin
    return ml, w - mr, math.max(HERE, math.floor(mt / 2))
end

--- Chapter strip layout for the current page: dots, index, chapter list.
function Dots:stripState()
    local chapters = self:chapters()
    if #chapters <= 1 then return nil end
    local page = self:currentPage()
    local current = 0
    for i, c in ipairs(chapters) do
        if c.page <= page then current = i - 1 end
    end
    local left, right = self:stripGeometry()
    local max_dots = math.max(1, math.floor((right - left + GAP) / (DOT + GAP)))
    local dots, index = bucket(current, #chapters, max_dots)
    return { dots = dots, index = index, chapters = chapters, left = left, right = right }
end

function Dots:paintTo(bb, x, y)
    local ui = self.plugin.ui
    if not ui.document then return end
    local w, h = Screen:getWidth(), Screen:getHeight()

    -- top strip: chapters
    local st = self:stripState()
    local _, strip_y = nil, nil
    if st then
        _, _, strip_y = self:stripGeometry()
        local span = st.right - st.left
        for i = 0, st.dots - 1 do
            local cx = st.dots > 1 and math.floor(st.left + span * i / (st.dots - 1) + 0.5) or st.left
            local color = i < st.index and READ or (i == st.index and CURRENT or AHEAD)
            dot(bb, x + cx, y + strip_y, i == st.index and HERE or DOT, color)
        end
    end

    -- right rail: pages of this chapter (whole book when there's no TOC)
    local page = self:currentPage()
    local total, done
    if ui.toc and st then
        total = ui.toc:getChapterPageCount(page)
        done = ui.toc:getChapterPagesDone(page)
    end
    if not total or total < 1 then
        total, done = ui.document:getPageCount(), page - 1
    end
    if total and total > 1 then
        -- spans the text height; horizontally centred in the right margin
        local _, mt, mr, mb = self:margins()
        local top, bottom = mt, h - mb
        local max_dots = math.max(1, math.floor((bottom - top + GAP) / (DOT + GAP)))
        local dots, index = bucket(done or 0, total, max_dots)
        local span = bottom - top
        local cx = w - math.max(HERE, math.floor(mr / 2))
        for i = 0, dots - 1 do
            local cy = dots > 1 and math.floor(top + span * i / (dots - 1) + 0.5) or top
            local color = i < index and READ or (i == index and CURRENT or AHEAD)
            dot(bb, x + cx, y + cy, i == index and HERE or DOT, color)
        end
    end
end

--- Chapter for a tap at screen x on the strip, or nil.
function Dots:chapterAt(px)
    local st = self:stripState()
    if not st then return nil end
    local ratio = (px - st.left) / math.max(1, st.right - st.left)
    local i = math.floor(math.max(0, math.min(1, ratio)) * (st.dots - 1) + 0.5)
    local ci = st.dots == #st.chapters and i or math.floor(i / math.max(1, st.dots - 1) * (#st.chapters - 1) + 0.5)
    return st.chapters[ci + 1]
end

return Dots
