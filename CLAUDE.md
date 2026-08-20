# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is the official repository of Hammerspoon Spoons - a collection of plugins/extensions for Hammerspoon, a macOS automation tool. Each Spoon is a self-contained Lua module that provides specific functionality.

**Official Spoon repository:** http://www.hammerspoon.org/Spoons
**Main documentation:** https://github.com/Hammerspoon/hammerspoon/blob/master/SPOONS.md

## Repository Structure

```
Source/               # Source code for all Spoons
  <Name>.spoon/      # Individual Spoon directory
    init.lua         # Main Spoon implementation
    docs.json        # Auto-generated documentation metadata
    *.lua            # Additional plugin files (for complex Spoons)
    *.png            # Assets (icons, images)

Spoons/              # Built/packaged Spoons (zip files)
  <Name>.spoon.zip   # Distributed binary package

docs/                # Published HTML documentation (auto-generated)
```

## Development Workflow

### Building Spoons

**Build all Spoons:**
```bash
make
```

**Build specific Spoon:**
```bash
make Spoons/<SpoonName>.spoon.zip
```

**Clean built packages:**
```bash
make clean
```

### Documentation

**Generate documentation for all Spoons:**
```bash
./build_docs.sh
```
Requires the Hammerspoon repository to be in `../hammerspoon` or `./hammerspoon`.

**Lint documentation for a specific Spoon:**
```bash
python3 ../hammerspoon/scripts/docs/bin/build_docs.py -l -o /tmp/ -n Source/<SpoonName>.spoon
```

**Generate docs.json for a specific Spoon:**
```bash
python3 ../hammerspoon/scripts/docs/bin/build_docs.py -e ../hammerspoon/scripts/docs/templates/ -o Source/<SpoonName>.spoon/ -j -n Source/<SpoonName>.spoon/
```

### Merging New Spoons

Use `merge_spoon.sh` to merge a PR and generate all documentation:
```bash
./merge_spoon.sh <PR_NUMBER> <SpoonName>
# Or skip fetching PR: ./merge_spoon.sh 0 <SpoonName>
```

## Spoon Architecture

### Basic Spoon Structure

Every Spoon follows this pattern:

```lua
--- === SpoonName ===
---
--- Brief description
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/SpoonName.spoon.zip](...)

local obj = {}
obj.__index = obj

-- Metadata (required)
obj.name = "SpoonName"
obj.version = "1.0"
obj.author = "Author Name <email>"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

-- Variables, methods, etc.

return obj
```

### Documentation Format

Use Lua doc comments (triple dash `---`) following Hammerspoon's conventions:

```lua
--- SpoonName.variableName
--- Variable
--- Description of the variable
---
--- Notes:
---  * Additional notes if needed
obj.variableName = defaultValue

--- SpoonName:methodName(param1, param2)
--- Method
--- Description of what the method does
---
--- Parameters:
---  * param1 - description
---  * param2 - description
---
--- Returns:
---  * Description of return value
---
--- Notes:
---  * Additional notes
function obj:methodName(param1, param2)
  -- implementation
end
```

### Plugin-Based Spoons

Some Spoons support plugins (e.g., Seal). Plugin files follow naming convention:
- Main spoon: `init.lua`
- Plugins: `<spoonname>_<pluginname>.lua` (e.g., `seal_apps.lua`, `seal_calc.lua`)

### Configuration Pattern

Many Spoons use a metatable pattern for reactive configuration:

```lua
local _store = {}
setmetatable(obj,
  { __index = function(_, k) return _store[k] end,
    __newindex = function(t, k, v)
      rawset(_store, k, v)
      if t._init_done and t._attribs[k] then
        t:init()  -- Reinitialize when config changes
      end
    end
  })
```

## CI/CD Pipeline

GitHub Actions automatically:
1. Lints documentation on PRs and pushes to master
2. Rebuilds docs.json for modified Spoons
3. Regenerates zip packages
4. Updates HTML documentation
5. Auto-commits changes

**PR workflow** (`.github/workflows/PR.yml`):
- Checks out both Spoons and Hammerspoon repos
- Detects modified .lua files
- Runs `gh_actions_doclint.sh` for validation
- Runs `gh_actions_publish.sh` to rebuild docs and zips
- Auto-commits if push to master

## Development and Publishing Workflow

### How SpoonInstall Works

The Hammerspoon config (`~/.config/hammerspoon/init.lua`) uses SpoonInstall to auto-update Spoons:
```lua
hs.loadSpoon("SpoonInstall")
Install = spoon.SpoonInstall
Install.repos.default = {
    url = "https://github.com/jacobbrugh/Spoons",
    desc = "My Hammerspoon Spoon repository",
    branch = "master",
}
Install.use_syncinstall = true
Install:updateAllRepos()
Install:installSpoonFromRepo("Seal")
```

**Critical:** SpoonInstall downloads from `Spoons/*.spoon.zip` files, NOT from `Source/`. The CI pipeline rebuilds these zips when you push to master.

### Testing and Publishing Changes

**Complete workflow:**

1. **Edit source files** in `Source/<SpoonName>.spoon/`
   ```bash
   # Example: editing Seal pasteboard plugin
   vim Source/Seal.spoon/seal_pasteboard.lua
   ```

2. **Commit changes** (one logical commit per change)
   ```bash
   git add Source/Seal.spoon/seal_pasteboard.lua
   git commit -m "Seal pasteboard: Add preview for large entries"
   ```

3. **Push to GitHub** and wait for CI
   ```bash
   git push
   # Watch CI at: https://github.com/jacobbrugh/Spoons/actions
   ```

4. **If CI fails**, fix the issue, amend, and force push:
   ```bash
   # Make fixes...
   git add -A
   git commit --amend --no-edit
   git push --force-with-lease
   ```

5. **Once CI passes**, restart Hammerspoon
   - Quit Hammerspoon completely (menu bar → Quit)
   - Reopen Hammerspoon
   - SpoonInstall will download the updated zip

### Git Commit Style

**One commit per conceptual change.** When iterating on a fix:
- Use `git commit --amend --no-edit` to update the existing commit
- Use `git push --force-with-lease` to update the remote
- This keeps history clean and makes CI easier to follow

**Example iteration:**
```bash
# Initial commit
git add -A && git commit -m "Seal: Add clipboard preview feature"
git push

# CI fails due to doc lint...
# Fix the issue
git add -A && git commit --amend --no-edit
git push --force-with-lease

# CI passes, done!
```

### Common CI Failures

**"Unable to find module for: X"** - Doc linter error
- Cause: Using `---` (triple dash) comments on non-API functions
- Fix: Use `--` (double dash) for internal/local function comments
- `---` comments are parsed as Hammerspoon API documentation

**Example fix:**
```lua
-- WRONG: triggers doc linter
--- Creates a preview of text
local function createPreview(text)

-- CORRECT: internal function, use double dash
-- Creates a preview of text
local function createPreview(text)
```

### Quick Reference

| Step | Command |
|------|---------|
| Edit source | `vim Source/Seal.spoon/seal_pasteboard.lua` |
| Stage changes | `git add Source/Seal.spoon/` |
| Commit | `git commit -m "Description"` |
| Push | `git push` |
| Fix + amend | `git add -A && git commit --amend --no-edit` |
| Force push | `git push --force-with-lease` |
| Check CI | https://github.com/jacobbrugh/Spoons/actions |
| Apply changes | Quit and restart Hammerspoon |

## Common Spoon Patterns

### Initialization
```lua
function obj:init()
  -- Setup code
  self._init_done = true
  return self
end
```

### Start/Stop
```lua
function obj:start()
  -- Enable functionality
  return self
end

function obj:stop()
  -- Disable functionality
  return self
end
```

### Hotkey Binding
```lua
function obj:bindHotkeys(mapping)
  local spec = {
    show = hs.fnutils.partial(self.show, self),
    hide = hs.fnutils.partial(self.hide, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  return self
end
```

### Chooser API Patterns

When working with `hs.chooser`, special care is needed for temporarily swapping callbacks:

```lua
-- Save original callbacks
local original_callback = self.chooser:choices()
local original_completion = self.completionCallback

-- Set temporary callbacks
self.chooser:choices(temporary_callback)
self.completionCallback = temporary_completion_callback

-- Use background watcher to detect when chooser dismissed
self._restore_watcher = hs.timer.doEvery(0.1, function()
  if not self.chooser:isVisible() then
    -- Restore original callbacks
    self.chooser:choices(original_callback)
    self.completionCallback = original_completion

    -- Stop watcher
    if self._restore_watcher then
      self._restore_watcher:stop()
      self._restore_watcher = nil
    end
  end
end)
```

**Why this pattern:**
- Choosers don't have a built-in "dismissed" callback
- Must poll visibility to detect when user closes chooser (Escape key)
- Always restore original state to avoid breaking normal operation
- Example usage: Seal's `showPasteboard()` method

### AppleScript Patterns for Browser Automation

When opening URLs in Chrome or Safari via AppleScript, different logic is needed based on window state:

```lua
local function escapeForAppleScript(str)
  str = str:gsub("\\", "\\\\")  -- Escape backslashes first
  str = str:gsub('"', '\\"')    -- Escape quotes
  return str
end

local escaped_url = escapeForAppleScript(url)
local script = string.format([[
  tell application "Google Chrome"
    if (count of windows) = 0 then
      make new window
      set URL of active tab of front window to "%s"
    else
      tell front window
        make new tab with properties {URL:"%s"}
      end tell
    end if
    activate
  end tell
]], escaped_url, escaped_url)

hs.osascript.applescript(script)
```

**Important:**
- Different logic for 0 windows vs existing windows
- Use backslash escaping for quotes/backslashes (NOT percent-encoding or `%q`)
- Always activate the application after opening URL
- Reference: `seal_chrome_bookmarks.lua` for complete pattern

## Seal Plugin Development

Seal is a complex Spoon with a plugin architecture. Seal plugins have unique initialization and scoring patterns that differ from regular Spoons.

### Plugin Initialization

**CRITICAL:** Seal does NOT automatically call `start()` on plugins. Plugins must initialize themselves at module load time.

**Pattern from seal_chrome_bookmarks.lua:**
```lua
local obj = {}
obj.__name = "seal_chrome_bookmarks"

-- ... plugin implementation ...

-- Initialize on load (Seal doesn't call start() on plugins)
obj:_reindex()  -- Build initial data
obj:_watch()    -- Set up file watchers (if applicable)

return obj
```

**Why this matters:**
- Unlike main Spoons, plugins are loaded via `require()` and never explicitly started
- All initialization (indexing, watchers, etc.) must happen during module load
- Do NOT wait for `start()` to be called - it won't be
- Place initialization calls BEFORE the final `return obj`

### Bare Functions (Default Search)

Plugins can implement a `bare()` function to show results in default search (without keyword prefix):

```lua
function obj:bare()
  -- Return choices to show when user opens Seal without typing a keyword
  return self._choices  -- or dynamically generated choices
end
```

**Example:** The chrome_bookmarks plugin implements `bare()` so bookmarks appear immediately when opening Seal.

### Frecency Integration

Seal tracks item usage frequency and recency. Plugins should apply frecency boosts BEFORE sorting/limiting results.

**Pattern:**
```lua
-- After generating choices, apply frecency boosts
if self.seal and self.seal.frecency_enable and self.seal.frecency_data then
  for _, choice in ipairs(choices) do
    local frecency_data = self.seal.frecency_data[choice.uuid]
    if frecency_data and frecency_data.last_used then
      -- Use high boost values (e.g., 10000) for recently used items
      local recency_boost = frecency_data.last_used > 0 and 10000 or 0
      choice._score = (choice._score or 0) + recency_boost
    end
  end
end

-- THEN sort and limit results
table.sort(choices, function(a, b) return (a._score or 0) > (b._score or 0) end)
```

**Important:**
- Boost values should be high (e.g., 10000) to meaningfully affect ranking
- Apply boosts BEFORE sorting or limiting results
- Use the choice's `uuid` field to look up frecency data
- Access frecency via `self.seal.frecency_data[uuid]`

### Priority and Scoring System

Seal uses a threshold-based sorting system (see `sortChoicesByFrecency()` in init.lua):

**Priority Tiers:**
- `HIGH_PRIORITY_THRESHOLD = 50000`
- Scores >= 50000: High priority tier (sorted by frecency within tier)
- Scores < 50000: Normal priority tier (sorted by frecency within tier)

**Setting Plugin Priority:**
```lua
-- For high-priority results (e.g., calculator results for math expressions)
choice._score = 100000  -- Ensures result appears first

-- For medium-priority results
choice._score = 75000   -- Above threshold but below critical results

-- For normal results with frecency boost
choice._score = 10000   -- Boosted by recency

-- For base results
choice._score = 0       -- Relies on frecency for ordering
```

**Example from seal_calc.lua:**
```lua
choice["_score"] = 100000  -- Very high score to prioritize calc over other plugins
```

The calculator plugin sets `_score = 100000` to ensure math results always appear at the top when user types an equation like "5 + 7".

### Plugin Architecture Summary

**Key files:**
- `init.lua` - Main Seal spoon
- `seal_*.lua` - Individual plugins (apps, bookmarks, calc, pasteboard, etc.)

**Plugin lifecycle:**
1. Seal's `loadPlugins()` calls `require()` on each plugin file
2. Plugin module code executes (calls `_reindex()`, `_watch()`, etc. at end of file)
3. Plugin `obj` is stored in Seal's plugins table
4. When user searches, Seal calls plugin's `commands()` or `bare()` method
5. Plugins return choices, Seal applies frecency and sorts by priority

**No explicit start/stop for plugins** - they are active once loaded.

## Common Pitfalls and Best Practices

### Lua and Hammerspoon Gotchas

**Method vs. Function Calls:**
```lua
-- WRONG: Using dot notation for method calls
self.logger.i("message")  -- Error: missing 'self' parameter

-- CORRECT: Using colon notation for method calls
self.logger:i("message")  -- Automatically passes 'self'
```

In Lua, the colon (`:`) automatically passes `self` as the first parameter. Using dot (`.`) requires manually passing `self`.

**String Comparison:**
Always normalize strings when comparing (especially for keyword matching):
```lua
-- WRONG: Case-sensitive comparison
if query == keyword then

-- CORRECT: Case-insensitive comparison
if query:lower() == keyword:lower() then
```

Seal users may type keywords in any case ("CB", "cb", "Cb") - always normalize both sides.

**File Operations:**
Use `pcall()` for operations that might fail:
```lua
-- WRONG: Unprotected file operation
for file in hs.fs.dir(path) do
  -- process file
end

-- CORRECT: Protected with error handling
local success, iter = pcall(hs.fs.dir, path)
if success and iter then
  for file in iter do
    -- process file
  end
else
  self.logger:e("Failed to read directory: " .. path)
end
```

Chrome profile directories, bookmark files, etc. may not exist on all systems.

**Logging:**
Always provide context in log messages:
```lua
-- WRONG: Vague logging
self.logger:i("Reindexing")

-- CORRECT: Detailed logging with context
self.logger:i(string.format("Reindexing %d bookmarks from %s", count, bookmarks_file))
```

### Documentation and EmmyLua Integration

**EmmyLua triggers on docs.json modification time, NOT version number.**

When adding new methods to a Spoon:

1. **Update the Lua code** with proper doc comments (triple-dash `---`)
2. **Regenerate `docs.json`** to update modification timestamp:
   ```bash
   python3 ../hammerspoon/scripts/docs/bin/build_docs.py \
     -e ../hammerspoon/scripts/docs/templates/ \
     -o Source/<SpoonName>.spoon/ \
     -j \
     -n Source/<SpoonName>.spoon/
   ```
3. **Bump the version number** in `init.lua` (e.g., "1.0" → "1.1")
4. **Copy updated Spoon** to Hammerspoon config:
   ```bash
   rsync -av --delete Source/<SpoonName>.spoon/ ~/.config/hammerspoon/Spoons/<SpoonName>.spoon/
   ```
5. **Reload Hammerspoon** to trigger EmmyLua annotation refresh

**Why this matters:**
- EmmyLua caches annotations based on `docs.json` file modification time
- Just changing the version number won't trigger refresh
- Must actually regenerate `docs.json` to update the timestamp
- Without this, IDEs will show "undefined field" warnings for new methods

### Testing Changes

**Local testing workflow for Spoons:**
1. Make changes to Spoon source in `Source/<SpoonName>.spoon/`
2. Regenerate docs.json (see above)
3. Copy to Hammerspoon config directory
4. Reload Hammerspoon: Console → Reload Config (or Cmd+Shift+R)
5. Test functionality
6. Check Hammerspoon console for errors/logs

**For Seal plugins specifically:**
- After reloading, open Seal (default: Cmd+Space) and try searches
- Test bare() function by opening Seal without typing
- Test keyword-based search (e.g., "cb test" for chrome_bookmarks)
- Verify frecency boost behavior: use an item, close Seal, reopen and check if item appears first
- Use `hs -c "hs.inspect(spoon.Seal.plugins.chrome_bookmarks)"` in terminal to inspect plugin state
- Check logs: `tail -f ~/.hammerspoon/hammerspoon.log` or Console app

**Common test commands:**
```bash
# Test Seal plugin loading
hs -c "hs.inspect(spoon.Seal.plugins)"

# Reload Hammerspoon from terminal
hs -c "hs.reload()"

# Check if Chrome bookmarks file exists
ls -la ~/Library/Application\ Support/Google/Chrome/Profile\ 1/Bookmarks
```

## Important Notes

### General Spoon Development
- Each Spoon must be self-contained in its `.spoon` directory
- The `docs.json` file is auto-generated - never edit manually
- Always run documentation linting before submitting PRs
- Spoon names use CamelCase (e.g., `MouseFollowsFocus`)
- Documentation follows strict format for automated processing
- Lua version: Uses Hammerspoon's embedded Lua runtime

### Lua Syntax
- Method calls use colon (`:`) not dot (`.`) - e.g., `self.logger:i()` not `self.logger.i()`
- Always normalize strings (`:lower()`) when comparing user input to keywords
- Use `pcall()` for file operations that might fail (e.g., `hs.fs.dir()`)

### Seal Plugin Development
- Seal plugins must initialize during module load (call `_reindex()`, `_watch()` before `return obj`)
- Seal does NOT call `start()` on plugins - initialization must happen at module load time
- Apply frecency boosts BEFORE sorting/limiting results in plugins
- Seal's priority threshold is 50000 - scores >= 50000 are high priority
- Use `_score = 100000` for critical results (like calc) that should always appear first
- Implement `bare()` function to show results in default search without keyword

### Documentation and EmmyLua
- EmmyLua refreshes annotations based on `docs.json` modification time, NOT version number
- After adding new methods, must regenerate `docs.json` to update modification timestamp
- Bump version number when making significant changes (good practice)
- Copy updated spoon to `~/.config/hammerspoon/Spoons/` and reload to trigger EmmyLua refresh

### User Configuration Notes
- I set `MJConfigFile` to ~/.config/hammerspoon/init.lua and my recency file to hs.configDir .. <filename> so that Seal frecency file is stored under ~/.config/hammerspoon/ for my setup