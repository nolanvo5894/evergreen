--[[--
Shows a KOReader settings sub-tree (menu items: text/text_func, checked_func,
enabled_func, callback, sub_item_table[_func]) as an Evergreen list. Sub-menus
drill in with a back step; toggles show On/Off; items run their own callbacks,
so all existing settings logic is reused unchanged.
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local EgUI = require("egui")
local _ = require("gettext")
local Screen = Device.screen
local S = EgUI.S

local PER_PAGE = 12

local Section = InputContainer:extend{
    title = nil,
    items = nil, -- menu item list
    covers_fullscreen = true,
}

function Section:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
    self.stack = {} -- { title, items, page } of parents
    self.page = 1
    self:build()
end

local function itemText(item)
    local t = item.text_func and item.text_func() or item.text or ""
    return (t:gsub("\n.*", ""))
end

local function visible(items)
    local out = {}
    for _, item in ipairs(items or {}) do
        if type(item) == "table" and item.id ~= "----------------------------"
                and (item.text or item.text_func) then
            table.insert(out, item)
        end
    end
    return out
end

local function subItems(item)
    if item.sub_item_table_func then return item.sub_item_table_func() end
    return item.sub_item_table
end

function Section:build()
    if self[1] then self[1]:free() end
    local w = self.dimen.w
    local inner = w - 2 * S(16)
    local items = visible(self.items)
    self.pages = math.max(1, math.ceil(#items / PER_PAGE))
    self.page = math.max(1, math.min(self.page, self.pages))

    local body = VerticalGroup:new{ align = "left" }
    local title = self.title
    if #self.stack > 0 then title = "‹ " .. title end
    table.insert(body, EgUI.spread(inner, S(40),
        EgUI.tap(EgUI.text(title, 19, inner - S(60), { bold = true }), function()
            if #self.stack > 0 then self:back() end
        end),
        EgUI.tap(EgUI.text("✕", 19, S(44)), function() self:close() end)))
    table.insert(body, EgUI.vspan(6))
    table.insert(body, EgUI.line(inner, EgUI.GRAY))

    for i = (self.page - 1) * PER_PAGE + 1, math.min(#items, self.page * PER_PAGE) do
        local item = items[i]
        local enabled = not item.enabled_func or item.enabled_func()
        local value
        local subs = item.sub_item_table or item.sub_item_table_func
        if item.checked_func then
            value = item.checked_func() and _("On") or _("Off")
        elseif item.radio and item.checked_func == nil and item.checked then
            value = "✓"
        elseif subs then
            value = "›"
        end
        table.insert(body, EgUI.listRow(inner, itemText(item), value,
            enabled and function() self:activate(item) end or nil,
            { pad = 9, color = not enabled and EgUI.LIGHT or nil }))
    end

    self[1] = EgUI.sheet(w, self.dimen.h, OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = self.dimen.h - S(26) },
        body,
        self.pages > 1 and VerticalGroup:new{
            VerticalSpan:new{ width = self.dimen.h - S(26) - S(40) },
            EgUI.pager(inner, self.page, self.pages, function(d) self:turn(d) end),
        } or nil,
    }, true)
end

-- What item callbacks get as `touchmenu_instance`.
function Section:updateItems() self:refresh() end
function Section:closeMenu() self:close() end
function Section:onClose() self:close() end

function Section:activate(item)
    local subs = (item.sub_item_table or item.sub_item_table_func) and subItems(item)
    if subs then
        table.insert(self.stack, { title = self.title, items = self.items, page = self.page })
        self.title, self.items, self.page = itemText(item), subs, 1
        self:refresh()
        return
    end
    if item.callback then
        item.callback(self)
    end
    -- callbacks may open their own dialog on top; our list stays, updated
    self:refresh()
end

function Section:back()
    local prev = table.remove(self.stack)
    if not prev then return end
    self.title, self.items, self.page = prev.title, prev.items, prev.page
    self:refresh()
end

function Section:turn(d)
    local p = self.page + d
    if p < 1 or p > self.pages then return end
    self.page = p
    self:refresh()
end

function Section:onSwipe(_, ges)
    if ges.direction == "west" then self:turn(1)
    elseif ges.direction == "east" then self:turn(-1)
    else return false end
    return true
end

function Section:refresh()
    self:build()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function Section:close()
    UIManager:close(self, "ui", self.dimen)
end

function Section:onCloseWidget()
    if self[1] then self[1]:free() end
end

function Section:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

return Section
