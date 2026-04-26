--- === Seal ===
---
--- Pluggable launch bar
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/Seal.spoon.zip](https://github.com/Hammerspoon/Spoons/raw/master/Spoons/Seal.spoon.zip)
---
--- Seal includes a number of plugins, which you can choose to load (see `:loadPlugins()` below):
---  * apps : Launch applications by name
---  * calc : Simple calculator
---  * chrome_bookmarks : Search and open Google Chrome bookmarks
---  * rot13 : Apply ROT13 substitution cipher
---  * safari_bookmarks : Open Safari bookmarks (this is broken since at least High Sierra)
---  * screencapture : Lets you take screenshots in various ways
---  * urlformats : User defined URL formats to open
---  * useractions : User defined custom actions
---  * vpn : Connect and disconnect VPNs (currently supports Viscosity and macOS system preferences)


local obj = {}
obj.__index = obj

-- Metadata
obj.name = "Seal"
obj.version = "1.1"
obj.author = "Chris Jones <cmsj@tenshu.net>"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

obj.chooser = nil
obj.hotkeyShow = nil
obj.hotkeyToggle = nil
obj.plugins = {}
obj.commands = {}
obj.queryChangedTimer = nil

obj.spoonPath = hs.spoons.scriptPath()

--- Seal.queryChangedTimerDuration
--- Variable
--- Time between the last keystroke and the start of the recalculation of the choices to display, in seconds.
---
--- Notes:
---  * Defaults to 0.02s (20ms).
obj.queryChangedTimerDuration = 0.02

--- Seal.plugin_search_paths
--- Variable
--- List of directories where Seal will look for plugins. Defaults to `~/.hammerspoon/seal_plugins/` and the Seal Spoon directory.
obj.plugin_search_paths = { hs.configdir .. "/seal_plugins", obj.spoonPath }

--- Seal.frecency_enable
--- Variable
--- Enable recency-based result ranking (results you've selected before will be prioritized by how recently you used them).
---
--- Notes:
---  * Defaults to `true`
---  * When enabled, Seal will track which results you select and prioritize them in future searches
---  * Items you've selected before appear at the top, sorted by most recent first
obj.frecency_enable = true

--- Seal.frecency_storage_path
--- Variable
--- Path to the JSON file where frecency data is stored
---
--- Notes:
---  * Defaults to `~/.hammerspoon/seal_frecency.json`
obj.frecency_storage_path = hs.configdir .. "/seal_frecency.json"

--- Seal.pinnedPrefixes
--- Variable
--- A table mapping query prefixes to app/result names that should be pinned to the top
---
--- Notes:
---  * Defaults to `{}` (no pinned prefixes)
---  * When the query starts with a pinned prefix, the matching result is boosted above normal prefix/frecency ranking
---  * Matching is case-insensitive
---  * Example configuration in init.lua:
---    ```
---    spoon.Seal.pinnedPrefixes = {
---        ["vs"] = "Visual Studio Code",
---        ["ff"] = "Firefox",
---        ["cb"] = "Google Chrome",
---    }
---    ```
obj.pinnedPrefixes = {}

-- Internal frecency data structure
obj.frecency_data = {}

--- Seal:loadFrecencyData()
--- Method
--- Load frecency data from disk
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Seal object
function obj:loadFrecencyData()
    local file = io.open(self.frecency_storage_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local success, data = pcall(hs.json.decode, content)
        if success and data then
            self.frecency_data = data
        else
            print("-- Seal: Failed to parse frecency data, starting fresh")
            self.frecency_data = {}
        end
    else
        self.frecency_data = {}
    end
    return self
end

--- Seal:saveFrecencyData()
--- Method
--- Save frecency data to disk
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Seal object
function obj:saveFrecencyData()
    local file = io.open(self.frecency_storage_path, "w")
    if file then
        local success, json = pcall(hs.json.encode, self.frecency_data)
        if success and json then
            file:write(json)
            file:close()
        else
            print("-- Seal: Failed to encode frecency data")
        end
    else
        print("-- Seal: Failed to open frecency file for writing: " .. self.frecency_storage_path)
    end
    return self
end

--- Seal:recordSelection(query, uuid)
--- Method
--- Record a selection in the frecency database
---
--- Parameters:
---  * query - The query string used when the selection was made (currently unused, kept for API compatibility)
---  * uuid - The unique identifier of the selected item
---
--- Returns:
---  * The Seal object
function obj:recordSelection(query, uuid)
    if not self.frecency_enable or not uuid or uuid == "" then
        return self
    end

    -- Initialize data structure if needed
    if not self.frecency_data[uuid] then
        self.frecency_data[uuid] = {
            count = 0,
            last_used = 0
        }
    end

    -- Update usage data
    self.frecency_data[uuid].count = self.frecency_data[uuid].count + 1
    self.frecency_data[uuid].last_used = os.time()

    -- Save to disk
    self:saveFrecencyData()

    return self
end

--- Seal:calculateFrecencyScore(uuid, query)
--- Method
--- Calculate the recency score for a given item
---
--- Parameters:
---  * uuid - The unique identifier of the item
---  * query - The current query string (unused, kept for API compatibility)
---
--- Returns:
---  * The last_used timestamp (number), or 0 if no history exists
function obj:calculateFrecencyScore(uuid, query)
    if not self.frecency_enable or not uuid then
        return 0
    end

    if not self.frecency_data[uuid] then
        return 0
    end

    -- Return the last_used timestamp directly for sorting by recency
    return self.frecency_data[uuid].last_used or 0
end

--- Seal:sortChoices(choices, query)
--- Method
--- Sort choices using multi-level ranking with explicit precedence
---
--- Parameters:
---  * choices - A table of choice items
---  * query - The current query string (used for prefix matching)
---
--- Returns:
---  * The sorted choices table
---
--- Notes:
---  * Ranking dimensions in order of precedence:
---    1. Priority tier - High-priority plugins (score >= 50000) always win
---    2. Pinned/Provider prefix - Results matching pinnedPrefixes OR urlformat provider prefixes
---    3. Prefix match - Items starting with query beat substring matches
---    4. Frecency - Previously selected items ranked by most recent use
---    5. Alphabetical - Final tiebreaker for consistent ordering
---  * To add new ranking dimensions, insert a comparison block at the
---    appropriate precedence level in the sort comparator
function obj:sortChoices(choices, query)
    local HIGH_PRIORITY_THRESHOLD = 50000
    local query_lower = query and query:lower() or ""

    -- For choices returned via a command keyword (e.g. "t ai1"), the
    -- user-typed needle is the query *after* the keyword. Strip the
    -- keyword before comparing so prefix matches against the choice text
    -- actually fire — otherwise the leading "t " makes every choice a
    -- non-prefix match and frecency dominates.
    local function effectiveQuery(choice)
        if query_lower == "" or not choice.keyword then return query_lower end
        local prefix = choice.keyword:lower() .. " "
        if query_lower:sub(1, #prefix) == prefix then
            return (query_lower:sub(#prefix + 1):gsub("^%s+", ""))
        end
        return query_lower
    end

    -- Helper: check if text starts with query (prefix match)
    local function isPrefixMatch(choice)
        local q = effectiveQuery(choice)
        if q == "" then return false end
        local text = tostring(choice.text or "")
        return text:lower():sub(1, #q) == q
    end

    -- Helper: check if choice matches a pinned prefix for the current query
    local function isPinnedMatch(choice)
        if query_lower == "" then return false end
        local choice_text = tostring(choice.text or ""):lower()
        for prefix, pinned_name in pairs(self.pinnedPrefixes or {}) do
            local prefix_lower = prefix:lower()
            local pinned_lower = pinned_name:lower()
            -- Check if query starts with the pinned prefix
            if query_lower:sub(1, #prefix_lower) == prefix_lower then
                -- Check if this choice matches the pinned name
                if choice_text == pinned_lower or choice_text:find(pinned_lower, 1, true) then
                    return true
                end
            end
        end
        return false
    end

    -- Helper: check if choice is from a urlformat provider prefix command
    local function isUrlFormatProviderMatch(choice)
        if query_lower == "" then return false end
        -- Check if this is a urlformats choice
        if choice.plugin ~= "seal_urlformats" then return false end
        -- Check if query matches a urlformat provider prefix
        if not self.plugins.urlformats or not self.plugins.urlformats.providers then
            return false
        end
        -- Extract the first word from the query (the command part)
        local cmd = query:match("^%S+")
        if not cmd then return false end
        local cmd_lower = cmd:lower()
        -- Check if this command matches a provider key
        for provider_key, _ in pairs(self.plugins.urlformats.providers) do
            if provider_key:lower() == cmd_lower then
                -- Check if this choice is for this specific provider
                local uuid_suffix = "__" .. provider_key
                if choice.uuid and choice.uuid:find(uuid_suffix, 1, true) then
                    return true
                end
            end
        end
        return false
    end

    -- Helper: get display text for alphabetical sorting
    local function getSortText(choice)
        return tostring(choice.text or ""):lower()
    end

    -- Pre-compute ranking attributes for each choice
    for _, choice in ipairs(choices) do
        -- Priority tier (high priority = true)
        choice._high_priority = (choice._score or 0) >= HIGH_PRIORITY_THRESHOLD

        -- Pinned prefix match
        choice._pinned_match = isPinnedMatch(choice)

        -- URL format provider prefix match (same priority as pinned)
        choice._urlformat_provider_match = isUrlFormatProviderMatch(choice)

        -- Frecency score (0 if never selected, timestamp if selected)
        if self.frecency_enable and choice.uuid then
            choice._frecency = self:calculateFrecencyScore(choice.uuid, query)
        else
            choice._frecency = 0
        end

        -- Prefix match
        choice._prefix_match = isPrefixMatch(choice)

        -- Sort text
        choice._sort_text = getSortText(choice)
    end

    -- Sort using multi-level comparison
    table.sort(choices, function(a, b)
        -- 1. High priority tier wins (calc results, etc.)
        if a._high_priority ~= b._high_priority then
            return a._high_priority
        end

        -- 2. Pinned prefix match OR urlformat provider match wins (same priority)
        local a_pinned_or_provider = a._pinned_match or a._urlformat_provider_match
        local b_pinned_or_provider = b._pinned_match or b._urlformat_provider_match
        if a_pinned_or_provider ~= b_pinned_or_provider then
            return a_pinned_or_provider
        end

        -- 3. Prefix match wins
        if a._prefix_match ~= b._prefix_match then
            return a._prefix_match
        end

        -- 4. Higher frecency wins (more recently used)
        if a._frecency ~= b._frecency then
            return a._frecency > b._frecency
        end

        -- 5. Alphabetical (final tiebreaker)
        return a._sort_text < b._sort_text
    end)

    return choices
end

-- Backwards compatibility alias
function obj:sortChoicesByFrecency(choices, query)
    return self:sortChoices(choices, query)
end

--- Seal:clearFrecencyData()
--- Method
--- Clear all usage history (reset recency tracking)
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Seal object
function obj:clearFrecencyData()
    self.frecency_data = {}
    self:saveFrecencyData()
    print("-- Seal: Usage history cleared")
    return self
end

--- Seal:refreshCommandsForPlugin(plugin_name)
--- Method
--- Refresh the list of commands provided by the given plugin.
---
--- Parameters:
---  * plugin_name - the name of the plugin. Should be the name as passed to `loadPlugins()` or `loadPluginFromFile`.
---
--- Returns:
---  * The Seal object
---
--- Notes:
---  * Most Seal plugins expose a static list of commands (if any), which are registered at the time the plugin is loaded. This method is used for plugins which expose a dynamic or changing (e.g. depending on configuration) list of commands.
function obj:refreshCommandsForPlugin(plugin_name)
   plugin = self.plugins[plugin_name]
   if plugin.commands then
      for cmd,cmdInfo in pairs(plugin:commands()) do
         if not self.commands[cmd] then
            print("-- Adding Seal command: "..cmd)
            self.commands[cmd] = cmdInfo
         end
      end
   end
   return self
end

--- Seal:refreshAllCommands()
--- Method
--- Refresh the list of commands provided by all the currently loaded plugins.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Seal object
---
--- Notes:
---  * Most Seal plugins expose a static list of commands (if any), which are registered at the time the plugin is loaded. This method is used for plugins which expose a dynamic or changing (e.g. depending on configuration) list of commands.
function obj:refreshAllCommands()
   for p, _ in pairs(self.plugins) do
      self:refreshCommandsForPlugin(p)
   end
   return self
end

--- Seal:loadPluginFromFile(plugin_name, file)
--- Method
--- Loads a plugin from a given file
---
--- Parameters:
---  * plugin_name - the name of the plugin, without "seal_" at the beginning or ".lua" at the end
---  * file - the file where the plugin code is stored.
---
--- Returns:
---  * The Seal object if the plugin was successfully loaded, `nil` otherwise
---
--- Notes:
---  * You should normally use `Seal:loadPlugins()`. This method allows you to load plugins
---    from non-standard locations and is mostly a development interface.
---  * Some plugins may immediately begin doing background work (e.g. Spotlight searches)
function obj:loadPluginFromFile(plugin_name, file)
   local f,err = loadfile(file)
   if f~= nil then
      local plugin = f()
      plugin.seal = self
      self.plugins[plugin_name] = plugin
      self:refreshCommandsForPlugin(plugin_name)
      return self
   else
      return nil
   end
end

--- Seal:loadPlugins(plugins)
--- Method
--- Loads a list of Seal plugins
---
--- Parameters:
---  * plugins - A list containing the names of plugins to load
---
--- Returns:
---  * The Seal object
---
--- Notes:
---  * The plugins live inside the Seal.spoon directory
---  * The plugin names in the list, should not have `seal_` at the start, or `.lua` at the end
---  * Some plugins may immediately begin doing background work (e.g. Spotlight searches)
function obj:loadPlugins(plugins)
    self.chooser = hs.chooser.new(self.completionCallback)
    self.chooser:choices(self.choicesCallback)
    self.chooser:queryChangedCallback(self.queryChangedCallback)

    -- Load frecency data
    self:loadFrecencyData()

    for k,plugin_name in pairs(plugins) do
       local loaded=nil
       print("-- Loading Seal plugin: " .. plugin_name)
       for _,dir in ipairs(self.plugin_search_paths) do
          if obj.plugins[plugin_name] == nil then
             local file = dir .. "/seal_" .. plugin_name .. ".lua"
             loaded = (self:loadPluginFromFile(plugin_name, file) ~= nil)
          end
       end
       if (not loaded) then
          hs.showError(string.format("Error: could not find Seal plugin %s in any of the load paths %s", plugin_name, hs.inspect(self.plugin_search_paths)))
       end
    end
    return self
end

--- Seal:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for Seal
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the following (optional) items:
---   * show - This will cause Seal's UI to be shown
---   * toggle - This will cause Seal's UI to be shown or hidden depending on its current state
---
--- Returns:
---  * The Seal object
function obj:bindHotkeys(mapping)
    if (self.hotkeyShow) then
        self.hotkeyShow:delete()
    end
    if (self.hotkeyToggle) then
        self.hotkeyToggle:delete()
    end

    if mapping["show"] ~= nil then
        local showMods = mapping["show"][1]
        local showKey = mapping["show"][2]
        self.hotkeyShow = hs.hotkey.new(showMods, showKey, function() self:show() end)
    end
    if mapping["toggle"] ~= nil then
        local toggleMods = mapping["toggle"][1]
        local toggleKey = mapping["toggle"][2]
        self.hotkeyToggle = hs.hotkey.new(toggleMods, toggleKey, function() self:toggle() end)
    end

    return self
end

--- Seal:start()
--- Method
--- Starts Seal
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Seal object
function obj:start()
    print("-- Starting Seal")
    if self.hotkeyShow then
        self.hotkeyShow:enable()
    end
    if self.hotkeyToggle then
        self.hotkeyToggle:enable()
    end
    return self
end

--- Seal:stop()
--- Method
--- Stops Seal
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Seal object
---
--- Notes:
---  * Some Seal plugins will continue performing background work even after this call (e.g. Spotlight searches)
function obj:stop()
    print("-- Stopping Seal")
    self.chooser:hide()
    if self.hotkeyShow then
        self.hotkeyShow:disable()
    end
    if self.hotkeyToggle then
        self.hotkeyToggle:disable()
    end
    return self
end

--- Seal:show(query)
--- Method
--- Shows the Seal UI
---
--- Parameters:
---  * query - An optional string to pre-populate the query box with
---
--- Returns:
---  * None
---
--- Notes:
---  * This may be useful if you wish to show Seal in response to something other than its hotkey
function obj:show(query)
    self.chooser:show()
    if query then self.chooser:query(query) end
    return self
end

--- Seal:toggle(query)
--- Method
--- Shows or hides the Seal UI
---
--- Parameters:
---  * query - An optional string to pre-populate the query box with
---
--- Returns:
---  * None
function obj:toggle(query)
    if self.chooser:isVisible() then
        self.chooser:hide()
    else
        self:show(query)
    end
    return self
end

--- Seal:showPasteboard()
--- Method
--- Shows the Seal UI with clipboard history results directly (no command prefix)
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Seal object
---
--- Notes:
---  * This is useful for creating a dedicated hotkey to browse clipboard history
---  * The search box will be empty but will filter clipboard items as you type
function obj:showPasteboard()
    if not self.plugins.pasteboard then
        hs.alert.show("Pasteboard plugin not loaded")
        return self
    end

    -- Create a temporary chooser callback that filters pasteboard items
    local pasteboardChoicesCallback = function()
        local query = obj.chooser:query() or ""
        return obj.plugins.pasteboard.choicesPasteboardCommand(query)
    end

    -- Save original callbacks
    local originalCallback = self.choicesCallback
    local originalCompletionCallback = self.completionCallback

    -- Function to restore original behavior
    local function restoreCallbacks()
        obj.chooser:choices(originalCallback)
        obj.completionCallback = originalCompletionCallback
        if obj._pasteboardWatcher then
            obj._pasteboardWatcher:stop()
            obj._pasteboardWatcher = nil
        end
    end

    -- Temporarily replace the choices callback
    self.chooser:choices(pasteboardChoicesCallback)

    -- Show the chooser
    self.chooser:show()

    -- Set up a watcher to restore callbacks when chooser is dismissed
    obj._pasteboardWatcher = hs.timer.doEvery(0.1, function()
        if not obj.chooser:isVisible() then
            restoreCallbacks()
        end
    end)

    -- Also handle completion (when item is selected)
    self.completionCallback = function(rowInfo)
        restoreCallbacks()
        -- Handle the selection
        if rowInfo then
            originalCompletionCallback(rowInfo)
        end
    end

    return self
end

function obj.completionCallback(rowInfo)
    if rowInfo == nil then
        return
    end
    if rowInfo["type"] == "plugin_cmd" then
        obj.chooser:query(rowInfo["cmd"])
        return
    end

    -- Record selection for frecency tracking
    local query = obj.chooser:query()
    if rowInfo["uuid"] and query then
        obj:recordSelection(query, rowInfo["uuid"])
    end

    for k,plugin in pairs(obj.plugins) do
        if plugin.__name == rowInfo["plugin"] then
            plugin.completionCallback(rowInfo)
            break
        end
    end

    -- Clear the search query after selection so it doesn't persist next time
    obj.chooser:query("")
end

function obj.choicesCallback()
    -- TODO: Sort each of these clusters of choices, alphabetically
    choices = {}
    query = obj.chooser:query()
    cmd = nil
    query_words = {}
    if tostring(query):find("^%s*$") ~= nil then
        return choices
    end
    for word in string.gmatch(query, "%S+") do
        if cmd == nil then
            cmd = word
        else
            table.insert(query_words, word)
        end
    end
    query_words = table.concat(query_words, " ")
    -- First get any direct command matches
    for _,cmdInfo in pairs(obj.commands) do
        cmd_fn = cmdInfo["fn"]
        if cmd:lower() == cmdInfo["cmd"]:lower() then
            if (query_words or "") == "" then
                query_words = ".*"
            end
            fn_choices = cmd_fn(query_words)
            if fn_choices ~= nil then
                for j,choice in pairs(fn_choices) do
                    table.insert(choices, choice)
                end
            end
        end
    end
    -- Now get any bare matches
    for k,plugin in pairs(obj.plugins) do
        bare = plugin:bare()
        if bare then
            for i,choice in pairs(bare(query)) do
                table.insert(choices, choice)
            end
        end
    end
    -- Now add in any matching commands
    -- TODO: This only makes sense to do if we can select the choice without dismissing the chooser, which requires changes to HSChooser
    for command,cmdInfo in pairs(obj.commands) do
        if string.match(command, query) and #query_words == 0 then
            choice = {}
            choice["text"] = cmdInfo["name"]
            choice["subText"] = cmdInfo["description"]
            choice["type"] = "plugin_cmd"
            table.insert(choices,choice)
        end
    end

    -- Inject pinned apps that might not match the query naturally
    local query_lower = query:lower()
    for prefix, pinned_name in pairs(obj.pinnedPrefixes or {}) do
        local prefix_lower = prefix:lower()
        -- Check if query starts with this pinned prefix
        if query_lower:sub(1, #prefix_lower) == prefix_lower then
            -- Check if this pinned result is already in choices
            local already_present = false
            local pinned_lower = pinned_name:lower()
            for _, choice in ipairs(choices) do
                local choice_text = tostring(choice.text or ""):lower()
                if choice_text:find(pinned_lower, 1, true) then
                    already_present = true
                    break
                end
            end
            -- If not present, try to inject it from the apps cache
            if not already_present and obj.plugins.apps and obj.plugins.apps.appCache then
                for name, app in pairs(obj.plugins.apps.appCache) do
                    if name:lower():find(pinned_lower, 1, true) then
                        local choice = {}
                        local instances = {}
                        if app["bundleID"] then
                            instances = hs.application.applicationsForBundleID(app["bundleID"])
                        end
                        if #instances > 0 then
                            choice["text"] = name .. " (Running)"
                        else
                            choice["text"] = name
                        end
                        choice["subText"] = app["path"]
                        if app["icon"] then
                            choice["image"] = app["icon"]
                        end
                        choice["path"] = app["path"]
                        choice["uuid"] = "seal_apps__" .. (app["bundleID"] or name)
                        choice["plugin"] = "seal_apps"
                        choice["type"] = "launchOrFocus"
                        table.insert(choices, choice)
                        break
                    end
                end
            end
        end
    end

    -- Sort choices (priority > pinned/provider > prefix match > frecency > alphabetical)
    obj:sortChoices(choices, query)

    return choices
end

function obj.queryChangedCallback(query)
    if obj.queryChangedTimer then
        obj.queryChangedTimer:stop()
    end
    obj.queryChangedTimer = hs.timer.doAfter(obj.queryChangedTimerDuration,
                                             function() obj.chooser:refreshChoicesCallback() end)
end

return obj

--- === Seal.plugins ===
---
--- Various APIs for Seal plugins

-- This isn't really shown, but it's necessary to force Seal.plugins.html to render
--- Seal.plugins
--- Constant
--- This is a table containing all of the loaded plugins for Seal. You should interact with it only via documented API that the plugins expose.
