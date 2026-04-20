--- ==== Seal.plugins.pasteboard ====
---
--- Clipboard history backed by the clipboard-cli sync daemon. Per-keystroke
--- list responses carry only a short SUBSTR preview; full text is fetched
--- on selection via a separate socket round-trip, so payload size stays
--- flat regardless of how large the underlying clipboard entries are.
local obj = {}
obj.__index = obj
obj.__name = "seal_pasteboard"

--- Seal.plugins.pasteboard.historyLimit
--- Variable
---
--- Max rows shown when opening the picker with an empty query.
--- Preview-mode payload is ~500 B per row, so big numbers are cheap.
obj.historyLimit = 1000

--- Seal.plugins.pasteboard.searchLimit
--- Variable
---
--- Max rows returned per live-search keystroke. Preview-mode responses
--- are small enough that 5000 is snappy even on huge histories; the
--- underlying bottleneck is now hs.chooser render, not JSON size.
obj.searchLimit = 5000

function obj:commands()
    return {
        pb = {
            cmd = "pb",
            fn = obj.choicesPasteboardCommand,
            name = "Pasteboard",
            description = "Pasteboard history",
            plugin = obj.__name
        }
    }
end

function obj:bare()
    return nil
end

-- Creates a preview of text showing only the first few non-whitespace-only lines
-- @param text string The full text to preview
-- @param maxLines number Maximum number of non-whitespace-only lines to include (default 3)
-- @return string The preview text
local function createPreview(text, maxLines)
    maxLines = maxLines or 3
    local lines = {}
    local count = 0

    for line in text:gmatch("[^\r\n]*") do
        if line:match("%S") then
            table.insert(lines, line)
            count = count + 1
            if count >= maxLines then
                break
            end
        end
    end

    local preview = table.concat(lines, "\n")
    if #preview < #text then
        preview = preview .. " ..."
    end
    return preview
end

local function previewToChoice(p)
    if not p.preview or p.preview == "" then
        return nil
    end

    local parts = {}
    local app = p.metadata and p.metadata.source_app_name
    if app and app ~= "" then
        table.insert(parts, app)
    end
    if p.device_id and p.device_id ~= "" then
        table.insert(parts, p.device_id)
    end
    if p.created_at and p.created_at ~= "" then
        table.insert(parts, p.created_at)
    end
    if p.truncated then
        table.insert(parts, "…truncated")
    end

    return {
        uuid = p.id,
        text = createPreview(p.preview, 10),
        -- fullText intentionally omitted: the completion callback
        -- fetches the real text by id via `clipboard-cli paste`.
        plugin = obj.__name,
        type = "copy",
        subText = table.concat(parts, " · "),
    }
end

local function runCli(args)
    local cmd = "clipboard-cli " .. args
    local output, status = hs.execute(cmd, true)
    if not status then
        print("seal_pasteboard: clipboard-cli failed: " .. (output or ""))
        return nil
    end
    -- Strip shell integration escape sequences (e.g., iTerm2 OSC codes)
    -- that appear before the JSON output when using the user's login shell.
    if output then
        local jsonStart = output:find("[%[{]")
        if jsonStart then
            output = output:sub(jsonStart)
        end
    end
    return output
end

local function fetchHistory(limit)
    local output = runCli("history --limit " .. limit .. " --format json 2>/dev/null")
    if not output or output == "" then
        return {}
    end

    local previews = hs.json.decode(output)
    if not previews then
        return {}
    end

    local choices = {}
    for _, p in ipairs(previews) do
        local choice = previewToChoice(p)
        if choice then
            table.insert(choices, choice)
        end
    end
    return choices
end

local function fetchSearch(query, limit)
    -- Shell-escape the query to prevent injection
    local escaped = query:gsub("'", "'\\''")
    local output = runCli("search '" .. escaped .. "' --limit " .. limit .. " --format json 2>/dev/null")
    if not output or output == "" then
        return {}
    end

    local previews = hs.json.decode(output)
    if not previews then
        return {}
    end

    local choices = {}
    for _, p in ipairs(previews) do
        local choice = previewToChoice(p)
        if choice then
            table.insert(choices, choice)
        end
    end
    return choices
end

local function fetchFull(id)
    if not id or id == "" then return nil end
    local escaped = id:gsub("'", "'\\''")
    local cmd = "clipboard-cli paste '" .. escaped .. "' 2>/dev/null"
    local output, status = hs.execute(cmd, true)
    if not status then
        print("seal_pasteboard: clipboard-cli paste failed: " .. (output or ""))
        return nil
    end
    return output
end

local function checkSyncStatus()
    local home = os.getenv("HOME")
    if not home then return nil end
    -- macOS: ~/Library/Application Support/clipboard-sync/sync-status.json
    local statusPath = home .. "/Library/Application Support/clipboard-sync/sync-status.json"
    local f = io.open(statusPath, "r")
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
    if rowInfo["type"] == "copy" then
        local full = fetchFull(rowInfo["uuid"])
        if not full or full == "" then
            print("seal_pasteboard: failed to fetch full text for " .. tostring(rowInfo["uuid"]))
            return
        end
        hs.pasteboard.setContents(full)

        if obj.seal and obj.seal.chooser then
            obj.seal.chooser:query("")
        end

        hs.timer.doAfter(0.05, function()
            hs.eventtap.keyStroke({"cmd"}, "v")
        end)
    end
end

return obj
