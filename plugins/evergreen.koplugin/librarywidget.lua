--[[--
Library: a paged grid of books with uniform cover cards.

Every cover is cropped to the same card size, titles get a fixed two-line box
in one face, and there are no paths or folders: the books under `dir` are
listed recursively. Filter chips (All / Reading / Unread / Finished), a sort
toggle (Recent / Title / Author), swipe or the pager to turn pages, tap to
open, hold for book information.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local DocSettings = require("docsettings")
local Covers = require("egcovers")
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

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_DARK_GRAY
local LIGHT = Blitbuffer.COLOR_LIGHT_GRAY

local BOOK_EXT = {
    epub = true, pdf = true, mobi = true, azw3 = true, azw = true, fb2 = true,
    cbz = true, djvu = true, docx = true, kepub = true,
}

local COLS, ROWS = 5, 3
local FILTERS = { "all", "reading", "unread", "finished" }
local FILTER_LABEL = { all = _("All"), reading = _("Reading"), unread = _("Unread"), finished = _("Finished") }
local SORTS = { "recent", "title", "author" }
local SORT_LABEL = { recent = _("Recent"), title = _("Title"), author = _("Author") }

---------------------------------------------------------------------------

local Tappable = InputContainer:extend{ callback = nil, hold_callback = nil }

function Tappable:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ w = size.w, h = size.h }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function Tappable:onTapSelect()
    if self.callback then UIManager:nextTick(self.callback) end
    return true
end

function Tappable:onHoldSelect()
    if self.hold_callback then
        UIManager:nextTick(self.hold_callback)
        return true
    end
end

local function text(str, face, width, color)
    return TextWidget:new{ text = str or "", face = face, max_width = width, fgcolor = color }
end

-- "Title (Last, First).epub" style filenames -> title, author
local function fromFilename(file)
    local name = file:match("([^/]+)$"):gsub("%.%w+$", ""):gsub("_", " ")
    local title, author = name:match("^(.-)%s*%(([^()]+)%)$")
    if title and title ~= "" then return title, author end
    return name, nil
end

local function cleanTitle(t)
    t = (t or ""):gsub("^%(%a%a%a?%)%s*", ""):gsub("^%[%a%a%a?%]%s*", "")
    return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "Last, First" / "Last,First" -> "First Last"; drop trailing separators
local function cleanAuthor(a)
    if not a then return nil end
    a = a:gsub("\n.*", ""):gsub("[;,%s]+$", ""):gsub("^%s+", "")
    local last, first = a:match("^([^,]+),%s*([^,]+)$")
    if last then a = first .. " " .. last end
    if a == "" then return nil end
    return a
end

local function bookInfoManager()
    local ok, BIM = pcall(require, "bookinfomanager")
    return ok and BIM or nil
end

---------------------------------------------------------------------------
-- Data

local function scanBooks(dir, out)
    if lfs.attributes(dir, "mode") ~= "directory" then return out end
    for f in lfs.dir(dir) do
        if f ~= "." and f ~= ".." and not f:match("^%.") then
            local path = dir .. "/" .. f
            local mode = lfs.attributes(path, "mode")
            if mode == "directory" then
                if not f:match("%.sdr$") then scanBooks(path, out) end
            elseif mode == "file" then
                local ext = f:match("%.(%w+)$")
                if ext and BOOK_EXT[ext:lower()] then table.insert(out, path) end
            end
        end
    end
    return out
end

local function loadBook(file, last_read, BIM)
    local info = BIM and BIM:getBookInfo(file, false)
    local book = { file = file, last_read = last_read or 0, indexed = info ~= nil, info = info }
    local fn_title, fn_author = fromFilename(file)
    book.title = (info and info.title) or fn_title
    book.authors = (info and info.authors) or fn_author
    if book.authors then book.authors = book.authors:gsub("\n.*", "") end
    if DocSettings:hasSidecarFile(file) then
        local ds = DocSettings:open(file)
        local props = ds:readSetting("doc_props")
        if not info and props then
            book.title = (props.title and props.title ~= "") and props.title or book.title
            book.authors = (props.authors and props.authors ~= "") and props.authors:gsub("\n.*", "") or book.authors
        end
        book.percent = ds:readSetting("percent_finished")
        book.status = (ds:readSetting("summary") or {}).status
    end
    if book.status == "complete" or (book.percent and book.percent >= 0.995) then
        book.state = "finished"
    elseif book.percent and book.percent > 0 then
        book.state = "reading"
    else
        book.state = "unread"
    end
    book.title = cleanTitle(book.title)
    book.authors = cleanAuthor(book.authors)
    book.sort_title = book.title:lower():gsub("^the ", ""):gsub("^a ", "")
    book.sort_author = (book.authors or "~"):lower()
    return book
end

---------------------------------------------------------------------------

local LibraryWidget = InputContainer:extend{
    plugin = nil,
    dir = nil,
    title = nil,
    covers_fullscreen = true,
}

function LibraryWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.margin = Screen:scaleBySize(22)
    self.inner_w = self.dimen.w - 2 * self.margin
    self.filter = self.plugin.settings_filter or "all"
    self.sort = G_reader_settings:readSetting("evergreen_library_sort") or "recent"
    self.page = 1
    self.dithered = true

    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    self:computeLayout()
    self:loadAll()
    self:build()
    self:indexMissing()
end

function LibraryWidget:computeLayout()
    local gap_x = Screen:scaleBySize(12)
    self.gap_x = gap_x
    self.gap_y = Screen:scaleBySize(16)
    self.card_w = math.floor((self.inner_w - (COLS - 1) * gap_x) / COLS)
    self.title_face = Font:getFace("tfont", 11)
    self.meta_face = Font:getFace("cfont", 10)
    self.title_h = text("Ag", self.title_face, self.card_w):getSize().h
    local meta_h = text("Ag", self.meta_face, self.card_w):getSize().h
    self.text_block_h = Screen:scaleBySize(6) + self.title_h + meta_h + Screen:scaleBySize(10)
    -- header (title + chips) and footer (pager) heights
    self.header_h = Screen:scaleBySize(116)
    self.footer_h = Screen:scaleBySize(40)
    local grid_h = self.dimen.h - self.header_h - self.footer_h
    local row_h = math.floor((grid_h - (ROWS - 1) * self.gap_y) / ROWS)
    self.cover_h = math.min(row_h - self.text_block_h, math.floor(self.card_w * 1.5))
end

function LibraryWidget:loadAll()
    local last_read = {}
    for _, e in ipairs(ReadHistory.hist) do
        last_read[e.file] = math.max(last_read[e.file] or 0, e.time or 0)
    end
    local BIM = bookInfoManager()
    self.books = {}
    for _, file in ipairs(scanBooks(self.dir, {})) do
        table.insert(self.books, loadBook(file, last_read[file], BIM))
    end
    self:applyView()
end

function LibraryWidget:applyView()
    local list = {}
    for _, b in ipairs(self.books) do
        if self.filter == "all" or b.state == self.filter then table.insert(list, b) end
    end
    local sort = self.sort
    table.sort(list, function(a, b)
        if sort == "title" then return a.sort_title < b.sort_title end
        if sort == "author" then
            if a.sort_author ~= b.sort_author then return a.sort_author < b.sort_author end
            return a.sort_title < b.sort_title
        end
        if a.last_read ~= b.last_read then return a.last_read > b.last_read end
        return a.sort_title < b.sort_title
    end)
    self.view = list
    self.pages = math.max(1, math.ceil(#list / (COLS * ROWS)))
    if self.page > self.pages then self.page = self.pages end
end

---------------------------------------------------------------------------
-- Building

function LibraryWidget:build()
    if self[1] then self[1]:free() end
    local body = VerticalGroup:new{ align = "left" }
    table.insert(body, self:header())
    table.insert(body, self:grid())
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        background = WHITE,
        bordersize = 0,
        padding = 0,
        padding_left = self.margin,
        padding_right = self.margin,
        OverlapGroup:new{
            dimen = Geom:new{ w = self.inner_w, h = self.dimen.h },
            body,
            self:footer(),
        },
    }
end

function LibraryWidget:header()
    local w = self.inner_w
    local top_h = Screen:scaleBySize(50)
    local back = Tappable:new{
        callback = function() self:goHome() end,
        CenterContainer:new{
            dimen = Geom:new{ w = Screen:scaleBySize(70), h = top_h },
            text("‹ " .. _("Home"), Font:getFace("cfont", 15), Screen:scaleBySize(70)),
        },
    }
    local title_row = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = top_h },
        LeftContainer:new{ dimen = Geom:new{ w = w, h = top_h }, back },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = top_h },
            text(self.title, Font:getFace("tfont", 22), w / 2),
        },
        RightContainer:new{
            dimen = Geom:new{ w = w, h = top_h },
            text(T(_("%1 books"), #self.view), Font:getFace("cfont", 14), w / 4, GRAY),
        },
    }

    local chips = HorizontalGroup:new{ align = "center" }
    for i, f in ipairs(FILTERS) do
        if i > 1 then table.insert(chips, HorizontalSpan:new{ width = Screen:scaleBySize(8) }) end
        table.insert(chips, self:chip(FILTER_LABEL[f], self.filter == f, function()
            self.filter = f
            self.plugin.settings_filter = f
            self.page = 1
            self:refresh()
        end))
    end
    local sort_btn = self:chip(T(_("Sort: %1"), SORT_LABEL[self.sort]), false, function()
        for i, s in ipairs(SORTS) do
            if s == self.sort then
                self.sort = SORTS[i % #SORTS + 1]
                break
            end
        end
        G_reader_settings:saveSetting("evergreen_library_sort", self.sort)
        self.page = 1
        self:refresh()
    end)
    local chip_h = Screen:scaleBySize(36)
    local chip_row = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = chip_h },
        LeftContainer:new{ dimen = Geom:new{ w = w, h = chip_h }, chips },
        RightContainer:new{ dimen = Geom:new{ w = w, h = chip_h }, sort_btn },
    }

    local h = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        title_row,
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        chip_row,
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        LineWidget:new{ dimen = Geom:new{ w = w, h = Size.line.thin }, background = LIGHT },
    }
    -- pad to the fixed header height so the grid never moves
    local used = h:getSize().h
    table.insert(h, VerticalSpan:new{ width = math.max(0, self.header_h - used) })
    h:resetLayout() -- getSize() cached offsets for the old child list
    return h
end

function LibraryWidget:chip(label, selected, callback)
    local face = Font:getFace("cfont", 14)
    local pad_h = Screen:scaleBySize(12)
    local label_w = text(label, face):getSize().w
    return Tappable:new{
        callback = callback,
        FrameContainer:new{
            bordersize = Size.border.thin,
            radius = Screen:scaleBySize(16),
            padding = 0,
            padding_left = pad_h,
            padding_right = pad_h,
            padding_top = Screen:scaleBySize(4),
            padding_bottom = Screen:scaleBySize(4),
            background = selected and BLACK or WHITE,
            color = selected and BLACK or GRAY,
            TextWidget:new{
                text = label,
                face = face,
                fgcolor = selected and WHITE or BLACK,
                max_width = label_w + 2,
            },
        },
    }
end

function LibraryWidget:grid()
    local per_page = COLS * ROWS
    local first = (self.page - 1) * per_page + 1
    local BIM = bookInfoManager()
    local grid = VerticalGroup:new{ align = "left" }
    if #self.view == 0 then
        table.insert(grid, VerticalSpan:new{ width = Screen:scaleBySize(80) })
        table.insert(grid, CenterContainer:new{
            dimen = Geom:new{ w = self.inner_w, h = Screen:scaleBySize(40) },
            text(_("No books here."), Font:getFace("cfont", 18), self.inner_w, GRAY),
        })
        return grid
    end
    for r = 0, ROWS - 1 do
        local row = HorizontalGroup:new{ align = "top" }
        for c = 0, COLS - 1 do
            local book = self.view[first + r * COLS + c]
            if c > 0 then table.insert(row, HorizontalSpan:new{ width = self.gap_x }) end
            if book then
                table.insert(row, self:card(book, BIM))
            end
        end
        if #row > 0 then
            if r > 0 then table.insert(grid, VerticalSpan:new{ width = self.gap_y }) end
            table.insert(grid, row)
        end
    end
    return grid
end

function LibraryWidget:coverBox(book, BIM)
    local info = BIM and book.indexed and BIM:getBookInfo(book.file, true)
    return Covers.card({ title = book.title, cover_bb = info and info.cover_bb }, self.card_w, self.cover_h)
end

function LibraryWidget:card(book, BIM)
    local w = self.card_w
    local meta
    if book.state == "reading" then
        meta = HorizontalGroup:new{
            align = "center",
            ProgressWidget:new{
                width = math.floor(w * 0.55),
                height = Screen:scaleBySize(5),
                percentage = book.percent,
                margin_h = 0, margin_v = 0,
                bordersize = 0,
                radius = 0,
                bgcolor = LIGHT,
                fillcolor = BLACK,
            },
            HorizontalSpan:new{ width = Screen:scaleBySize(6) },
            text(T(_("%1%"), math.floor(book.percent * 100)), self.meta_face, math.floor(w * 0.4), GRAY),
        }
    elseif book.state == "finished" then
        meta = text(_("Finished"), self.meta_face, w, GRAY)
    else
        meta = text(book.authors or "", self.meta_face, w, GRAY)
    end
    return Tappable:new{
        callback = function() self:openBook(book.file) end,
        hold_callback = function()
            if self.plugin.ui.bookinfo then self.plugin.ui.bookinfo:show(book.file) end
        end,
        VerticalGroup:new{
            align = "left",
            self:coverBox(book, BIM),
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
            text(book.title, self.title_face, w),
            meta,
        },
    }
end

function LibraryWidget:footer()
    local w = self.inner_w
    local h = self.footer_h
    local face = Font:getFace("cfont", 15)
    local arrow_w = Screen:scaleBySize(70)
    local pager = HorizontalGroup:new{
        align = "center",
        Tappable:new{
            callback = function() self:turn(-1) end,
            CenterContainer:new{ dimen = Geom:new{ w = arrow_w, h = h },
                text("‹", Font:getFace("tfont", 20), arrow_w, self.page > 1 and BLACK or LIGHT) },
        },
        CenterContainer:new{ dimen = Geom:new{ w = Screen:scaleBySize(90), h = h },
            text(T("%1 / %2", self.page, self.pages), face, Screen:scaleBySize(90)) },
        Tappable:new{
            callback = function() self:turn(1) end,
            CenterContainer:new{ dimen = Geom:new{ w = arrow_w, h = h },
                text("›", Font:getFace("tfont", 20), arrow_w, self.page < self.pages and BLACK or LIGHT) },
        },
    }
    return VerticalGroup:new{
        VerticalSpan:new{ width = self.dimen.h - h },
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, pager },
    }
end

---------------------------------------------------------------------------
-- Behaviour

function LibraryWidget:refresh(mode)
    self:applyView()
    self:build()
    UIManager:setDirty(self, function() return mode or "ui", self.dimen end)
end

function LibraryWidget:turn(delta)
    local p = self.page + delta
    if p < 1 or p > self.pages then return end
    self.page = p
    -- a full flash every few turns keeps e-ink ghosting away
    self.turns = (self.turns or 0) + 1
    self:refresh(self.turns % 6 == 0 and "full" or "ui")
end

function LibraryWidget:onSwipe(_, ges)
    local dir = ges.direction
    if dir == "west" then self:turn(1)
    elseif dir == "east" then self:turn(-1)
    else return false end
    return true
end

function LibraryWidget:indexMissing()
    local BIM = bookInfoManager()
    if not BIM then return end
    -- thumbnails are stored fitted inside the spec; 1.6x the card leaves
    -- enough pixels to crop-fill it without upscaling
    local specs = {
        max_cover_w = math.floor(self.card_w * 1.6),
        max_cover_h = math.floor(self.cover_h * 1.6),
    }
    local files = {}
    for _, b in ipairs(self.books) do
        local stale = b.info and b.info.has_cover and BIM.isCachedCoverInvalid(b.info, specs)
        if not b.indexed or stale then
            table.insert(files, { filepath = b.file, cover_specs = specs })
        end
    end
    if #files == 0 then return end
    UIManager:nextTick(function() BIM:extractInBackground(files) end)
    self.poll = function()
        if BIM:isExtractingInBackground() then
            UIManager:scheduleIn(3, self.poll)
            return
        end
        self.poll = nil
        -- pick up the new titles and covers
        self:loadAll()
        self:refresh("full")
    end
    UIManager:scheduleIn(3, self.poll)
end

function LibraryWidget:openBook(file)
    self.plugin:openBook(file)
end

function LibraryWidget:onShowingReader()
    UIManager:close(self)
end

-- The home sits underneath; closing the library reveals it.
function LibraryWidget:goHome()
    if not self.plugin.home then self.plugin:showHome() end
    UIManager:close(self)
end

function LibraryWidget:onClose()
    self:goHome()
    return true
end

function LibraryWidget:onCloseWidget()
    if self.poll then UIManager:unschedule(self.poll) end
    if self.plugin.library == self then self.plugin.library = nil end
    self:free()
end

function LibraryWidget:onShow()
    UIManager:setDirty(self, function() return "full", self.dimen end)
end

return LibraryWidget
