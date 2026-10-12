--[[--
Bookie sync: keeps the reading position and highlights of the open book in
sync with a Bookie server (POST /api/koreader/sync, see server/koreader.js).

Books are matched by KOReader's partial MD5, so the device must hold the same
EPUB file that is in the Bookie library. The server translates between
xpointers and epub.js CFIs; this plugin only speaks xpointers.

Each device keeps its own reading position in Bookie: this one is never moved
from the server (only a book never read here opens at the latest place).
"Other devices" in the menu lists where the Mac, the iPhone… are, to jump to.

The library: "Download new books now" (or, when "Download new books
automatically" is on, the file manager every so often) downloads new EPUBs into
the Bookie folder (/mnt/us/documents/Bookie on a Kindle), so
they show up here. Books already on the device (any folder under the home
folder, matched by partial MD5) aren't downloaded again.

Per book, the sidecar keeps:
  bookie_known        set of Bookie annotation ids last seen on this device
                      (an id that disappears locally is a local delete)
  bookie_progress_at  epoch ms of the last page turn made here

Settings live in settings/bookiesync.lua: server, token, auto_sync, device_id,
library_dir, library_auto (off by default), library_md5 (cache of local files'
partial MD5s), library_at.
--]]

local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local DATETIME_FMT = "%Y-%m-%d %H:%M:%S"
local LIBRARY_EVERY = 30 -- seconds between automatic library checks (each is one small request)

-- LuaJSON decodes null to a sentinel; keep only real values.
local function val(x)
    local t = type(x)
    if t == "string" or t == "number" or t == "table" or t == "boolean" then return x end
    return nil
end

local function str(x)
    x = val(x)
    if type(x) == "string" and x ~= "" then return x end
    return nil
end

local function toMs(datetime)
    if type(datetime) ~= "string" then return nil end
    local y, mo, d, h, mi, s = datetime:match("^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
    if not y then return nil end
    return os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) } * 1000
end

local function fromMs(ms)
    return os.date(DATETIME_FMT, math.floor((tonumber(ms) or os.time() * 1000) / 1000))
end

local function nowMs()
    return os.time() * 1000
end

local function keyOf(item)
    return (item.datetime or "") .. "|" .. tostring(item.pos0 or item.page)
end

local BookieSync = WidgetContainer:extend{
    name = "bookiesync",
    is_doc_only = false, -- the file manager instance keeps the library in step
}

function BookieSync:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/bookiesync.lua")
    self.armed = false   -- count page turns only after the opening sync
    self.busy = false
    self.ui.menu:registerToMainMenu(self)
    if not self.ui.document then self:scheduleLibrary(8, false) end
end

function BookieSync:deviceId()
    local id = self.settings:readSetting("device_id")
    if not id then
        math.randomseed(os.time())
        id = string.format("%08x", math.random(0, 0x7fffffff))
        self.settings:saveSetting("device_id", id)
        self.settings:flush()
    end
    return id
end

function BookieSync:isConfigured()
    return self.settings:readSetting("server") and self.settings:readSetting("token")
end

function BookieSync:autoSync()
    return self:isConfigured() and self.settings:nilOrTrue("auto_sync")
end

function BookieSync:isSupported()
    return self.ui.rolling ~= nil and self.ui.document and not self.ui.document.info.has_pages
end

---------------------------------------------------------------------------
-- HTTP

function BookieSync:post(payload, timeout)
    local server = self.settings:readSetting("server"):gsub("/+$", "")
    local body = JSON.encode(payload)
    local sink = {}
    socketutil:set_timeout(timeout or 5, (timeout or 5) * 3)
    local code, headers, status = socket.skip(1, http.request{
        url = server .. "/api/koreader/sync",
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. self.settings:readSetting("token"),
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = socketutil.table_sink(sink),
    })
    socketutil:reset_timeout()
    if headers == nil then
        return nil, "network error: " .. tostring(status or code)
    end
    if code ~= 200 then
        return nil, "server returned " .. tostring(code)
    end
    local ok, res = pcall(JSON.decode, table.concat(sink))
    if not ok or type(res) ~= "table" then
        return nil, "bad response"
    end
    return res
end

---------------------------------------------------------------------------
-- Payload

function BookieSync:collect()
    local items, present = {}, {}
    for _, item in ipairs(self.ui.annotation.annotations) do
        local kind = "bookmark"
        if item.drawer then
            kind = (item.note and item.note ~= "") and "note" or "highlight"
        end
        table.insert(items, {
            key = keyOf(item),
            bookie_id = item.bookie_id,
            kind = kind,
            pos0 = item.pos0,
            pos1 = item.pos1,
            page = item.page,
            text = item.text,
            note = item.note,
            color = item.color,
            drawer = item.drawer,
            chapter = item.chapter,
            created = toMs(item.datetime),
            updated = toMs(item.datetime_updated or item.datetime),
        })
        if item.bookie_id then present[item.bookie_id] = true end
    end
    local known_set = self.ui.doc_settings:readSetting("bookie_known") or {}
    local known, deleted = {}, {}
    for id in pairs(known_set) do
        table.insert(known, id)
        if not present[id] then table.insert(deleted, id) end
    end
    return {
        md5 = self.ui.doc_settings:readSetting("partial_md5_checksum")
              or util.partialMD5(self.ui.document.file),
        filename = self.ui.document.file:match("([^/]+)$"),
        device = Device.model or "KOReader",
        device_id = self:deviceId(),
        device_name = Device:isKindle() and "Kindle" or (Device:isKobo() and "Kobo" or "KOReader"),
        progress = {
            xpointer = self.ui.rolling:getLastProgress(),
            percentage = self.ui.rolling:getLastPercent(),
            at = self.ui.doc_settings:readSetting("bookie_progress_at") or 0,
            chapter = self:chapterTitle(),
        },
        annotations = items,
        deleted = deleted,
        known = known,
    }
end

function BookieSync:chapterTitle()
    local ok, title = pcall(function() return self.ui.toc:getTocTitleOfCurrentPage() end)
    if ok and type(title) == "string" and title ~= "" then return title end
    return nil
end

---------------------------------------------------------------------------
-- Applying the server's view

function BookieSync:indexOf(target)
    for i, item in ipairs(self.ui.annotation.annotations) do
        if item == target then return i end
    end
end

function BookieSync:removeItem(item)
    local index = self:indexOf(item)
    if index then self.ui.bookmark:removeItemByIndex(index) end
end

function BookieSync:addRemote(r)
    local doc = self.ui.document
    local item = {
        bookie_id = r.bookie_id,
        datetime = fromMs(val(r.created) or val(r.updated)),
        datetime_updated = fromMs(val(r.updated)),
        chapter = str(r.chapter),
    }
    if r.kind == "bookmark" then
        local page = str(r.page)
        if not page or not doc:isXPointerInDocument(page) then
            logger.warn("BookieSync: skipping unresolvable bookmark", page)
            return false
        end
        item.page = page
        item.chapter = item.chapter or self.ui.toc:getTocTitleByPage(page)
        item.text = str(r.text) or T(_("in %1"), item.chapter or "")
    else
        local pos0, pos1 = str(r.pos0), str(r.pos1)
        if not (pos0 and pos1 and doc:isXPointerInDocument(pos0) and doc:isXPointerInDocument(pos1)) then
            logger.warn("BookieSync: skipping unresolvable highlight", pos0, pos1)
            return false
        end
        item.page, item.pos0, item.pos1 = pos0, pos0, pos1
        item.drawer = str(r.drawer) or "lighten"
        item.color = str(r.color) or "yellow"
        item.note = str(r.note)
        local text = doc:getTextFromXPointers(pos0, pos1)
        item.text = str(r.text) or text
        item.chapter = item.chapter or self.ui.toc:getTocTitleByPage(pos0)
    end
    local index = self.ui.annotation:addItem(item)
    local ev = { item, index_modified = index }
    if item.drawer then
        if item.note then ev.nb_notes_added = 1 else ev.nb_highlights_added = 1 end
    end
    self.ui:handleEvent(Event:new("AnnotationsModified", ev))
    return true
end

function BookieSync:apply(res)
    local anns = self.ui.annotation.annotations
    local changed = 0

    -- ids for annotations created here
    local by_key = {}
    for _, item in ipairs(anns) do by_key[keyOf(item)] = item end
    for _, link in ipairs(val(res.links) or {}) do
        local item = by_key[link.key]
        if item and not item.bookie_id then item.bookie_id = link.id end
    end

    local by_id = {}
    for _, item in ipairs(anns) do
        if item.bookie_id then by_id[item.bookie_id] = item end
    end
    local known = self.ui.doc_settings:readSetting("bookie_known") or {}

    -- deleted in Bookie
    for _, id in ipairs(val(res.deleted) or {}) do
        if by_id[id] then
            self:removeItem(by_id[id])
            by_id[id] = nil
            changed = changed + 1
        end
        known[id] = nil
    end

    -- added or edited in Bookie
    for _, r in ipairs(val(res.annotations) or {}) do
        local id = str(r.bookie_id)
        local item = id and by_id[id]
        local remote_updated = tonumber(val(r.updated)) or 0
        if item then
            local local_updated = toMs(item.datetime_updated or item.datetime) or 0
            if remote_updated > local_updated + 999 then
                local moved = (str(r.pos0) or str(r.page)) ~= (item.pos0 or item.page)
                    or str(r.pos1) ~= item.pos1
                if moved then
                    self:removeItem(item)
                    self:addRemote(r)
                else
                    item.note = str(r.note)
                    if item.drawer then
                        item.color = str(r.color) or item.color
                        item.drawer = str(r.drawer) or item.drawer
                    end
                    self.ui:handleEvent(Event:new("AnnotationsModified", { item }))
                    item.datetime_updated = fromMs(remote_updated)
                end
                changed = changed + 1
            end
        elseif id and not known[id] then
            if self:addRemote(r) then changed = changed + 1 end
        end
    end

    -- remember which Bookie ids this device holds
    known = {}
    for _, item in ipairs(anns) do
        if item.bookie_id then known[item.bookie_id] = true end
    end
    self.ui.doc_settings:saveSetting("bookie_known", known)

    -- where the other devices are, for the "Other devices" menu
    self.others = val(res.others) or {}

    -- a book never read here opens at the latest place (sent only then)
    local p = val(res.progress)
    local jumped
    if p and str(p.xpointer) and p.xpointer ~= self.ui.rolling:getLastProgress()
            and self.ui.document:isXPointerInDocument(p.xpointer) then
        self.jumping = true
        self.ui:handleEvent(Event:new("GotoXPointer", p.xpointer))
        self.jumping = false
        self.ui.doc_settings:saveSetting("bookie_progress_at", tonumber(val(p.at)) or nowMs())
        jumped = math.floor((tonumber(val(p.percentage)) or 0) * 100 + 0.5)
    end

    if changed > 0 then
        UIManager:setDirty(self.ui.dialog, "ui")
    end
    return changed, jumped
end

---------------------------------------------------------------------------
-- Sync

function BookieSync:sync(reason, interactive)
    if not self:isConfigured() or not self:isSupported() or self.busy then return end
    self.busy = true
    local ok, err = pcall(function()
        local res, net_err = self:post(self:collect(), interactive and 10 or 4)
        if not res then error(net_err, 0) end
        if not res.matched then
            if interactive then
                UIManager:show(InfoMessage:new{ text = _("This book is not in the Bookie library.") })
            end
            return
        end
        if reason == "close" then return end -- document is going away; next open reconciles
        self.applying = true
        local changed, jumped = self:apply(res)
        self.applying = false
        self.ui:saveSettings()
        local msg
        if jumped then
            msg = T(_("Bookie: jumped to %1%"), jumped)
        elseif interactive then
            msg = T(_("Bookie: synced (%1 changes)"), changed)
        elseif changed > 0 then
            msg = T(_("Bookie: %1 highlight changes"), changed)
        end
        if msg then UIManager:show(Notification:new{ text = msg }) end
        self.settings:saveSetting("last_sync", os.date(DATETIME_FMT))
        self.settings:delSetting("last_error")
    end)
    self.applying = false
    self.busy = false
    if not ok then
        logger.warn("BookieSync:", reason, err)
        self.settings:saveSetting("last_error", os.date(DATETIME_FMT) .. " " .. tostring(err))
        if interactive then
            UIManager:show(InfoMessage:new{ text = T(_("Bookie sync failed:\n%1"), tostring(err)) })
        end
    end
    self.settings:flush()
end

function BookieSync:scheduleSync(delay, reason)
    if not self:autoSync() then return end
    if self._scheduled then UIManager:unschedule(self._scheduled) end
    self._scheduled = function()
        self._scheduled = nil
        self:sync(reason)
    end
    UIManager:scheduleIn(delay, self._scheduled)
end

---------------------------------------------------------------------------
-- Other devices (where the Mac, the iPhone… are in this book)

local function ago(ms)
    ms = tonumber(ms)
    if not ms or ms <= 0 then return nil end
    local s = os.time() - math.floor(ms / 1000)
    if s < 60 then return _("just now") end
    if s < 3600 then return T(_("%1 min ago"), math.floor(s / 60)) end
    if s < 86400 then return T(_("%1 h ago"), math.floor(s / 3600)) end
    return os.date("%d %b", math.floor(ms / 1000))
end

function BookieSync:othersMenu()
    self:sync("devices") -- refresh first (a few seconds at most)
    local items = {}
    for _, o in ipairs(self.others or {}) do
        local xp = str(o.xpointer)
        if xp then
            local parts = { str(o.device) or "?",
                            math.floor((tonumber(val(o.percentage)) or 0) * 100 + 0.5) .. "%" }
            if str(o.chapter) then table.insert(parts, o.chapter) end
            table.insert(parts, ago(val(o.at)))
            table.insert(items, {
                text = table.concat(parts, " · "),
                callback = function()
                    -- a page change like any other: this device's place follows
                    if self.ui.document:isXPointerInDocument(xp) then
                        self.ui:handleEvent(Event:new("GotoXPointer", xp))
                    end
                end,
            })
        end
    end
    if #items == 0 then
        items = {{ text = _("No other device has read this book yet."), enabled = false }}
    end
    return items
end

---------------------------------------------------------------------------
-- Library: new EPUBs in Bookie are downloaded into the Bookie folder

function BookieSync:libraryDir()
    local dir = self.settings:readSetting("library_dir")
    if dir then return dir end
    if Device:isKindle() then return "/mnt/us/documents/Bookie" end
    return (G_reader_settings:readSetting("home_dir") or DataStorage:getDataDir()) .. "/Bookie"
end

function BookieSync:homeDir()
    if Device:isKindle() then return "/mnt/us/documents" end
    return G_reader_settings:readSetting("home_dir") or self:libraryDir()
end

function BookieSync:get(path, timeout)
    local server = self.settings:readSetting("server"):gsub("/+$", "")
    local sink = {}
    socketutil:set_timeout(timeout or 5, (timeout or 5) * 3)
    local code, headers, status = socket.skip(1, http.request{
        url = server .. path,
        method = "GET",
        headers = { ["Authorization"] = "Bearer " .. self.settings:readSetting("token") },
        sink = socketutil.table_sink(sink),
    })
    socketutil:reset_timeout()
    if headers == nil then return nil, "network error: " .. tostring(status or code) end
    if code ~= 200 then return nil, "server returned " .. tostring(code) end
    local ok, res = pcall(JSON.decode, table.concat(sink))
    if not ok or type(res) ~= "table" then return nil, "bad response" end
    return res
end

--- Partial MD5s of the EPUBs already anywhere under the home folder (cached
--- per file by size and mtime, so only new files are read).
function BookieSync:localMd5s()
    local cache = self.settings:readSetting("library_md5") or {}
    local fresh, have = {}, {}
    local function scan(dir, depth)
        if depth > 4 then return end
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok or not iter then return end
        for name in iter, obj do
            if name ~= "." and name ~= ".." and not name:match("^%.") then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    if not name:match("%.sdr$") then scan(path, depth + 1) end
                elseif attr and name:lower():match("%.epub$") then
                    local stamp = tostring(attr.size) .. ":" .. tostring(attr.modification)
                    local hit = cache[path]
                    local md5 = (hit and hit.stamp == stamp) and hit.md5 or util.partialMD5(path)
                    if md5 then
                        fresh[path] = { stamp = stamp, md5 = md5 }
                        have[md5] = true
                    end
                end
            end
        end
    end
    scan(self:homeDir(), 0)
    self.settings:saveSetting("library_md5", fresh)
    return have
end

local function safeName(s)
    s = tostring(s or ""):gsub("[%c/\\:%*%?\"<>|]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #s > 80 then
        s = s:sub(1, 80)
        -- don't end inside a UTF-8 character
        while #s > 0 and s:byte(#s) >= 0x80 and s:byte(#s) < 0xC0 do s = s:sub(1, -2) end
        if #s > 0 and s:byte(#s) >= 0xC0 then s = s:sub(1, -2) end
        s = s:gsub("%s+$", "")
    end
    return s
end

function BookieSync:download(book, dir)
    local title = safeName(book.title)
    if title == "" then title = "Untitled" end
    local author = safeName(book.author)
    local name = author ~= "" and (title .. " - " .. author) or title
    local path = dir .. "/" .. name .. ".epub"
    if lfs.attributes(path, "mode") then path = dir .. "/" .. name .. " (" .. book.id:sub(1, 8) .. ").epub" end
    local tmp = path .. ".part"
    local fh, err = io.open(tmp, "wb")
    if not fh then return nil, err end
    local server = self.settings:readSetting("server"):gsub("/+$", "")
    socketutil:set_timeout(20, 600)
    local code, headers, status = socket.skip(1, http.request{
        url = server .. "/api/books/" .. book.id .. "/file",
        method = "GET",
        headers = { ["Authorization"] = "Bearer " .. self.settings:readSetting("token") },
        sink = socketutil.file_sink(fh),
    })
    socketutil:reset_timeout()
    pcall(fh.close, fh)
    local size = lfs.attributes(tmp, "size") or 0
    local want = tonumber(val(book.size)) or 0
    if headers == nil or code ~= 200 or size == 0 or (want > 0 and size ~= want) then
        os.remove(tmp)
        return nil, "download failed: " .. tostring(status or code)
    end
    os.rename(tmp, path)
    return path
end

function BookieSync:syncLibrary(interactive)
    if not self:isConfigured() or self.library_busy then return end
    self.library_busy = true
    local queued = false
    local ok, err = pcall(function()
        local res, net_err = self:get("/api/koreader/library", interactive and 10 or 5)
        if not res then error(net_err, 0) end
        local have = self:localMd5s()
        local missing = {}
        for _, b in ipairs(val(res.books) or {}) do
            if str(b.id) and str(b.md5) and not have[b.md5] then table.insert(missing, b) end
        end
        self.settings:saveSetting("library_at", os.time())
        self.settings:delSetting("library_error")
        self.settings:flush()
        if #missing == 0 then
            if interactive then UIManager:show(InfoMessage:new{ text = _("Bookie: no new books.") }) end
            return
        end
        UIManager:show(Notification:new{ text = T(_("Bookie: downloading %1 new books…"), #missing) })
        util.makePath(self:libraryDir())
        queued = true
        UIManager:scheduleIn(1, function() self:downloadNext(missing, 1, 0) end)
    end)
    if not queued then self.library_busy = false end
    if not ok then
        logger.warn("BookieSync library:", err)
        self.settings:saveSetting("library_error", os.date(DATETIME_FMT) .. " " .. tostring(err))
        self.settings:flush()
        if interactive then
            UIManager:show(InfoMessage:new{ text = T(_("Bookie library check failed:\n%1"), tostring(err)) })
        end
    end
end

-- One book at a time, giving the UI a moment between downloads.
function BookieSync:downloadNext(list, i, done)
    if i > #list then
        self.library_busy = false
        UIManager:show(Notification:new{ text = T(_("Bookie: %1 new books in the Bookie folder"), done) })
        if self.ui.file_chooser then self.ui.file_chooser:refreshPath() end
        UIManager:broadcastEvent(Event:new("BookieLibraryChanged"))
        return
    end
    local path, err = self:download(list[i], self:libraryDir())
    if path then done = done + 1 else logger.warn("BookieSync download", list[i].id, err) end
    UIManager:scheduleIn(0.5, function() self:downloadNext(list, i + 1, done) end)
end

-- Automatic checks: in the file manager only, at most every LIBRARY_EVERY.
function BookieSync:scheduleLibrary(delay)
    if self.ui.document or not self:autoSync() or not self.settings:isTrue("library_auto") then return end
    if os.time() - (self.settings:readSetting("library_at") or 0) < LIBRARY_EVERY then return end
    if self._library then UIManager:unschedule(self._library) end
    self._library = function()
        self._library = nil
        self:syncLibrary(false)
    end
    UIManager:scheduleIn(delay, self._library)
end

---------------------------------------------------------------------------
-- Events

function BookieSync:onReaderReady()
    if not self:autoSync() or not self:isSupported() then
        self.armed = true
        return
    end
    UIManager:scheduleIn(1, function()
        self:sync("open")
        self.armed = true
    end)
end

function BookieSync:onPageUpdate()
    if not self.armed or self.jumping or not self:isSupported() then return end
    self.ui.doc_settings:saveSetting("bookie_progress_at", nowMs())
    self:scheduleSync(60, "page")
end

function BookieSync:onAnnotationsModified()
    if self.applying or not self.armed then return end
    self:scheduleSync(5, "annotations")
end

function BookieSync:onCloseDocument()
    if self._scheduled then
        UIManager:unschedule(self._scheduled)
        self._scheduled = nil
    end
    if self:autoSync() then self:sync("close") end
end

function BookieSync:onSuspend()
    if self:autoSync() then self:sync("suspend") end
end

function BookieSync:onResume()
    self:scheduleSync(3, "resume")
    self:scheduleLibrary(6)
end

function BookieSync:onNetworkConnected()
    self:scheduleSync(2, "network")
    self:scheduleLibrary(4)
end

---------------------------------------------------------------------------
-- Menu

function BookieSync:editSetting(key, title, hint)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self.settings:readSetting(key) or "",
        input_hint = hint,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                if v == "" then self.settings:delSetting(key) else self.settings:saveSetting(key, v) end
                self.settings:flush()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BookieSync:addToMainMenu(menu_items)
    menu_items.bookie_sync = {
        text = _("Bookie sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync now"),
                enabled_func = function() return self:isConfigured() and self:isSupported() end,
                callback = function() self:sync("manual", true) end,
            },
            {
                text = _("Other devices"),
                enabled_func = function() return self:isConfigured() and self:isSupported() end,
                sub_item_table_func = function() return self:othersMenu() end,
            },
            {
                text = _("Download new books now"),
                enabled_func = function() return self:isConfigured() end,
                callback = function() self:syncLibrary(true) end,
            },
            {
                text = _("Download new books automatically"),
                checked_func = function() return self.settings:isTrue("library_auto") end,
                callback = function()
                    self.settings:flipNilOrFalse("library_auto")
                    self.settings:flush()
                end,
            },
            {
                text = _("Sync automatically"),
                checked_func = function() return self.settings:nilOrTrue("auto_sync") end,
                callback = function()
                    self.settings:flipNilOrTrue("auto_sync")
                    self.settings:flush()
                end,
            },
            {
                text_func = function()
                    return T(_("Server: %1"), self.settings:readSetting("server") or _("not set"))
                end,
                keep_menu_open = true,
                callback = function()
                    self:editSetting("server", _("Bookie server"), "http://192.168.1.10:8080")
                end,
            },
            {
                text_func = function()
                    return self.settings:readSetting("token") and _("Token: set") or _("Token: not set")
                end,
                keep_menu_open = true,
                callback = function() self:editSetting("token", _("Bookie token")) end,
            },
            {
                text_func = function()
                    local err = self.settings:readSetting("last_error") or self.settings:readSetting("library_error")
                    if err then return T(_("Last error: %1"), err) end
                    return T(_("Last sync: %1"), self.settings:readSetting("last_sync") or _("never"))
                end,
                keep_menu_open = true,
                callback = function() end,
            },
        },
    }
end

return BookieSync
