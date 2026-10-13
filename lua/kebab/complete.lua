-- What the shell needs to complete `kebab`, written where a shell can read it
-- without starting Neovim.
--
-- The constraint that shapes this: tab completion has to answer in a few
-- milliseconds, and every real `kebab` command boots an editor (`kebab list`
-- is ~200ms at best, and `jdtls` makes `kebab open` far worse). A completion
-- that shells out to the thing it completes is a completion nobody leaves
-- installed.
--
-- So the authoritative lists -- which commands exist, which project types a
-- language declared, what each type asks -- are written to a cache file here,
-- and `bin/kebab __complete` reads only that. Nothing in the fast path parses
-- Lua or guesses: an earlier attempt grepped `key = "..."` out of
-- lua/kebab/languages/*.lua and collected 36 names for 11 types, because
-- scratch kinds and file templates use the same field.
--
-- The cache refreshes itself: every command that boots an editor calls
-- `M.write()` on the way out, so ordinary use keeps it current and adding a
-- language needs no extra step. `setup.sh` warms it at install time, and a
-- missing cache degrades to completing the command names only.
--
-- Format: one record per line, `section<TAB>value`, because the reader is
-- bash and `jq` is optional on this machine.
local M = {}

---@return string
function M.path()
  local dir = vim.fn.stdpath("cache") .. "/kebab"
  return dir .. "/completion"
end

---Everything the shell can offer, as section/value pairs.
---@return string[] lines
function M.lines()
  local lines = {}
  local function add(section, value)
    if value ~= nil and value ~= "" then
      lines[#lines + 1] = ("%s\t%s"):format(section, value)
    end
  end

  -- The commands `bin/kebab` dispatches, and the read-only queries, which are
  -- `kebab.agent`'s own list rather than a copy of it.
  for _, name in ipairs({
    "open", "new", "types", "db", "list", "doctor", "serve", "help", "version",
  }) do
    add("command", name)
  end
  for _, name in ipairs(require("kebab.agent").COMMANDS) do
    add("command", name)
    add("query", name)
  end

  for _, type_def in ipairs(require("kebab.registry").project_types()) do
    add("type", type_def.key)
    -- the prompts a type declares become `--name value` options on `kebab new`
    for _, prompt in ipairs(type_def.prompts or {}) do
      if prompt.name then
        add("answer", (prompt.name:gsub("_", "-")))
      end
    end
  end

  -- The project roots, so the fast path can list directories without knowing
  -- how they are configured.
  for _, root in ipairs(require("kebab.project").roots()) do
    add("root", require("kebab.path").expand(root))
  end

  add("store", require("kebab.db").store_path())
  return lines
end

---Write the cache. Never raises: a completion cache is a convenience, and a
---command that fails because it could not write one would be absurd.
---@return boolean written, string|nil err
function M.write()
  local ok, result = pcall(function()
    local lines = M.lines()
    return require("kebab.fs").write_lines(M.path(), lines)
  end)
  if not ok then
    return false, tostring(result)
  end
  return result == true, nil
end

---Is a shell completion script linked where the shell will find it?
---
---Reported by `kebab doctor` because the failure is otherwise silent: an
---unlinked completion is indistinguishable from a CLI that has none.
---@return { ok: boolean, detail: string }
function M.installed()
  local data = vim.env.XDG_DATA_HOME
  if data == nil or data == "" then
    data = vim.env.HOME .. "/.local/share"
  end
  local found = {}
  local candidates = {
    bash = data .. "/bash-completion/completions/kebab",
    zsh = data .. "/zsh/site-functions/_kebab",
  }
  for shell, path in pairs(candidates) do
    if vim.uv.fs_stat(path) then
      found[#found + 1] = shell
    end
  end
  table.sort(found)
  if #found == 0 then
    return { ok = false, detail = "not linked for bash or zsh" }
  end
  return { ok = true, detail = table.concat(found, ", ") }
end

return M
