--[[--
Evergreen home: makes the reader the Kindle's shell.

The home (homewidget.lua) is shown over the file manager whenever one is
created, i.e. at KOReader start and every time a book is closed. The file
manager's title-bar home icon opens it too, and "Home screen" is available as
a gesture action.
--]]

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
    if self.ui.document then return end -- reader: closing the book brings the home back

    self.ui.menu:registerToMainMenu(self)
    self.show_home_on_show = G_reader_settings:nilOrTrue("evergreen_home_on_start")
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

function Evergreen:onShowHomeScreen()
    if self.ui.document then
        -- from a book: close it; the new file manager shows the home
        self.ui:onClose()
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
