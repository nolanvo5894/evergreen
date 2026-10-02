--[[--
More: every other reader setting, grouped in plain sections. Entries open the
matching section of KOReader's settings (by menu id) on its own, so all the
existing settings logic is reused; items missing on a build are skipped.
--]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local EgUI = require("egui")
local _ = require("gettext")
local Screen = Device.screen
local S = EgUI.S

local More = InputContainer:extend{
    plugin = nil,
    covers_fullscreen = true,
}

-- { label, kind, target }: kind "menu" = menu id(s), "event" = ui event
local SECTIONS = {
    { _("This book"), {
        { _("Book information"), "event", "ShowBookInfo" },
        { _("Reading status and rating"), "event", "ShowBookStatus" },
        { _("Reading statistics"), "menu", { "statistics" } },
    } },
    { _("Reading"), {
        { _("Page turns and taps"), "menu", { "taps_and_gestures" } },
        { _("Screen and refresh"), "menu", { "screen", "night_mode" } },
        { _("Status bar"), "menu", { "status_bar" } },
        { _("Advanced text"), "menu", { "change_font", "typography", "style_tweaks", "set_render_style", "document_settings" } },
    } },
    { _("Tools"), {
        { _("Dictionary"), "menu", { "dictionary_settings" } },
        { _("Bookie sync"), "menu", { "bookie_sync" } },
        { _("Export highlights"), "menu", { "exporter" } },
    } },
    { _("Device"), {
        { _("Wi-Fi and network"), "menu", { "network" } },
        { _("Device"), "menu", { "device" } },
        { _("All settings"), "classic" },
    } },
}

function More:init()
    self.ui = self.plugin.ui
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self:build()
end

--- Menu items (already sorted by KOReader) indexed by their menu id.
function More:menuIndex()
    local menu = self.ui.menu
    if not menu.tab_item_table then menu:setUpdateItemTable() end
    local index = {}
    local function walk(list)
        for _, item in ipairs(list) do
            if type(item) == "table" then
                if item.id then index[item.id] = item end
                if type(item.sub_item_table) == "table" then walk(item.sub_item_table) end
            end
        end
    end
    for _, tab in ipairs(menu.tab_item_table) do walk(tab) end
    return index
end

function More:build()
    local w = self.dimen.w
    local inner = w - 2 * S(16)
    local index = self:menuIndex()
    local body = VerticalGroup:new{ align = "left" }
    table.insert(body, EgUI.header(inner, _("More"), function() self:close() end))
    for _, section in ipairs(SECTIONS) do
        local rows = {}
        for _, entry in ipairs(section[2]) do
            local label, kind, target = entry[1], entry[2], entry[3]
            local available = kind ~= "menu"
            if kind == "menu" then
                for _, id in ipairs(target) do
                    if index[id] then available = true end
                end
            end
            if available then
                table.insert(rows, EgUI.listRow(inner, label, "›", function() self:openEntry(kind, target, label) end, { pad = 7 }))
            end
        end
        if #rows > 0 then
            table.insert(body, EgUI.vspan(10))
            table.insert(body, EgUI.text(section[1], 13, inner, { color = EgUI.GRAY }))
            table.insert(body, EgUI.vspan(2))
            for _, r in ipairs(rows) do table.insert(body, r) end
        end
    end
    self[1] = EgUI.sheet(w, self.dimen.h, body, true)
end

function More:openEntry(kind, target, label)
    if kind == "event" then
        self:close()
        self.ui:handleEvent(Event:new(target))
    elseif kind == "classic" then
        self:close()
        self.ui.menu:onShowMenu()
    else
        local index = self:menuIndex()
        local tab = {}
        for _, id in ipairs(target) do
            local item = index[id]
            if item then
                local subs = item.sub_item_table
                if not subs and item.sub_item_table_func then subs = item.sub_item_table_func() end
                -- one or two entries: show their contents directly;
                -- larger groups keep one row per entry (drill in)
                if subs and #target <= 2 then
                    for _, s in ipairs(subs) do table.insert(tab, s) end
                else
                    table.insert(tab, item)
                end
            end
        end
        self:close()
        UIManager:show(require("egsection"):new{ title = label, items = tab })
    end
end

function More:close()
    UIManager:close(self, "ui", self.dimen)
end

function More:onCloseWidget()
    if self.plugin.panel == self then self.plugin.panel = nil end
    if self[1] then self[1]:free() end
end

function More:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

return More
