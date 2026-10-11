-- Add a dependency to the project you are in -- BACKLOG.md's "biggest remaining
-- daily gap against a graphical IDE".
--
-- This file no longer knows about any particular ecosystem. Each language in
-- lua/kebab/languages/ declares, per project marker, how a dependency is added:
-- a `command` to run (`go get`, `cargo add`, `npm install`, `flutter pub add`,
-- `uv add`), an `edit` function for the one ecosystem with no such command
-- (Maven, where the pom is rewritten -- see kebab/maven.lua), or `unsupported`
-- with a reason. Adding Rust meant declaring `cargo add` in one file, not
-- extending a chain of elseifs here.
local M = {}

local registry = require("kebab.registry")

---Which kind of project `dir` belongs to, walking up to the filesystem root.
---@param dir string
---@return string|nil kind e.g. "maven", "node", "flutter", "python", "go", "rust"
---@return string|nil marker_path
function M.detect(dir)
  local kind, marker_path = registry.find_project(dir)
  return kind, marker_path
end

---The command that adds `package` to a project of `kind`, or nil plus a reason.
---@param kind string
---@param package string
---@param opts? { dev?: boolean, dir?: string }
---@return table|nil cmd, string|nil err
function M.command_for(kind, package, opts)
  opts = opts or {}
  package = vim.trim(package or "")
  if package == "" then
    return nil, "No package given"
  end
  -- A package name reaches a shell-less vim.system as one argv element, but
  -- refuse the obviously wrong shapes early so the error is ours and clear.
  if package:match("%s") then
    return nil, ("%q contains whitespace; add one package at a time"):format(package)
  end

  local deps = registry.deps_for(kind)
  if not deps then
    return nil, "Unknown project kind: " .. tostring(kind)
  end
  if deps.unsupported then
    return nil, deps.unsupported
  end
  if deps.edit then
    return nil, ("%s dependencies are written into %s, not installed by a command")
      :format(kind, deps.file or "the build file")
  end
  if not deps.command then
    return nil, "No way to add a dependency to a " .. tostring(kind) .. " project"
  end
  return deps.command(package, opts)
end

---How to install `exe`, borrowed from the doctor so the advice is in one place.
---Required lazily: cli.lua pulls in project.lua and the registry, which there
---is no reason to load just to add a dependency.
---@param exe string
---@return string|nil
function M.install_hint(exe)
  local ok, cli = pcall(require, "kebab.cli")
  if not ok then
    return nil
  end
  local hinted, hint = pcall(cli.install_hint, exe)
  return hinted and hint or nil
end

---The prompt to show for a project of `kind`.
function M.prompt_for(kind)
  local deps = registry.deps_for(kind)
  return (deps and deps.prompt) or ("Package to add (" .. tostring(kind) .. "): ")
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

---Interactive entry point: `:IdeAddDependency`.
---
---@param arg? string a package or coordinate, to skip the prompt
---@param opts? { dev?: boolean, cwd?: string, done?: fun(ok:boolean, err:string|nil) }
function M.add(arg, opts)
  opts = opts or {}
  local done = opts.done or function() end
  local start = opts.cwd or vim.fn.getcwd()
  local kind, marker = M.detect(start)
  if not kind then
    local files = table.concat(registry.marker_files(), ", ")
    notify(("No project above %s (looked for %s)"):format(start, files), vim.log.levels.WARN)
    return done(false, "no project found")
  end
  local root = vim.fn.fnamemodify(marker, ":h")
  local deps = registry.deps_for(kind) or {}

  local function with_input(value)
    if value == nil or vim.trim(value) == "" then
      return done(false, "cancelled")
    end

    -- Ecosystems with no add-a-dependency command edit their build file.
    if deps.edit then
      local ok, message = deps.edit(marker, value, opts)
      if not ok then
        notify(message or "Could not add the dependency", vim.log.levels.ERROR)
        return done(false, message)
      end
      notify(message or ("Added " .. value))
      -- jdtls and friends pick build-file changes up on their own; the buffer
      -- showing the file needs rereading.
      vim.cmd("checktime")
      return done(true)
    end

    local cmd, cerr = M.command_for(kind, value, { dev = opts.dev, dir = root })
    if not cmd then
      notify(cerr, vim.log.levels.ERROR)
      return done(false, cerr)
    end

    -- vim.system *throws* ENOENT for a missing executable rather than
    -- reporting it, so the whole call would blow up and `done` would never
    -- fire. Check first, and say how to install it -- the doctor already knows.
    if vim.fn.executable(cmd[1]) == 0 then
      local hint = M.install_hint(cmd[1])
      local msg = ("%s is not installed, so %s dependencies cannot be added%s")
        :format(cmd[1], kind, hint and ("\n  install: " .. hint) or "")
      notify(msg, vim.log.levels.ERROR)
      return done(false, msg)
    end

    notify("… " .. table.concat(cmd, " "))
    vim.system(cmd, { cwd = root, text = true }, function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          local msg = ("%s failed (%d)\n%s"):format(cmd[1], res.code,
            (res.stderr or "") .. (res.stdout or ""))
          notify(msg, vim.log.levels.ERROR)
          return done(false, msg)
        end
        -- Some ecosystems want a follow-up: `go get` leaves go.mod needing a
        -- tidy. Failure here is reported but does not undo the add.
        if deps.after and vim.fn.executable(deps.after[1]) == 1 then
          vim.system(deps.after, { cwd = root, text = true }, function(after)
            vim.schedule(function()
              if after.code ~= 0 then
                notify(("Added %s, but %s failed"):format(value, table.concat(deps.after, " ")),
                  vim.log.levels.WARN)
              else
                notify("Added " .. value)
              end
              vim.cmd("checktime")
              done(true)
            end)
          end)
          return
        end
        notify("Added " .. value)
        vim.cmd("checktime")
        done(true)
      end)
    end)
  end

  if arg and vim.trim(arg) ~= "" then
    return with_input(arg)
  end
  vim.ui.input({ prompt = M.prompt_for(kind) }, with_input)
end

function M.setup()
  vim.api.nvim_create_user_command("IdeAddDependency", function(cmd)
    M.add(cmd.args ~= "" and cmd.args or nil, { dev = cmd.bang })
  end, {
    nargs = "?",
    bang = true,
    desc = "Add a dependency to this project (! for a dev dependency)",
  })
end

return M
