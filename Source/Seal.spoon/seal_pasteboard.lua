--- ==== Seal.plugins.pasteboard ====
---
--- Clipboard history via clipboard-cli service with fuzzy search (nucleo)
local obj = {}
obj.__index = obj
obj.__name = "seal_pasteboard"

--- Seal.plugins.pasteboard.historyLimit
--- Variable
---
--- The number of history items to fetch. Defaults to 50
obj.historyLimit = 50

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

local function entryToChoice(entry)
    if not entry.text_content or entry.text_content == "" then
        return nil
    end

    return {
        uuid = entry.id,
        text = createPreview(entry.text_content, 10),
        fullText = entry.text_content,
        plugin = obj.__name,
        type = "copy",
        subText = (entry.device_id or "") .. " :: " .. (entry.created_at or ""),
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
    -- that appear before the JSON output when using the user's login shell
    if output then
        local jsonStart = output:find("%[")
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

    local entries = hs.json.decode(output)
    if not entries then
        return {}
    end

    local choices = {}
    for _, entry in ipairs(entries) do
        local choice = entryToChoice(entry)
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

    local entries = hs.json.decode(output)
    if not entries then
        return {}
    end

    local choices = {}
    for _, entry in ipairs(entries) do
        local choice = entryToChoice(entry)
        if choice then
            table.insert(choices, choice)
        end
    end
    return choices
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
        choices = fetchSearch(query, obj.historyLimit)
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
        hs.pasteboard.setContents(rowInfo["fullText"])

        if obj.seal and obj.seal.chooser then
            obj.seal.chooser:query("")
        end

        hs.timer.doAfter(0.05, function()
            hs.eventtap.keyStroke({"cmd"}, "v")
        end)
    end
end

return obj
