--- ==== Seal.plugins.pasteboard ====
---
--- Clipboard history backed by the clipboard-cli sync daemon.
---
--- Per-keystroke list responses carry only a SUBSTR preview of each
--- entry's text; full text is fetched on paste. All socket traffic
--- goes through `nc -U` via `io.popen` — no login shell, no
--- clipboard-cli process startup, no hs.execute round-trip.
local obj = {}
obj.__index = obj
obj.__name = "seal_pasteboard"

--- Seal.plugins.pasteboard.historyLimit — max rows on open.
obj.historyLimit = 500

--- Seal.plugins.pasteboard.searchLimit — max rows per keystroke.
obj.searchLimit = 500

--- Seal.plugins.pasteboard.previewChars — SUBSTR window for list rows.
obj.previewChars = 500

--- Seal.plugins.pasteboard.socketPath — Unix socket the sync daemon listens on.
obj.socketPath = (os.getenv("HOME") or "") ..
    "/Library/Application Support/clipboard-sync/query.sock"

--- Seal.plugins.pasteboard.nc — path to a `nc`/`netcat` that supports `-U`.
obj.nc = "/usr/bin/nc"

function obj:commands()
    return {
        pb = {
            cmd = "pb",
            fn = obj.choicesPasteboardCommand,
            name = "Pasteboard",
            description = "Pasteboard history",
            plugin = obj.__name,
        },
    }
end

function obj:bare()
    return nil
end

-- Minimal shell-escape for single-quoted arguments.
local function sq(s)
    return "'" .. (s or ""):gsub("'", [['\'']]) .. "'"
end

-- Send one newline-delimited JSON request to the query socket. Returns
-- the decoded response table (possibly with an `error` key) or nil on
-- transport failure.
local function socketCall(request)
    local body = hs.json.encode(request)
    if not body then return nil end
    -- printf avoids a trailing newline issue; nc writes, reads one
    -- response line, and exits.
    local cmd = "/bin/sh -c " .. sq(
        "printf '%s\\n' " .. sq(body) ..
        " | " .. obj.nc .. " -U " .. sq(obj.socketPath)
    )
    local f = io.popen(cmd, "r")
    if not f then return nil end
    local out = f:read("*a")
    f:close()
    if not out or out == "" then return nil end
    return hs.json.decode(out)
end

local function previewToChoice(p)
    if not p.preview or p.preview == "" then return nil end

    local subparts = {}
    local app = p.metadata and p.metadata.source_app_name
    if app and app ~= "" then table.insert(subparts, app) end
    if p.device_id and p.device_id ~= "" then
        table.insert(subparts, p.device_id)
    end
    if p.created_at and p.created_at ~= "" then
        table.insert(subparts, p.created_at)
    end
    if p.truncated then table.insert(subparts, "…truncated") end

    -- hs.chooser renders `text` as a single line — grabbing the first
    -- non-blank line of the SUBSTR preview keeps the row readable
    -- without running gmatch across the whole preview.
    local first = p.preview:match("([^\r\n]+)") or p.preview

    return {
        uuid = p.id,
        text = first,
        plugin = obj.__name,
        type = "copy",
        subText = table.concat(subparts, " · "),
    }
end

local function previewsToChoices(previews)
    local choices = {}
    if not previews then return choices end
    for i = 1, #previews do
        local c = previewToChoice(previews[i])
        if c then choices[#choices + 1] = c end
    end
    return choices
end

local function fetchHistory(limit)
    local resp = socketCall({
        cmd = "history",
        limit = limit,
        preview_chars = obj.previewChars,
    })
    if not resp then return {} end
    if resp.error then
        print("seal_pasteboard: history error: " .. tostring(resp.error))
        return {}
    end
    return previewsToChoices(resp.previews)
end

local function fetchSearch(query, limit)
    local resp = socketCall({
        cmd = "search",
        query = query,
        limit = limit,
        preview_chars = obj.previewChars,
    })
    if not resp then return {} end
    if resp.error then
        print("seal_pasteboard: search error: " .. tostring(resp.error))
        return {}
    end
    return previewsToChoices(resp.previews)
end

local function fetchFull(id)
    if not id or id == "" then return nil end
    local resp = socketCall({ cmd = "get_full", id = id })
    if not resp or resp.error or not resp.entry then return nil end
    return resp.entry.text_content
end

local function checkSyncStatus()
    local home = os.getenv("HOME")
    if not home then return nil end
    local path = home .. "/Library/Application Support/clipboard-sync/sync-status.json"
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local status = hs.json.decode(content)
    if not status then return nil end
    if status.status ~= "ok" then
        return status.error or "Unknown sync error"
    end
    return nil
end

function obj.choicesPasteboardCommand(query)
    local choices
    if not query or query == "" then
        choices = fetchHistory(obj.historyLimit)
    else
        choices = fetchSearch(query, obj.searchLimit)
    end

    local syncError = checkSyncStatus()
    if syncError then
        table.insert(choices, 1, {
            text = "⚠ Clipboard sync error",
            subText = syncError,
            plugin = obj.__name,
            type = "warning",
        })
    end
    return choices
end

function obj.completionCallback(rowInfo)
    if rowInfo["type"] ~= "copy" then return end
    local full = fetchFull(rowInfo["uuid"])
    if not full or full == "" then
        print("seal_pasteboard: empty full text for " .. tostring(rowInfo["uuid"]))
        return
    end
    hs.pasteboard.setContents(full)

    if obj.seal and obj.seal.chooser then
        obj.seal.chooser:query("")
    end

    hs.timer.doAfter(0.05, function()
        hs.eventtap.keyStroke({ "cmd" }, "v")
    end)
end

return obj
