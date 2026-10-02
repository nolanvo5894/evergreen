--[[--
Evergreen home: makes the reader the Kindle's shell.

The home (homewidget.lua) is shown over the file manager whenever one is
created, i.e. at KOReader start and every time a book is closed. The file
manager's title-bar home icon opens it too, and "Home screen" is available as
a gesture action.
--]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Evergreen = WidgetContainer:extend{
    name = "evergreen",
    is_doc_only = false,
    BOOKIE_DIR = "/mnt/us/documents/Bookie",
    NOTES_FILE = "/mnt/us/documents/notes.txt",
}

function Evergreen:onDispatcherRegisterActions()
    Dispatcher:registerAction("evergreen_home", {
        category = "none",
        event = "ShowHomeScreen",
        title = _("Home screen"),
        general = true,
    })
end

function Evergreen:init()
    self:onDispatcherRegisterActions()
    if self.ui.document then
        -- reader: Evergreen's overlay replaces KOReader's top and bottom menus;
        -- closing the book brings the home back
        self:removeStockReaderZones()
        self:registerReaderZones()
        self.dots = require("egdots"):new{ plugin = self }
        self.ui.view:registerViewModule("evergreen_dots", self.dots)
        return
    end

    self.ui.menu:registerToMainMenu(self)
    self.show_home_on_show = G_reader_settings:nilOrTrue("evergreen_home_on_start")
    -- Sleep screen: Evergreen's wallpapers, no "Sleeping" message (set once,
    -- so a user's own later choice sticks)
    if G_reader_settings:hasNot("evergreen_sleep_screen_set") then
        local DataStorage = require("datastorage")
        G_reader_settings:saveSetting("screensaver_type", "random_image")
        G_reader_settings:saveSetting("screensaver_dir", DataStorage:getDataDir() .. "/wallpapers")
        G_reader_settings:makeFalse("screensaver_show_message")
        G_reader_settings:saveSetting("screensaver_img_background", "white")
        G_reader_settings:makeTrue("evergreen_sleep_screen_set")
    end
    -- Stopping SSH must not wait for connected clients, or a restart leaves a
    -- half-stopped server that refuses new connections.
    if G_reader_settings:hasNot("SSH_force_kill_clients") then
        G_reader_settings:makeTrue("SSH_force_kill_clients")
    end
    if self.ui.SSH then self.ui.SSH.force_kill_clients = G_reader_settings:isTrue("SSH_force_kill_clients") end
end

-- The file manager is the base layer under Evergreen's screens. It receives
-- "Show" from UIManager:show() before anything is painted, so putting the home
-- up here (not a tick later) means the file manager is never drawn: the
-- repaint starts at the topmost full-screen widget.
function Evergreen:onShow()
    if self.ui.document or self.shown_once then return end
    self.shown_once = true

    local bar = self.ui.title_bar
    if bar and bar.left_button then
        bar.left_icon_tap_callback = function() self:showHome() end
        bar.left_button.callback = bar.left_icon_tap_callback
    end

    if self.show_home_on_show then
        self:showHome()
    end
    -- development aid (setting evergreen_dev): /tmp/hs_open holding a
    -- folder path also opens the library there
    local f = G_reader_settings:isTrue("evergreen_dev") and io.open("/tmp/hs_open", "r")
    if f then
        local dir = f:read("*l")
        f:close()
        os.remove("/tmp/hs_open")
        if dir and dir ~= "" then
            self:showLibrary(dir, dir:match("([^/]+)$"))
        end
    end
end

function Evergreen:showHome()
    -- show the new home before closing the old one: one repaint, no gap
    local old = self.home
    local HomeWidget = require("homewidget")
    self.home = HomeWidget:new{ plugin = self }
    UIManager:show(self.home, "full")
    if old then UIManager:close(old) end
end

-- The library opens on top of the home, so closing it reveals the home.
function Evergreen:showLibrary(dir, title)
    local old = self.library
    local LibraryWidget = require("librarywidget")
    self.library = LibraryWidget:new{ plugin = self, dir = dir, title = title }
    UIManager:show(self.library, "full")
    if old then UIManager:close(old) end
end

--- Open a book from any Evergreen screen. The screens stay up until the
-- reader announces itself (ShowingReader), then close without a refresh.
function Evergreen:openBook(file)
    -- seamless: no "Opening…" box; our screen stays up until the first page
    require("apps/reader/readerui"):showReader(file, nil, true)
end

---------------------------------------------------------------------------
-- Reader

-- KOReader's own reader UI gets no touch zones: its top menu and bottom
-- settings menu (tap, swipe and drag) and its status bar. Page turns, links,
-- highlights and the Gestures plugin keep theirs.
function Evergreen:removeStockReaderZones()
    local noop = function() end
    local function ids(prefix)
        local zones = {}
        for _, suffix in ipairs{ "tap", "ext_tap", "swipe", "ext_swipe", "pan", "ext_pan" } do
            table.insert(zones, { id = prefix .. suffix })
        end
        return zones
    end
    -- the top menu registers at ReaderReady (and again on a resize)
    self.ui.menu.onReaderReady = noop
    self.ui.menu.initGesListener = noop
    self.ui:unRegisterTouchZones(ids("readermenu_"))
    -- the settings menu registered at its init, before plugins load
    self.ui.config.initGesListener = noop
    self.ui:unRegisterTouchZones(ids("readerconfigmenu_"))
    -- the status bar registers at ReaderReady
    local footer = self.ui.view and self.ui.view.footer
    if footer then footer.setupTouchZones = noop end
    -- gesture shortcuts for the table of contents and bookmarks open
    -- Evergreen's Contents panel instead of KOReader's lists
    if self.ui.toc then
        self.ui.toc.onShowToc = function() self:openReaderPanel("contents"); return true end
    end
    if self.ui.bookmark then
        self.ui.bookmark.onShowBookmark = function() self:openReaderPanel("bookmarks"); return true end
    end
end

function Evergreen:registerReaderZones()
    local function overrides()
        return {
            "readermenu_tap", "readermenu_ext_tap", "readerconfigmenu_tap", "readerconfigmenu_ext_tap",
            "tap_forward", "tap_backward",
        }
    end
    local show = function(ges) return self:onReaderTap(ges) end
    self.ui:registerTouchZones({
        { -- the chapter dot strip along the top edge: jump to a chapter
            id = "evergreen_chapter_strip",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 0.03 },
            overrides = { "evergreen_overlay_top", "readermenu_tap", "readermenu_ext_tap", "tap_forward", "tap_backward",
                "tap_top_left_corner", "tap_top_right_corner" },
            handler = function(ges)
                local chapter = self.dots and self.dots:chapterAt(ges.pos.x)
                if not chapter then return self:onReaderTap(ges) end
                if self.ui.link then self.ui.link:addCurrentLocationToStack() end
                self.ui:handleEvent(Event:new("GotoPage", chapter.page))
                return true
            end,
        },
        { -- middle of the page
            id = "evergreen_overlay_center",
            ges = "tap",
            screen_zone = { ratio_x = 0.3, ratio_y = 0.15, ratio_w = 0.4, ratio_h = 0.7 },
            overrides = overrides(),
            handler = show,
        },
        { -- top strip (also over the top corner gestures)
            id = "evergreen_overlay_top",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1/8 },
            overrides = (function()
                local o = overrides()
                table.insert(o, "tap_top_left_corner")
                table.insert(o, "tap_top_right_corner")
                return o
            end)(),
            handler = show,
        },
        { -- bottom strip (also over the bottom corner gestures)
            id = "evergreen_overlay_bottom",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 7/8, ratio_w = 1, ratio_h = 1/8 },
            overrides = (function()
                local o = overrides()
                table.insert(o, "tap_left_bottom_corner")
                table.insert(o, "tap_right_bottom_corner")
                return o
            end)(),
            handler = show,
        },
        { -- the swipes that used to pull the stock menus down / up
            id = "evergreen_overlay_swipe",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { "readermenu_swipe", "readermenu_ext_swipe", "readerconfigmenu_swipe", "readerconfigmenu_ext_swipe" },
            handler = function(ges)
                local y = ges.pos.y / Device.screen:getHeight()
                if (ges.direction == "south" and y < 1/5) or (ges.direction == "north" and y > 4/5) then
                    self:showOverlay()
                    return true
                end
            end,
        },
    })
end

-- Evergreen's page layout: fixed "L" side and top margins (room for the
-- position dots between the screen edge and the text).
Evergreen.MARGIN_H = "DCREREADER_CONFIG_H_MARGIN_SIZES_XX_LARGE" -- {30, 30}
Evergreen.MARGIN_T = "DCREREADER_CONFIG_T_MARGIN_SIZES_XX_LARGE" -- 30

function Evergreen:applyMargins()
    if not self.ui.rolling then return end
    local conf = self.ui.document.configurable
    local h = G_defaults:readSetting(self.MARGIN_H)
    local t = G_defaults:readSetting(self.MARGIN_T)
    local cur_h = conf.h_page_margins
    if not (type(cur_h) == "table" and cur_h[1] == h[1] and cur_h[2] == h[2]) then
        self.ui:handleEvent(Event:new("ConfigChange", "h_page_margins", h))
        self.ui:handleEvent(Event:new("SetPageHorizMargins", h))
    end
    if conf.t_page_margin ~= t then
        self.ui:handleEvent(Event:new("ConfigChange", "t_page_margin", t))
        self.ui:handleEvent(Event:new("SetPageTopMargin", t))
    end
end

-- The dots replace KOReader's status bar (footer) in the reader. The footer
-- is switched off for good (its touch zones are gone, see
-- removeStockReaderZones): gestures and PDF flipping mode can't bring it back.
function Evergreen:onReaderReady()
    self:applyMargins()
    local footer = self.ui.view and self.ui.view.footer
    if not (footer and footer.mode_list) then return end
    local off = footer.mode_list.off
    if footer.mode ~= off then
        footer:applyFooterMode(off)
        footer:onUpdateFooter(true) -- lets the view reclaim the footer's height
        UIManager:setDirty(self.ui.dialog, "partial")
    end
    G_reader_settings:saveSetting("reader_footer_mode", off)
    footer.onToggleFooterMode = function() end
    footer.onEnterFlippingMode = function() end
    footer.onExitFlippingMode = function() end
    footer:disableFooter()
end

function Evergreen:onReaderTap(ges)
    -- links and existing highlights keep their own tap behaviour
    if self.ui.highlight and self.ui.highlight:onTap(nil, ges) then return true end
    if self.ui.link and self.ui.link:onTap(nil, ges) then return true end
    self:showOverlay()
    return true
end

function Evergreen:showOverlay()
    if self.overlay then return end
    local Overlay = require("egoverlay")
    self.overlay = Overlay:new{ plugin = self }
    UIManager:show(self.overlay, "ui")
end

function Evergreen:openReaderPanel(what)
    if what == "search" then
        self.ui.search:onShowFulltextSearchInput()
        return
    end
    local panel
    if what == "text" then
        panel = require("egtext"):new{ plugin = self }
    elseif what == "contents" or what == "notes" or what == "bookmarks" then
        local tab = ({ notes = "highlights", bookmarks = "bookmarks" })[what] or "contents"
        panel = require("egcontents"):new{ plugin = self, tab = tab }
    elseif what == "more" then
        panel = require("egmore"):new{ plugin = self }
    end
    if panel then
        self.panel = panel
        UIManager:show(panel, "ui")
    end
end

function Evergreen:onShowHomeScreen()
    if self.ui.document then
        -- from a book: close it; the new file manager shows the home
        self.ui:onHome()
    else
        self:showHome()
    end
    return true
end

---------------------------------------------------------------------------
-- Actions used by the tiles

function Evergreen:libraryDir()
    return G_reader_settings:readSetting("home_dir") or "/mnt/us/documents"
end

function Evergreen:countBooks(dir)
    local n = 0
    if lfs.attributes(dir, "mode") ~= "directory" then return 0 end
    for f in lfs.dir(dir) do
        if f:match("%.epub$") or f:match("%.pdf$") or f:match("%.mobi$") or f:match("%.azw3$") then
            n = n + 1
        end
    end
    return n
end

function Evergreen:openFolder(dir)
    for _, key in ipairs({ "library", "home" }) do
        if self[key] then
            UIManager:close(self[key])
            self[key] = nil
        end
    end
    if self.ui.file_chooser then
        self.ui.file_chooser:changeToPath(dir)
    end
end

function Evergreen:toggleWifi(home)
    local after = function()
        UIManager:scheduleIn(1, function() if self.home == home then self:showHome() end end)
    end
    if NetworkMgr:isWifiOn() then
        NetworkMgr:toggleWifiOff(after, true)
    else
        NetworkMgr:toggleWifiOn(after, nil, true)
    end
end

function Evergreen:toggleSSH(home)
    local ssh = self.ui.SSH
    if not ssh then return end
    -- key-only logins (keys in koreader/settings/SSH/authorized_keys)
    G_reader_settings:makeTrue("SSH_key_only_auth")
    ssh.key_only_auth = true
    if ssh:isRunning() then ssh:stop() else ssh:start() end
    UIManager:scheduleIn(1, function() if self.home == home then self:showHome() end end)
end

function Evergreen:exitToKindle()
    UIManager:broadcastEvent(Event:new("Exit"))
end

---------------------------------------------------------------------------

function Evergreen:addToMainMenu(menu_items)
    menu_items.evergreen = {
        text = _("Home screen"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Show home screen"),
                callback = function() self:showHome() end,
            },
            {
                text = _("Show home when KOReader starts"),
                checked_func = function() return G_reader_settings:nilOrTrue("evergreen_home_on_start") end,
                callback = function() G_reader_settings:flipNilOrTrue("evergreen_home_on_start") end,
            },
        },
    }
end

return Evergreen
