-- What the `kebab` shell command runs once Neovim is up.
--
-- The shell script in bin/kebab is deliberately thin: it parses arguments and
-- hands them here, so the behaviour is Lua that the test suite can call
-- directly instead of shell that it would have to spawn and scrape.
local M = {}

local project = require("kebab.project")

-- ------------------------------------------------------------------ resolve

---Projects whose name matches `query`.
---
---Exact (case-insensitive) matches win outright; otherwise anything containing
---the query is offered. Returning a list rather than a single project is what
---lets `kebab open foo` fall back to a picker when "foo" is ambiguous instead
---of silently opening the wrong one.
---@param query string
---@return table[] matches
function M.resolve(query)
  local all = project.discover()
  local needle = query:lower()

  local exact = {}
  for _, p in ipairs(all) do
    if p.name:lower() == needle then
      exact[#exact + 1] = p
    end
  end
  if #exact > 0 then
    return exact
  end

  local partial = {}
  for _, p in ipairs(all) do
    if p.name:lower():find(needle, 1, true) then
      partial[#partial + 1] = p
    end
  end
  return partial
end

---Open a project by name, path, or interactively when given nothing.
---@param query string|nil
function M.open(query)
  if query == nil or query == "" then
    return project.open_project()
  end

  -- A path the user can see wins over a name lookup: `kebab open ./thing`
  -- should never open some unrelated project called "thing".
  local expanded = require("kebab.path").expand(query)
  local stat = vim.uv.fs_stat(expanded)
  if stat then
    if stat.type == "directory" then
      return project.open_dir(expanded)
    end
    -- A file: open its project *root*, then the file itself. Its own
    -- directory is not the root -- `kebab src/main/java/com/foo/App.java`
    -- rooted the tree at com/foo, scoped <leader>ff to one package and hid the
    -- ./mvnw the run configurations look for.
    local dir = vim.fn.fnamemodify(expanded, ":h")
    local _, marker = require("kebab.registry").find_project(dir)
    project.open_dir(marker and vim.fn.fnamemodify(marker, ":h") or dir)
    return vim.cmd("edit " .. vim.fn.fnameescape(expanded))
  end

  local matches = M.resolve(query)
  if #matches == 1 then
    return project.open_dir(matches[1].path)
  end
  if #matches == 0 then
    vim.notify(("No project matching %q under %s"):format(query, table.concat(project.roots(), ", ")),
      vim.log.levels.WARN)
    return project.open_project()
  end
  vim.ui.select(matches, {
    prompt = ("%d projects match %q"):format(#matches, query),
    format_item = function(p)
      return string.format("%-28s  %-8s  %s", p.name, p.kind, p.root)
    end,
  }, function(choice)
    if choice then
      project.open_dir(choice.path)
    end
  end)
end

-- --------------------------------------------------------------------- new

---Create a project from fully-specified arguments, or fall back to the wizard
---when the type is missing.
---@param spec table { type?, name?, dest?, answers? }
function M.new(spec)
  spec = spec or {}
  if not spec.type or not spec.name or spec.name == "" then
    -- Not enough to go on; let the wizard ask. This is the common case for
    -- someone who just typed `kebab new`.
    return project.new_project()
  end
  project.create(spec, function(ok, err)
    if not ok then
      vim.notify("kebab new: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

---Create a project, report the outcome on stdout and quit with a meaningful
---exit code. This is what `kebab new --no-open` runs: creation without an
---editor, for scripts, CI and anyone who just wants the directory to exist.
---@param spec table
function M.create_and_quit(spec)
  local finished, succeeded, failure = false, false, nil
  project.create(vim.tbl_extend("force", spec, { open = false }), function(ok, err, dest)
    finished, succeeded, failure = true, ok, err
    if ok then
      io.write("created " .. tostring(dest) .. "\n")
    else
      io.write("failed: " .. tostring(err) .. "\n")
    end
  end)
  -- Scaffolds shell out: `mvn archetype:generate` and `npm install` are slow.
  if not vim.wait(15 * 60 * 1000, function() return finished end, 100) then
    io.write("failed: timed out waiting for the scaffold\n")
    return vim.cmd("cq 1")
  end
  vim.cmd(succeeded and "qa!" or "cq 1")
end

-- ---------------------------------------------------------------- database
--
-- `kebab db` is to the SQL IDE what `kebab` is to the editor: one word that
-- lands you in it. Without it the answer to "how do I start the database
-- explorer" was "start Neovim, then press a key", which is not how you start
-- a dedicated database IDE.

---Is this window's buffer one `kebab db` may take over?
---
---The dashboard is the case that mattered. With no files open, `:only` keeps
---the window holding it, and the statement pane refuses to reuse a special
---buffer -- so the splash screen survived into the database layout, and
---anything typed while focused there hit the *dashboard's* keymaps. Reported
---as three separate faults: "lazyvim splash always there", "shortcuts are not
---working at all", and `Space S` opening something else.
---@param win integer
---@return boolean
local function disposable(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].modified then
    return false -- never discard work
  end
  if vim.bo[buf].buftype ~= "" then
    return true -- a dashboard, a starter screen, any scratch
  end
  return vim.api.nvim_buf_get_name(buf) == ""
end

---Shut the file tree, and stop the always-on explorer from reopening it.
---
---`kebab db` is a database session: the left column belongs to the data source
---tree. Without this both are open and the statement and rows panes end up 20
---columns wide.
function M.close_file_explorer()
  vim.g.ide_explorer_opened = true
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(w)
    if vim.bo[buf].filetype == "neo-tree" and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

---Saved connections whose name matches `query`, exact match winning outright.
---Same shape as M.resolve for projects, and for the same reason: an ambiguous
---name should offer a choice, not pick one.
---@param query string
---@return table[] matches
function M.resolve_connection(query)
  local list = require("kebab.db").connections()
  local needle = query:lower()
  local exact, partial = {}, {}
  for _, c in ipairs(list) do
    if c.name:lower() == needle then
      exact[#exact + 1] = c
    elseif c.name:lower():find(needle, 1, true) then
      partial[#partial + 1] = c
    end
  end
  return #exact > 0 and exact or partial
end

---Open the SQL IDE: the explorer, or a console on one connection.
---
---Runs in an interactive session, so it reports by notifying rather than
---returning -- the caller is a person looking at the editor.
---@param name? string a saved connection; nil opens the explorer
function M.db(name)
  local db = require("kebab.db")
  local list, err = db.connections()
  if err then
    return vim.notify(err, vim.log.levels.ERROR)
  end
  if #list == 0 then
    return vim.notify(("No database connections yet — press %s, or run :IdeDbAdd, to add one")
      :format(require("kebab.keys").human("<leader>Da")), vim.log.levels.WARN)
  end

  -- Establishing the mode is scheduled, and the cleanup runs twice.
  --
  -- `kebab db` is a mode: it owns the screen while it is up. Doing that
  -- synchronously did not work, because at that point the editor is still
  -- starting -- the always-on explorer opens itself from a scheduled callback,
  -- so it reappeared *after* being closed, and `:only` kept the single window
  -- that existed before the others were created. Measured in a real terminal
  -- with two files open: five windows, the explorer back, and a leftover code
  -- window five columns wide.
  --
  -- <leader>DD and the menu entry do not do any of this: inside a working
  -- session you want the data source tree beside your work, not instead of it.
  local function establish(after)
    M.close_file_explorer()
    pcall(vim.cmd, "only")
    -- An empty buffer rather than the splash screen: a window holding a
    -- dashboard is not one the statement pane can take over, so it would
    -- otherwise sit in the layout keeping its own keymaps.
    local win = vim.api.nvim_get_current_win()
    if disposable(win) then
      pcall(vim.cmd, "enew")
    end
    after()
    -- and again, for anything that was already queued when we started
    vim.schedule(function()
      M.close_file_explorer()
      pcall(function()
        require("kebab.dbide").pin_tree()
      end)
    end)
  end

  if name == nil or name == "" then
    vim.schedule(function()
      establish(function()
        -- The explorer belongs to a lazy spec, so it has to be loaded before
        -- its command is called -- see the `cmd` triggers in plugins/sql.lua.
        pcall(function()
          require("lazy").load({ plugins = { "vim-dadbod-ui" } })
        end)
        db.publish()
        local ok, cerr = pcall(vim.cmd, "DBUI")
        if not ok then
          vim.notify("Could not open the database explorer: " .. tostring(cerr), vim.log.levels.ERROR)
        end
      end)
    end)
    return
  end

  local function open_console(c)
    vim.schedule(function()
      establish(function()
        pcall(function()
          require("lazy").load({ plugins = { "vim-dadbod-ui" } })
        end)
        db.publish()
        pcall(vim.cmd, "DBUI")
        require("kebab.dbide").layout(c)
      end)
    end)
  end

  local matches = M.resolve_connection(name)
  if #matches == 0 then
    local names = vim.tbl_map(function(c) return c.name end, list)
    return vim.notify(("No connection called %q. There is: %s"):format(name, table.concat(names, ", ")),
      vim.log.levels.ERROR)
  end
  if #matches == 1 then
    return open_console(matches[1])
  end
  vim.ui.select(matches, {
    prompt = ("%d connections match %q"):format(#matches, name),
    format_item = function(c) return ("%-22s %s"):format(c.name, c.url) end,
  }, function(choice)
    if choice then
      open_console(choice)
    end
  end)
end

-- -------------------------------------------------------------- reporting

---Lines listing every discovered project. Plain text, for a terminal.
function M.list_lines()
  local all, problems = project.discover()
  local lines = {}
  if #all == 0 then
    lines[#lines + 1] = "No projects found under " .. table.concat(project.roots(), ", ")
  end
  for _, p in ipairs(all) do
    lines[#lines + 1] = string.format("%-28s  %-8s  %s", p.rel or p.name, p.kind, p.path)
  end
  -- A root that could not be read is said out loud rather than looking like a
  -- root with nothing in it.
  for _, line in ipairs(project.problem_lines(problems)) do
    lines[#lines + 1] = "skipped " .. line
  end
  return lines
end

---Lines describing the available project types.
---@param opts? { prompts?: boolean } also list what each type asks
function M.type_lines(opts)
  opts = opts or {}
  local lines = {}
  for _, t in ipairs(project.project_types()) do
    local notes = {}
    if t.network then
      notes[#notes + 1] = "needs network"
    end
    local missing = project.missing_requirements(t)
    if #missing > 0 then
      notes[#notes + 1] = "MISSING: " .. table.concat(missing, ", ")
    end
    lines[#lines + 1] = string.format("%-10s %-42s %s", t.key, t.label,
      #notes > 0 and ("(" .. table.concat(notes, "; ") .. ")") or "")

    -- What `kebab new --<answer> <value>` accepts for this type. Generated
    -- from the type's own prompts, so a language that adds a question
    -- documents itself.
    if opts.prompts then
      for _, p in ipairs(t.prompts or {}) do
        local detail
        if p.kind == "select" then
          detail = "one of: " .. table.concat(p.choices or {}, ", ")
        else
          detail = "default: " .. tostring(p.default == nil and "(none)" or p.default)
        end
        lines[#lines + 1] = string.format("           --%-14s %s", p.name, detail)
      end
    end
  end
  return lines
end

-- ------------------------------------------------------------------ doctor
--
-- Grouped by who owns the version, which is the same split the whole layer is
-- built on:
--
--   Required            the layer does not work without these
--   Language toolchains the *project* dictates the version, so they are
--                       detected and reported, never installed silently
--   Optional            something degrades without them, nothing breaks
--
-- The language group is derived from the registry rather than listed here, so a
-- language added later reports its own requirements.

---Tools the layer itself needs.
local REQUIRED = {
  {
    exe = "git",
    why = "lazy.nvim clones plugins; every scaffold runs git init",
  },
  {
    exe = "curl",
    why = "Mason downloads tooling; JDBC drivers come from Maven Central",
  },
}

---Tools whose absence costs a feature but breaks nothing else.
local OPTIONAL = {
  {
    exe = "javac",
    why = "compiles the JDBC bridge",
    without = "no database support at all (:IdeDb*)",
  },
  {
    exe = "unzip",
    why = "unpacks the Spring Boot scaffold's download",
    without = "the spring project type fails; the others are fine",
  },
  {
    exe = "jq",
    why = "pretty-prints .kebab/run.json and connections.json",
    without = "they are still written and read, on a single line",
  },
  {
    exe = "inotifywait",
    why = "vim._watch shells out to it, so :IdeFollow needs it",
    without = ":IdeFollow cannot start (package: inotify-tools)",
  },
  {
    exe = "lazygit",
    -- doctor prints this; `<leader>gg` is not something a person presses
    why = "the git UI behind Space → g → g",
    without = "that one keybinding; diffview and gitsigns are unaffected",
  },
}

---Mason installs 31 of its 55 packages *through* a language toolchain, so a
---missing toolchain costs language servers as well as scaffolds. This is the
---mapping from Mason's package ecosystem to the executable it needs.
local MASON_ECOSYSTEM = {
  npm = "npm",
  golang = "go",
  gem = "gem",
  pypi = "python3",
}

---Which version manager to suggest. A language toolchain is best installed with
---one; a system tool is not.
function M.package_manager()
  for _, name in ipairs({ "mise", "asdf" }) do
    if vim.fn.executable(name) == 1 then
      return name
    end
  end
  return nil
end

function M.system_package_manager()
  for _, name in ipairs({ "pacman", "apt", "dnf", "zypper", "brew" }) do
    if vim.fn.executable(name) == 1 then
      return name
    end
  end
  return nil
end

-- exe -> the name each manager knows it by
local MISE_NAMES = {
  go = "go", node = "node", npm = "node", python3 = "python", cargo = "rust",
  rustc = "rust", ruby = "ruby", gem = "ruby", java = "java", javac = "java",
  flutter = "flutter", mvn = "maven", dart = "dart", gradle = "gradle",
  uv = "uv",
}

-- Not a toolchain of its own: bundler ships as a gem, so the suggestion has to
-- be the gem install rather than a version-manager plugin.
local GEM_TOOLS = { bundle = "bundler" }
local SYSTEM_NAMES = {
  pacman = {
    git = "git", curl = "curl", unzip = "unzip", jq = "jq", sqlite3 = "sqlite",
    inotifywait = "inotify-tools", lazygit = "lazygit", javac = "jdk-openjdk",
    java = "jdk-openjdk", mvn = "maven", go = "go", ruby = "ruby", npm = "nodejs npm",
  },
  apt = {
    git = "git", curl = "curl", unzip = "unzip", jq = "jq", sqlite3 = "sqlite3",
    inotifywait = "inotify-tools", javac = "default-jdk", java = "default-jre",
    mvn = "maven", go = "golang", ruby = "ruby", npm = "nodejs npm",
  },
  brew = {
    git = "git", curl = "curl", unzip = "unzip", jq = "jq", sqlite3 = "sqlite",
    inotifywait = "fswatch", lazygit = "lazygit", javac = "openjdk",
    java = "openjdk", mvn = "maven", go = "go", ruby = "ruby", npm = "node",
  },
}

---How to install `exe` on this machine, or nil when there is nothing to suggest.
---@param exe string
---@return string|nil
function M.install_hint(exe)
  if GEM_TOOLS[exe] then
    -- `gem install --user-install` puts the executable in Gem.user_dir/bin,
    -- which is not on PATH on a default Arch install -- gem itself warns about
    -- it. Saying so here saves the "installed it and it still is not found"
    -- round trip.
    local user_bin
    local ok, dir = pcall(function()
      return vim.fn.systemlist({ "ruby", "-e", "require 'rubygems'; print Gem.user_dir" })[1]
    end)
    if ok and type(dir) == "string" and dir ~= "" then
      user_bin = dir .. "/bin"
    end
    if user_bin and not (vim.env.PATH or ""):find(user_bin, 1, true) then
      return ("gem install --user-install %s   (then add %s to PATH)")
        :format(GEM_TOOLS[exe], user_bin)
    end
    return ("gem install %s"):format(GEM_TOOLS[exe])
  end
  local manager = M.package_manager()
  local mise_name = MISE_NAMES[exe]
  if manager == "mise" and mise_name then
    return ("mise use --global %s@latest"):format(mise_name)
  end
  if manager == "asdf" and mise_name then
    return ("asdf plugin add %s && asdf install %s latest"):format(mise_name, mise_name)
  end

  local system = M.system_package_manager()
  local names = system and SYSTEM_NAMES[system]
  local package = names and names[exe]
  if system and package then
    if system == "pacman" then
      return ("sudo pacman -S %s"):format(package)
    elseif system == "apt" then
      return ("sudo apt install %s"):format(package)
    elseif system == "dnf" or system == "zypper" then
      return ("sudo %s install %s"):format(system, package)
    elseif system == "brew" then
      return ("brew install %s"):format(package)
    end
  end
  if mise_name and manager == nil then
    return ("install %s (a version manager such as mise is the easiest way)"):format(mise_name)
  end
  return nil
end

---What each language toolchain unlocks, worked out from the registry.
---@return table<string, string[]>
function M.toolchain_uses()
  local uses = {}
  local function note(exe, text)
    uses[exe] = uses[exe] or {}
    if not vim.tbl_contains(uses[exe], text) then
      table.insert(uses[exe], text)
    end
  end

  for _, t in ipairs(project.project_types()) do
    for _, exe in ipairs(t.requires or {}) do
      note(exe, t.key .. " scaffold")
    end
  end

  -- Dependency commands: the first word of what each ecosystem runs.
  local registry = require("kebab.registry")
  for _, marker in ipairs(registry.markers()) do
    local deps = marker.deps
    if deps and deps.command then
      local ok, cmd = pcall(deps.command, "example")
      if ok and type(cmd) == "table" and cmd[1] then
        note(cmd[1], ("adding %s dependencies"):format(marker.kind))
      end
    end
  end

  -- Tasks: whatever each one actually runs.
  for _, task in ipairs(registry.tasks()) do
    local cmd = task.cmd
    if type(cmd) == "function" then
      local ok, resolved = pcall(cmd)
      cmd = ok and resolved or nil
    end
    if type(cmd) == "table" and type(cmd[1]) == "string" then
      local exe = cmd[1]
      -- A project-local wrapper is not a toolchain. `./mvnw` resolves because
      -- it exists in this directory, and plugins/run.lua re-resolves it at run
      -- time -- so reporting "mvnw not installed" (with no install hint, and
      -- only when the doctor happens to be run from a project that has one)
      -- told the user something was broken that works.
      if not exe:match("^%./") and exe ~= "" then
        note(exe, "run configurations")
      end
    end
  end

  -- Mason's own packages, which is the part people do not expect.
  local ok, reg = pcall(require, "mason-registry")
  if ok and reg and reg.get_package then
    local counts = {}
    for _, name in ipairs(require("kebab.registry").tools()) do
      local okp, pkg = pcall(reg.get_package, name)
      if okp and pkg then
        local id = tostring(pkg.spec and pkg.spec.source and pkg.spec.source.id or "")
        local scheme = id:match("^pkg:([%w_]+)")
        local exe = scheme and MASON_ECOSYSTEM[scheme]
        if exe then
          counts[exe] = (counts[exe] or 0) + 1
        end
      end
    end
    for exe, n in pairs(counts) do
      note(exe, ("%d Mason package%s"):format(n, n == 1 and "" or "s"))
    end
  end

  note("java", "jdtls, and running the JDBC bridge")
  return uses
end

---Every check, each tagged with the section it belongs to.
---
---`ok` is true/false only for *required* checks; it is nil for anything whose
---absence is not a failure, so a missing toolchain cannot fail the report.
function M.doctor()
  local checks = {}
  local function add(section, name, ok, detail, extra)
    local check = vim.tbl_extend("keep", {
      section = section, name = name, ok = ok, detail = detail or "",
    }, extra or {})
    checks[#checks + 1] = check
  end

  -- ------------------------------------------------------------- required
  -- 0.12, not 0.11: aerial.nvim's and refactoring.nvim's current releases
  -- both refuse to initialise below it -- aerial by returning from setup()
  -- after a notify_once, which removes the command stub lazy created, so
  -- "File Structure" is silently dead. Measured in a container on 0.11.4
  -- after the README had claimed 0.11 for months.
  local v = vim.version()
  add("Required", "Neovim >= 0.12",
    (v.major > 0 or v.minor >= 12),
    ("%d.%d.%d"):format(v.major, v.minor, v.patch),
    { why = "aerial and refactoring refuse to run below it" })

  local layer = vim.api.nvim_get_runtime_file("lua/kebab/project.lua", false)[1]
  add("Required", "kebab layer on runtimepath", layer ~= nil, layer or "not found")
  add("Required", "lazy.nvim loaded", package.loaded["lazy"] ~= nil)
  add("Required", "LazyVim loaded", _G.LazyVim ~= nil)
  local sheet = vim.api.nvim_get_runtime_file("CHEATSHEET.md", false)[1]
  add("Required", "cheatsheet findable", sheet ~= nil, sheet or "not found")

  for _, cmd in ipairs({ "IdeOpenProject", "IdeNewProject", "IdeInitHere", "IdeCheatsheet" }) do
    add("Required", ":" .. cmd, vim.fn.exists(":" .. cmd) >= 1)
  end

  -- The file tree the layer is built on. Required because its absence is
  -- invisible: LazyVim allows one explorer, decides which before this layer's
  -- spec exists, and then refuses the import without a word -- so a fresh
  -- install had no tree at all and nothing said so. @see kebab.lazyvimjson
  local explorer_ok, explorer_detail = require("kebab.lazyvimjson").explorer_ready()
  add("Required", "file explorer: neo-tree", explorer_ok, explorer_detail,
    { hint = not explorer_ok and "run setup.sh again, or add the extra to lazyvim.json" or nil })

  for _, tool in ipairs(REQUIRED) do
    local path = vim.fn.exepath(tool.exe)
    add("Required", "tool: " .. tool.exe, path ~= "",
      path ~= "" and path or "not on PATH",
      { present = path ~= "", why = tool.why, hint = path == "" and M.install_hint(tool.exe) or nil })
  end

  -- -------------------------------------------------- language toolchains
  --
  -- Anything already reported above is skipped: git and curl are required
  -- outright, and unzip and javac are listed as optional with what they cost,
  -- so repeating them here would be noise.
  local already = {}
  for _, tool in ipairs(REQUIRED) do
    already[tool.exe] = true
  end
  for _, tool in ipairs(OPTIONAL) do
    already[tool.exe] = true
  end

  local uses = M.toolchain_uses()
  local exes = vim.tbl_keys(uses)
  table.sort(exes)
  for _, exe in ipairs(exes) do
    if not already[exe] then
      local path = vim.fn.exepath(exe)
      local present = path ~= ""
      add("Language toolchains", "tool: " .. exe, nil,
        present and path or "not installed",
        {
          present = present,
          enables = table.concat(uses[exe], ", "),
          hint = (not present) and M.install_hint(exe) or nil,
        })
    end
  end

  -- ------------------------------------------------------------- optional
  for _, tool in ipairs(OPTIONAL) do
    local path = vim.fn.exepath(tool.exe)
    local present = path ~= ""
    add("Optional", "tool: " .. tool.exe, nil,
      present and path or "not on PATH",
      {
        present = present,
        why = tool.why,
        without = tool.without,
        hint = (not present) and M.install_hint(tool.exe) or nil,
      })
  end

  -- ---------------------------------------------------------------- state
  local roots = project.roots()
  local existing = {}
  for _, r in ipairs(roots) do
    local path = require("kebab.path").expand(r)
    if vim.uv.fs_stat(path) then
      existing[#existing + 1] = path
    end
  end
  add("Projects", "project roots exist", nil,
    ("%d/%d present: %s"):format(#existing, #roots, table.concat(existing, ", ")),
    { present = #existing > 0 })
  local discovered, problems = project.discover()
  add("Projects", "projects discovered", nil, tostring(#discovered), { present = #discovered > 0 })
  add("Projects", "project roots readable", nil,
    #problems == 0 and "all" or table.concat(project.problem_lines(problems), "; "),
    { present = #problems == 0, why = "a root that cannot be read hides every project inside it" })

  return checks
end

---Formatted report, grouped, with what to run for anything missing.
---@param opts? { verbose?: boolean }
---@return string[] lines, boolean ok
function M.doctor_lines(opts)
  opts = opts or {}
  local checks = M.doctor()
  local lines, ok = {}, true
  local section
  local counts = { ok = 0, missing = 0, required_missing = 0 }

  for _, c in ipairs(checks) do
    if c.section ~= section then
      section = c.section
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = section
    end

    local mark
    if c.ok == true then
      mark = "ok"
      counts.ok = counts.ok + 1
    elseif c.ok == false then
      mark = "FAIL"
      ok = false
      counts.required_missing = counts.required_missing + 1
      counts.missing = counts.missing + 1
    elseif c.present == false then
      mark = "--"
      counts.missing = counts.missing + 1
    else
      mark = "ok"
      counts.ok = counts.ok + 1
    end

    local label = (c.name:gsub("^tool: ", ""))
    -- Paths are shortened to ~ so the columns survive a long one.
    local detail = c.detail
    if detail ~= "" and detail:sub(1, 1) == "/" then
      detail = vim.fn.fnamemodify(detail, ":~")
    end
    lines[#lines + 1] = ("  %-4s %-16s %s"):format(mark, label, detail)

    -- The actionable part. Shown only where something is missing: for a tool
    -- that is present, its path is the whole story.
    if c.present == false or c.ok == false then
      if c.enables then
        lines[#lines + 1] = ("         costs:   %s"):format(c.enables)
      end
      if c.without then
        lines[#lines + 1] = ("         costs:   %s"):format(c.without)
      end
      if c.why and not c.enables and not c.without then
        lines[#lines + 1] = ("         needed:  %s"):format(c.why)
      end
      if c.hint then
        lines[#lines + 1] = ("         install: %s"):format(c.hint)
      end
    end
  end

  lines[#lines + 1] = ""
  if counts.required_missing > 0 then
    lines[#lines + 1] = ("%d ok, %d missing — %d of them required.")
      :format(counts.ok, counts.missing, counts.required_missing)
  elseif counts.missing > 0 then
    lines[#lines + 1] = ("%d ok, %d missing. Nothing required is absent; each line above says what it costs.")
      :format(counts.ok, counts.missing)
  else
    lines[#lines + 1] = ("%d ok, nothing missing."):format(counts.ok)
  end

  -- Name every manager the hints above actually used. Naming only the first
  -- one claimed "suggestions use mise" directly under `install: sudo pacman -S
  -- jq`, and a reader went looking for a mise recipe that does not exist.
  local managers = {}
  for _, manager in ipairs({ M.package_manager(), M.system_package_manager() }) do
    if manager and not vim.tbl_contains(managers, manager) then
      managers[#managers + 1] = manager
    end
  end
  if counts.missing > 0 and #managers > 0 then
    lines[#lines + 1] = ("Install suggestions use %s, which is what this machine has."):format(
      table.concat(managers, " and ")
    )
  end

  return lines, ok
end

---Show the report in a scratch buffer. `kebab doctor` prints it to a terminal;
---this is the same thing from inside the editor, where it is too long for a
---notification.
function M.doctor_buffer()
  local lines, ok = M.doctor_lines()
  vim.cmd("new")
  local buf = vim.api.nvim_get_current_buf()
  -- Scratch options first, and a name that is free. A second :IdeDoctor while
  -- the first report was still on screen threw E95 out of nvim_buf_set_name --
  -- leaving the user in a bare modifiable window with swap on, because none of
  -- the options below had been applied yet.
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local base = "kebab://doctor"
  local name, n = base, 1
  while vim.fn.bufexists(name) == 1 do
    n = n + 1
    name = ("%s#%d"):format(base, n)
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false,
    vim.list_extend({ "kebab.nvim doctor", "" }, lines))
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "kebabdoctor"
  return ok
end

function M.setup()
  vim.api.nvim_create_user_command("IdeDoctor", function()
    M.doctor_buffer()
  end, { desc = "Check the install: what is missing and what it costs" })
end

---Print lines and quit with a sensible exit code. Used by the headless
---subcommands, where stdout is the whole point.
function M.print_and_quit(lines, ok)
  for _, l in ipairs(lines) do
    io.write(l .. "\n")
  end
  vim.cmd(ok == false and "cq 1" or "qa!")
end

return M
