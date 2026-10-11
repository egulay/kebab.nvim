-- Helpers for the `build` functions in lua/kebab/languages/*.lua.
--
-- Separate from project.lua so a language definition can require it without a
-- cycle: project.lua pulls the languages in through the registry, so a language
-- cannot require project.lua back.
local M = {}

---Run shell steps one after another, stopping at the first failure, then call
---done(ok, err). Each step is { cmd = {...}, label?, cwd? }.
---@param steps table[]
---@param cwd string
---@param done fun(ok:boolean, err?:string)
function M.run_steps(steps, cwd, done)
  local i = 0
  local function next_step()
    i = i + 1
    local step = steps[i]
    if not step then
      return done(true)
    end
    -- vim.system throws ENOENT for a missing executable instead of returning
    -- a code, which would abort the scaffold with a stack trace and never call
    -- `done`. project.create checks a type's declared `requires` up front;
    -- this catches anything a build step runs beyond those.
    if vim.fn.executable(step.cmd[1]) == 0 then
      local msg = ("%s is not installed, so %s cannot run")
        :format(step.cmd[1], step.label or step.cmd[1])
      vim.notify(msg, vim.log.levels.ERROR)
      return done(false, msg)
    end
    -- The other way vim.system throws: a cwd that does not exist. A step
    -- whose directory an earlier step was supposed to create (`npm install`
    -- after `npm create vite`) raised inside the scheduled callback, where the
    -- error is swallowed -- so `done` was never called at all and
    -- `kebab new --no-open` sat in its 15-minute wait over a half-built tree.
    local where = step.cwd or cwd
    if where and vim.fn.isdirectory(where) == 0 then
      local msg = ("%s cannot run: %s does not exist"):format(step.label or step.cmd[1], where)
      vim.notify(msg, vim.log.levels.ERROR)
      return done(false, msg)
    end
    vim.notify("… " .. (step.label or step.cmd[1]))
    -- Belt and braces: anything else vim.system decides to throw must still
    -- reach `done`, because that is the only way a caller learns the outcome.
    local spawned, serr = pcall(vim.system, step.cmd, { cwd = where, text = true }, function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          local msg = ("%s failed (%d)\n%s"):format(
            step.label or step.cmd[1], res.code, (res.stderr or "") .. (res.stdout or ""))
          vim.notify(msg, vim.log.levels.ERROR)
          return done(false, msg)
        end
        next_step()
      end)
    end)
    if not spawned then
      local msg = ("%s could not start: %s"):format(step.label or step.cmd[1], tostring(serr))
      vim.notify(msg, vim.log.levels.ERROR)
      return done(false, msg)
    end
  end
  next_step()
end

---Write `lines` to `path`, creating parent directories.
---@param path string
---@param lines string[]
function M.write_file(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

---mkdir -p
function M.mkdir(path)
  vim.fn.mkdir(path, "p")
end

---The directory a scaffold should run *in*, for tools that create the project
---directory themselves (`flutter create`, `cargo new`, `npm create vite`).
function M.parent_of(dest)
  -- A trailing separator would make this one level too deep, and leaf_of empty.
  return vim.fn.fnamemodify((tostring(dest):gsub("/+$", "")), ":h")
end

---The last path component, which is what such tools are given as the name.
function M.leaf_of(dest)
  return vim.fn.fnamemodify((tostring(dest):gsub("/+$", "")), ":t")
end

---A project name reduced to what a given ecosystem allows.
---@param name string
---@param style "snake"|"kebab"|"plain"
function M.sanitise(name, style)
  if style == "snake" then
    return (name:gsub("[^%w_]", "_"):lower())
  elseif style == "kebab" then
    return (name:gsub("[^%w%-]", "-"):lower())
  end
  return (name:gsub("[^%w_%-]", "-"))
end

---The package clause a new Go file in `dir` should carry.
---
---Go's package name is the directory's, but a directory name is not
---necessarily a Go identifier: `~/Projects/my-tool` gave `package my-tool`,
---which is a syntax error, and the whole package stopped type-checking.
---@param dir string
---@return string
function M.go_package(dir)
  -- At a module root the package is main, which is what the scaffold writes.
  if vim.uv.fs_stat(dir .. "/go.mod") then
    return "main"
  end
  local pkg = (vim.fn.fnamemodify(dir, ":t"):gsub("[^%w_]", "_"):lower())
  if pkg == "" then
    return "main"
  end
  -- an identifier cannot start with a digit
  if pkg:match("^%d") then
    pkg = "pkg_" .. pkg
  end
  return pkg
end

return M
