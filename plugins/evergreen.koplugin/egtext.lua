--[[--
Text panel: font, size, line spacing, margins, alignment and darkness as plain
choices. Each change goes through ConfigChange + the option's event, exactly
like KOReader's bottom config panel, so it is saved with the book.
--]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local EgUI = require("egui")
local _ = require("gettext")
local Screen = Device.screen
local S = EgUI.S

local function D(key) return G_defaults:readSetting(key) end

local SPACING = {
    { _("Tight"), "DCREREADER_CONFIG_LINE_SPACE_PERCENT_SMALL" },
    { _("Normal"), "DCREREADER_CONFIG_LINE_SPACE_PERCENT_MEDIUM" },
    { _("Loose"), "DCREREADER_CONFIG_LINE_SPACE_PERCENT_LARGE" },
}
local DARKNESS = { { _("Light"), -0.5 }, { _("Normal"), 0 }, { _("Bold"), 1 } }
local PREFERRED_FONTS = {
    "Bookerly", "Literata", "Noto Serif", "Noto Sans", "Amazon Ember", "Caecilia", "Georgia", "Palatino",
}
local ALIGN_LEFT, ALIGN_JUSTIFY = "text_align_most_left", "text_align_most_justify"

local TextPanel = InputContainer:extend{
    plugin = nil,
}

function TextPanel:init()
    self.ui = self.plugin.ui
    self.screen_w, self.screen_h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    self.font_page = nil -- non-nil: showing the font list at that page
    self:build()
end

function TextPanel:conf(name)
    return self.ui.document.configurable[name]
end

function TextPanel:apply(name, value, event, arg)
    self.ui:handleEvent(Event:new("ConfigChange", name, value))
    self.ui:handleEvent(Event:new(event, arg == nil and value or arg))
    self:refresh()
end

local function same(a, b)
    if type(a) == "table" and type(b) == "table" then
        return a[1] == b[1] and a[2] == b[2]
    end
    return a == b
end

function TextPanel:fonts()
    local ok, faces = pcall(function() return require("document/credocument"):getFontFaces() end)
    return ok and faces or {}
end

function TextPanel:build()
    local w = self.screen_w
    local inner = w - 2 * S(16)
    local body = VerticalGroup:new{ align = "left" }
    local label = function(str)
        table.insert(body, EgUI.vspan(10))
        table.insert(body, EgUI.text(str, 13, inner, { color = EgUI.GRAY }))
        table.insert(body, EgUI.vspan(6))
    end

    if self.font_page then
        self:buildFontList(body, inner)
    else
        table.insert(body, EgUI.header(inner, _("Text"), function() self:close() end))

        -- font
        label(_("Font"))
        local current = self.ui.font and self.ui.font.font_face
        local available = {}
        for _, f in ipairs(self:fonts()) do available[f] = true end
        local chips, shown = {}, {}
        for _, f in ipairs(PREFERRED_FONTS) do
            if available[f] and #chips < 3 then
                table.insert(chips, EgUI.chip(f, f == current, function() self:setFont(f) end))
                shown[f] = true
            end
        end
        if current and not shown[current] then
            table.insert(chips, 1, EgUI.chip(current, true, function() end))
            shown[current] = true
            if #chips > 3 then table.remove(chips) end
        end
        -- fill up to three one-tap choices from the installed fonts
        for _, f in ipairs(self:fonts()) do
            if #chips >= 3 then break end
            if not shown[f] then
                table.insert(chips, EgUI.chip(f, false, function() self:setFont(f) end))
                shown[f] = true
            end
        end
        table.insert(chips, EgUI.chip(_("More fonts"), false, function()
            self.font_page = 1
            self:refresh()
        end))
        table.insert(body, EgUI.row(chips))

        -- size
        label(_("Size"))
        local size = self:conf("font_size") or 22
        table.insert(body, EgUI.row({
            EgUI.chip("A−", false, function() self:setSize(size - 1) end, { min_w = S(70) }),
            EgUI.text(tostring(math.floor(size * 10 + 0.5) / 10), 18, S(70), { bold = true }),
            EgUI.chip("A+", false, function() self:setSize(size + 1) end, { min_w = S(70) }),
        }, S(16)))

        -- spacing / margins / alignment / darkness
        local function choices(title, list, current_value, on_pick)
            label(title)
            local row = {}
            for _, c in ipairs(list) do
                table.insert(row, EgUI.chip(c[1], same(c[2], current_value), function() on_pick(c[2]) end))
            end
            table.insert(body, EgUI.row(row))
        end

        local spacing = {}
        for _, s in ipairs(SPACING) do table.insert(spacing, { s[1], D(s[2]) }) end
        choices(_("Line spacing"), spacing, self:conf("line_spacing"), function(v)
            self:apply("line_spacing", v, "SetLineSpace")
        end)

        local st = self.ui.styletweak
        local align = "book"
        if st and st:isTweakEnabled(ALIGN_JUSTIFY) then align = "justify"
        elseif st and st:isTweakEnabled(ALIGN_LEFT) then align = "left" end
        choices(_("Alignment"), {
            { _("Book"), "book" }, { _("Left"), "left" }, { _("Justify"), "justify" },
        }, align, function(v) self:setAlignment(v) end)

        choices(_("Darkness"), DARKNESS, self:conf("font_base_weight") or 0, function(v)
            self:apply("font_base_weight", v, "SetFontBaseWeight")
        end)
        table.insert(body, EgUI.vspan(6))
    end

    self.panel = EgUI.sheet(w, nil, body)
    self.panel_h = self.panel:getSize().h
end

function TextPanel:buildFontList(body, inner)
    table.insert(body, EgUI.header(inner, _("Fonts"), function()
        self.font_page = nil
        self:refresh()
    end))
    local faces = self:fonts()
    local per = 10
    local pages = math.max(1, math.ceil(#faces / per))
    self.font_page = math.min(self.font_page, pages)
    local current = self.ui.font and self.ui.font.font_face
    for i = (self.font_page - 1) * per + 1, math.min(#faces, self.font_page * per) do
        local f = faces[i]
        table.insert(body, EgUI.listRow(inner, f, f == current and "✓" or nil, function()
            self.font_page = nil
            self:setFont(f)
        end))
    end
    table.insert(body, EgUI.pager(inner, self.font_page, pages, function(d)
        local p = self.font_page + d
        if p >= 1 and p <= pages then
            self.font_page = p
            self:refresh()
        end
    end))
end

---------------------------------------------------------------------------

function TextPanel:setFont(face)
    self.ui:handleEvent(Event:new("SetFont", face))
    self:refresh()
end

function TextPanel:setSize(size)
    size = math.max(8, math.min(72, size))
    self:apply("font_size", size, "SetFontSize")
end

function TextPanel:setAlignment(v)
    local st = self.ui.styletweak
    if not st then return end
    if v == "left" then
        st:onToggleStyleTweak({ ALIGN_LEFT, true }, nil, true)
    elseif v == "justify" then
        st:onToggleStyleTweak({ ALIGN_JUSTIFY, true }, nil, true)
    else
        st:onToggleStyleTweak({ ALIGN_LEFT, false }, nil, true)
        st:onToggleStyleTweak({ ALIGN_JUSTIFY, false }, nil, true)
    end
    self:refresh()
end

---------------------------------------------------------------------------

function TextPanel:paintTo(bb, x, y)
    self.panel:paintTo(bb, x, y + self.screen_h - self.panel_h)
end

function TextPanel:handleEvent(event)
    if self.panel:handleEvent(event) then return true end
    return InputContainer.handleEvent(self, event)
end

function TextPanel:onTapOutside(_, ges)
    if ges.pos.y < self.screen_h - self.panel_h then self:close() end
    return true
end

function TextPanel:region()
    return Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
end

function TextPanel:refresh()
    local old_h = self.panel_h
    self.panel:free()
    self:build()
    local h = math.max(old_h, self.panel_h)
    UIManager:setDirty("all", function()
        return "ui", Geom:new{ x = 0, y = self.screen_h - h, w = self.screen_w, h = h }
    end)
end

function TextPanel:close()
    UIManager:close(self, "ui", self:region())
end

function TextPanel:onCloseWidget()
    if self.plugin.panel == self then self.plugin.panel = nil end
    self.panel:free()
end

return TextPanel
