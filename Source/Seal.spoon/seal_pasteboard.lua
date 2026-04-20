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

-- Send one JSON request to the query socket and return the raw response
-- bytes (nil on transport failure). Used for both the JSON path
-- (`get_full`) and the TSV path (`history`/`search`) — the caller
-- picks the framing by setting `preview_format` on the request.
local function socketSend(request)
    local body = hs.json.encode(request)
    if not body then return nil end
    -- printf writes the request line; nc reads one line, server
    -- responds, nc exits on EOF.
    local cmd = "/bin/sh -c " .. sq(
        "printf '%s\\n' " .. sq(body) ..
        " | " .. obj.nc .. " -U " .. sq(obj.socketPath)
    )
    local f = io.popen(cmd, "r")
    if not f then return nil end
    local out = f:read("*a")
    f:close()
    if not out or out == "" then return nil end
    return out
end

local function socketJson(request)
    local out = socketSend(request)
    if not out then return nil end
    return hs.json.decode(out)
end

-- Parse a TSV body (one record per line, fields separated by \t):
-- id \t device_id \t created_at \t source_app_name \t truncated(0|1) \t preview_line
-- string.gmatch in Lua beats hs.json.decode on nested tables by ~10x
-- because there are no per-row table allocations for metadata.
local function parseTsv(body)
    local choices = {}
    if not body or body == "" then return choices end
    for line in body:gmatch("([^\n]+)") do
        local id, dev, created, app, trunc, preview =
            line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if id and id ~= "" and preview and preview ~= "" then
            local sub = {}
            if app ~= "" then sub[#sub + 1] = app end
            if dev ~= "" then sub[#sub + 1] = dev end
            if created ~= "" then sub[#sub + 1] = created end
            if trunc == "1" then sub[#sub + 1] = "…truncated" end
            choices[#choices + 1] = {
                uuid = id,
                text = preview,
                plugin = obj.__name,
                type = "copy",
                subText = table.concat(sub, " · "),
            }
        end
    end
    return choices
end

local function fetchHistory(limit)
    local body = socketSend({
        cmd = "history",
        limit = limit,
        preview_chars = obj.previewChars,
        preview_format = "tsv",
    })
    return parseTsv(body)
end

local function fetchSearch(query, limit)
    local body = socketSend({
        cmd = "search",
        query = query,
        limit = limit,
        preview_chars = obj.previewChars,
        preview_format = "tsv",
    })
    return parseTsv(body)
end

local function fetchFull(id)
    if not id or id == "" then return nil end
    local resp = socketJson({ cmd = "get_full", id = id })
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
