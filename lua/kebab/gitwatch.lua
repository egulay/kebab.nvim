-- Noticing that git state changed outside the editor.
--
-- `kebab.follow` watches the working tree and *excludes* `.git`, which is
-- right: you do not want the view jumping to `.git/index`. But it means
-- nothing sees a commit, a checkout, a stash or a push -- and a push in
-- particular changes no file at all, only `.git/refs/remotes/...`. So the tree
-- kept showing a file as modified after it had been committed elsewhere.
--
-- This watches `.git` itself and does one thing: asks the things that render
-- git state to re-read it. It never moves the cursor or opens anything.
local M = {}

local STATE = { running = false, stop = nil, timer = nil, root = nil, refreshes = 0 }

---How long to coalesce. A single `git commit` touches several files under
---`.git`, and a rebase touches many.
function M.debounce_ms()
  return tonumber(vim.g.kebab_git_watch_debounce) or 300
end

---Re-read git state everywhere it is displayed.
---
---Deliberately belt and braces: each consumer caches separately, and the one
---that was stale is the one the user notices.
function M.refresh()
  STATE.refreshes = STATE.refreshes + 1

  -- gitsigns: the gutter marks and the +/~/- counts
  pcall(function()
    local gs = package.loaded["gitsigns"]
    if gs and gs.refresh then
      gs.refresh()
    end
  end)

  -- neo-tree: both the markers and the name highlight. The event alone leaves
  -- a partial update on some versions, so the filesystem source is refreshed
  -- too.
  pcall(function()
    local events = require("neo-tree.events")
    if events and events.fire_event then
      events.fire_event(events.GIT_EVENT)
    end
  end)
  pcall(function()
    local mgr = require("neo-tree.sources.manager")
    if mgr and mgr.refresh then
      mgr.refresh("filesystem")
    end
  end)

  -- and the statusline, which caches the branch
  pcall(function()
    vim.cmd("redrawstatus!")
  end)
  return true
end

---Is the watcher running?
function M.running()
  return STATE.running
end

function M.state()
  return { running = STATE.running, root = STATE.root, refreshes = STATE.refreshes }
end

local function cancel_timer()
  if STATE.timer then
    pcall(function()
      STATE.timer:stop()
      if not STATE.timer:is_closing() then
        STATE.timer:close()
      end
    end)
    STATE.timer = nil
  end
end

---The `.git` directory for `root`, resolving a worktree's `.git` file.
---@param root string
---@return string|nil
function M.git_dir(root)
  local path = root .. "/.git"
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  if stat.type == "directory" then
    return path
  end
  -- A worktree or submodule has `.git` as a *file* holding "gitdir: <path>".
  local lines = require("kebab.fs").read_lines(path) or {}
  local target = (lines[1] or ""):match("^gitdir:%s*(.+)$")
  if not target then
    return nil
  end
  if not target:match("^/") then
    target = root .. "/" .. target
  end
  return vim.fn.fnamemodify(target, ":p"):gsub("/$", "")
end

---Start watching `root`'s git directory.
---@param root? string
---@return boolean ok, string|nil err
function M.start(root)
  if STATE.running then
    return false, "already watching"
  end
  root = root or ((LazyVim and LazyVim.root and LazyVim.root()) or vim.uv.cwd())
  local dir = M.git_dir(root)
  if not dir then
    return false, "not a git repository: " .. tostring(root)
  end

  local ok, watch = pcall(require, "vim._watch")
  if not ok then
    return false, "vim._watch is not available"
  end
  local backend = watch.inotify or watch.watchdirs or watch.watch
  if not backend then
    return false, "no file-watching backend available"
  end

  local started, stop_or_err = pcall(backend, dir, {}, function()
    -- Coalesced: one commit writes several files in here.
    vim.schedule(function()
      if not STATE.running then
        return
      end
      cancel_timer()
      STATE.timer = vim.uv.new_timer()
      STATE.timer:start(
        M.debounce_ms(),
        0,
        vim.schedule_wrap(function()
          cancel_timer()
          if STATE.running then
            M.refresh()
          end
        end)
      )
    end)
  end)
  if not started then
    return false, "could not watch " .. dir .. ": " .. tostring(stop_or_err)
  end

  STATE.running = true
  STATE.stop = type(stop_or_err) == "function" and stop_or_err or nil
  STATE.root = root
  return true
end

function M.stop()
  cancel_timer()
  if STATE.stop then
    pcall(STATE.stop)
  end
  local was = STATE.running
  STATE.running = false
  STATE.stop = nil
  return was
end

function M.setup()
  vim.api.nvim_create_user_command("IdeGitRefresh", function()
    M.refresh()
    vim.notify("Re-read git state")
  end, { desc = "Re-read git state after a commit, checkout or push made elsewhere" })

  local group = vim.api.nvim_create_augroup("kebab_gitwatch", { clear = true })

  vim.api.nvim_create_autocmd({ "VimLeavePre", "VimLeave", "QuitPre" }, {
    group = group,
    callback = function()
      STATE.shutting_down = true
      pcall(M.stop)
    end,
  })

  if vim.g.kebab_git_watch == false then
    return
  end
  local function autostart()
    if STATE.shutting_down or vim.v.exiting ~= vim.NIL or M.running() then
      return
    end
    local ft = vim.bo[vim.api.nvim_get_current_buf()].filetype
    if ft == "gitcommit" or ft == "gitrebase" then
      return
    end
    pcall(M.start)
  end
  vim.api.nvim_create_autocmd({ "VimEnter", "BufEnter", "DirChanged" }, {
    group = group,
    nested = true,
    callback = function(ev)
      if ev.event == "DirChanged" then
        pcall(M.stop)
      end
      vim.schedule(autostart)
    end,
  })
  if vim.v.vim_did_enter == 1 then
    vim.schedule(autostart)
  end
end

return M
