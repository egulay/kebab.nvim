-- Keeps the project tree open on the left the way a graphical IDE's project
-- pane is, instead of toggling it with <leader>e every time.
--
-- Registered from config/options.lua rather than config/autocmds.lua on
-- purpose: autocmds.lua is loaded on VeryLazy, which is *after* the first
-- file's BufReadPost, so `nvim some/file.java` would miss the event. options
-- is loaded before lazy.nvim starts, so the autocmd is always in place.

local M = {}

---@param opts? { dir?: string }
local function open_project_tree(opts)
  if vim.g.ide_explorer_opened then
    return
  end
  vim.g.ide_explorer_opened = true
  vim.schedule(function()
    -- Checked here, not above: diff mode is turned on *after* the first file's
    -- BufReadPost, so a guard at call time always read false and `nvim -d a b`
    -- still got a tree shoved alongside the diff.
    if vim.o.diff then
      return
    end
    -- neo-tree is lazy-loaded on `:Neotree`/<leader>e, so its directory is not
    -- on the runtimepath yet and a bare require() would fail.
    pcall(function()
      require("lazy").load({ plugins = { "neo-tree.nvim" } })
    end)
    local ok, cmd = pcall(require, "neo-tree.command")
    if not ok then
      return
    end
    local root = (opts and opts.dir)
      or (LazyVim and LazyVim.root and LazyVim.root())
      or vim.uv.cwd()
    -- `show` opens the pane but leaves the cursor in the editor.
    pcall(cmd.execute, { action = "show", dir = root })
    M.replace_netrw()
  end)
end

---Clear netrw out of the main window.
---
---`nvim <dir>` opens the directory in netrw, and neo-tree's sidebar opens
---beside it -- so a project opened from the shell showed *two* file browsers,
---the tree on the left and netrw filling the rest. Nothing in the layer did
---that on purpose; it is simply what Vim does with a directory argument.
---
---netrw itself is left enabled: `:Explore` and `gx` still work. Only the
---buffer occupying the window is replaced, and only when it is netrw's.
---@return boolean replaced
function M.replace_netrw()
  local replaced = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "netrw" then
      vim.api.nvim_win_call(win, function()
        pcall(vim.cmd, "enew")
      end)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      replaced = true
    end
  end
  return replaced
end

---The directory Neovim was started on, if it was started on one.
---
---`nvim ~/Projects/thing` is how a project gets opened from a shell, and it
---produces no BufReadPost at all -- there is no file to read.
---@return string|nil
function M.directory_argument()
  if vim.fn.argc() < 1 then
    return nil
  end
  local first = vim.fn.argv(0)
  if type(first) ~= "string" or first == "" then
    return nil
  end
  local full = vim.fn.fnamemodify(first, ":p"):gsub("/+$", "")
  local stat = vim.uv.fs_stat(full)
  if stat and stat.type == "directory" then
    return full
  end
  return nil
end

local function is_real_file(buf)
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  local ft = vim.bo[buf].filetype
  -- don't hijack `git commit`, `git rebase -i`, man pages, help
  return ft ~= "gitcommit" and ft ~= "gitrebase" and ft ~= "man" and ft ~= "help"
end

function M.setup()
  local group = vim.api.nvim_create_augroup("ide_auto_explorer", { clear = true })

  -- A file the editor cannot usefully show goes to the desktop instead. Set
  -- up here because this runs from the neo-tree spec's `init`, i.e. before any
  -- file has been read -- a BufReadCmd registered later than the first read is
  -- a BufReadCmd that missed it, which is the same timing trap the explorer
  -- autocmd above exists for.
  require("kebab.openexternal").setup()

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      if is_real_file(ev.buf) then
        open_project_tree()
      end
    end,
  })

  -- A directory argument produces no BufReadPost, so the tree needs its own
  -- trigger. LazyVim has one, but this layer declares `init` on the neo-tree
  -- spec and lazy.nvim *replaces* init rather than chaining it -- so LazyVim's
  -- never ran, its Neotree_start_directory augroup was never created, and
  -- `nvim ~/Projects/thing` opened a single plain window with no tree at all.
  -- Owning it here means the layer does not depend on which init won.
  -- BufEnter as well as VimEnter, and deliberately not `once`: VimEnter has
  -- not fired yet while `-c` commands run, and under --headless it may never
  -- fire at all -- which is also why LazyVim's own version of this hooks
  -- BufEnter. Returning true deletes the autocmd as soon as the question is
  -- settled, so this costs one argv check and then nothing.
  vim.api.nvim_create_autocmd({ "BufEnter", "VimEnter" }, {
    group = group,
    nested = true,
    callback = function()
      local dir = M.directory_argument()
      if dir then
        open_project_tree({ dir = dir })
      end
      return true
    end,
  })
end

return M
