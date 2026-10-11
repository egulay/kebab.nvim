-- Keeps the project tree open on the left the way a graphical IDE's project
-- pane is, instead of toggling it with <leader>e every time.
--
-- Registered from config/options.lua rather than config/autocmds.lua on
-- purpose: autocmds.lua is loaded on VeryLazy, which is *after* the first
-- file's BufReadPost, so `nvim some/file.java` would miss the event. options
-- is loaded before lazy.nvim starts, so the autocmd is always in place.

local M = {}

local function open_project_tree()
  if vim.g.ide_explorer_opened or vim.o.diff then
    return
  end
  vim.g.ide_explorer_opened = true
  vim.schedule(function()
    -- neo-tree is lazy-loaded on `:Neotree`/<leader>e, so its directory is not
    -- on the runtimepath yet and a bare require() would fail.
    pcall(function()
      require("lazy").load({ plugins = { "neo-tree.nvim" } })
    end)
    local ok, cmd = pcall(require, "neo-tree.command")
    if not ok then
      return
    end
    local root = (LazyVim and LazyVim.root and LazyVim.root()) or vim.uv.cwd()
    -- `show` opens the pane but leaves the cursor in the editor.
    pcall(cmd.execute, { action = "show", dir = root })
  end)
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
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = vim.api.nvim_create_augroup("ide_auto_explorer", { clear = true }),
    callback = function(ev)
      if is_real_file(ev.buf) then
        open_project_tree()
      end
    end,
  })
end

return M
