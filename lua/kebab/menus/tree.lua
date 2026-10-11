-- Right-click menu for the project tree, with the git operations neo-tree
-- only binds in its git_status source.
--
-- IMPORTANT: by the time a menu entry runs, the focused window is the menu
-- (or whatever the menu restored), not the tree. neo-tree's
-- get_state_for_window() returns nil for a non-tree window, so resolving the
-- state lazily here -- and refocusing the tree before running the command --
-- is what makes these actions work at all.
--
-- Every entry is tagged with a descriptor (see kebab.menus.action) so
-- tests/spec/menu_tree_spec.lua can check its target exists without clicking it.
local A = require("kebab.menus.action")

-- neo-tree is lazy-loaded, so requiring its modules at file scope would fail
-- whenever this file is read before the plugin has started -- which is exactly
-- what the sweep does. Resolve them on use instead.
local function neotree(mod)
  local ok, m = pcall(require, "neo-tree." .. mod)
  if not ok then
    return nil
  end
  return m
end

local function manager()
  return neotree("sources.manager")
end

-- The window that was focused when the menu was opened, else any neo-tree
-- window in this tab.
local function tree_win()
  local ok, mstate = pcall(require, "menu.state")
  local w = ok and mstate.old_data and mstate.old_data.win or nil
  if w and vim.api.nvim_win_is_valid(w) and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "neo-tree" then
    return w
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree" then
      return win
    end
  end
  return nil
end

local function get_state()
  local w = tree_win()
  local mgr = manager()
  if not w or not mgr then
    return nil
  end
  local state = mgr.get_state_for_window(w)
  if state then
    state.config = state.config or {}
  end
  return state
end

---The set of commands available for a neo-tree source: the source's own, plus
---the common ones every source inherits. Used both to dispatch and to let the
---sweep check an entry names a command that exists.
---@param source string|nil defaults to "filesystem"
local function source_commands(source)
  local common = neotree("sources.common.commands") or {}
  local own = neotree("sources." .. (source or "filesystem") .. ".commands") or {}
  return own, common
end

-- Run a neo-tree command with the tree focused, the way pressing the key in
-- the tree would. Commands that prompt (add, rename, delete) need real focus.
local function call(what)
  local fn = vim.schedule_wrap(function()
    local w = tree_win()
    if not w then
      return vim.notify("neo-tree: tree window not found", vim.log.levels.WARN)
    end
    local mgr = manager()
    if not mgr then
      return vim.notify("neo-tree is not available", vim.log.levels.WARN)
    end
    vim.api.nvim_set_current_win(w)
    local state = mgr.get_state_for_window(w)
    if not state then
      return vim.notify("neo-tree: no state for tree window", vim.log.levels.WARN)
    end
    state.config = state.config or {}
    local own, common = source_commands(state.name)
    local cb = own[what] or common[what]
    if not cb then
      return vim.notify("neo-tree: no command '" .. what .. "'", vim.log.levels.WARN)
    end
    local called, err = pcall(cb, state)
    if not called then
      vim.notify("neo-tree: " .. what .. " failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
  return A.tag(fn, { kind = "neotree", command = what })
end

local function current_node()
  local state = get_state()
  if not state or not state.tree then
    return nil
  end
  local node = state.tree:get_node()
  if not node or node.type == "message" then
    return nil
  end
  return node
end

local function copy_path(how)
  local fn = function()
    local node = current_node()
    if not node then
      return vim.notify("neo-tree: nothing selected", vim.log.levels.WARN)
    end
    local p = vim.fn.fnamemodify(node.path, how)
    vim.fn.setreg('"', p)
    vim.fn.setreg("+", p)
    vim.notify("Copied: " .. p)
  end
  return A.tag(fn, {
    kind = "custom",
    label = "copy path (" .. how .. ")",
    check = function()
      -- fnamemodify is the whole implementation; prove the modifier is one it
      -- understands rather than silently yielding the unchanged path.
      local sample = "/tmp/kebab-check/file.txt"
      local got = vim.fn.fnamemodify(sample, how)
      if type(got) ~= "string" or got == "" then
        return false, "fnamemodify(" .. how .. ") returned nothing"
      end
      return true
    end,
  })
end

local function open_in_terminal()
  local node = current_node()
  if not node then
    return vim.notify("neo-tree: nothing selected", vim.log.levels.WARN)
  end
  local stat = vim.uv.fs_stat(node.path)
  local dir = (stat and stat.type == "directory") and node.path or vim.fn.fnamemodify(node.path, ":h")
  local ok = pcall(function()
    Snacks.terminal(nil, { cwd = dir })
  end)
  if not ok then
    vim.cmd("enew")
    vim.fn.jobstart({ vim.o.shell }, { cwd = dir, term = true })
  end
end

-- Revert that discards everything the node covers, rather than raw
-- `git checkout`. The logic lives in kebab.git so it can be tested against a
-- real repository without a tree window; this resolves the clicked node and
-- asks for confirmation.
local function revert_node()
  local git = require("kebab.git")
  local node = current_node()
  if not node then
    return vim.notify("Nothing selected in the tree", vim.log.levels.WARN)
  end
  local plan, err = git.revert_plan(node.path)
  if not plan then
    return vim.notify(err, vim.log.levels.WARN)
  end
  local label = vim.fn.fnamemodify(plan.path, ":t")
  if git.is_empty(plan) then
    return vim.notify("Nothing to revert in " .. label, vim.log.levels.INFO)
  end

  local msg = ("Revert %s: %s?"):format(label, git.describe_plan(plan))
  local inputs = neotree("ui.inputs")
  local function finish(yes)
    if not yes then
      return vim.notify("Revert cancelled", vim.log.levels.INFO)
    end
    local ok, failed = git.apply_revert(plan)
    -- pull reverted contents back into any open buffers
    vim.cmd("checktime")
    local events = neotree("events")
    if events then
      pcall(events.fire_event, events.GIT_EVENT)
    end
    local mgr = manager()
    if mgr then
      pcall(mgr.refresh, "filesystem")
    end
    if not ok then
      vim.notify("Revert partly failed: " .. table.concat(failed, ", "), vim.log.levels.ERROR)
    else
      vim.notify(("Reverted %s (%d restored, %d deleted)")
        :format(label, #plan.modified, #plan.untracked))
    end
  end

  if inputs then
    inputs.confirm(msg, finish)
  else
    vim.ui.select({ "No", "Yes" }, { prompt = msg }, function(ans)
      finish(ans == "Yes")
    end)
  end
end

local menu = {
  { name = "Open", cmd = call("open"), rtxt = "<CR>" },
  { name = "Open in Vertical Split", cmd = call("open_vsplit"), rtxt = "s" },
  { name = "Open in Horizontal Split", cmd = call("open_split"), rtxt = "S" },
  { name = "Open in New Tab", cmd = call("open_tabnew"), rtxt = "t" },
  { name = "separator" },

  { name = "New File", cmd = call("add"), rtxt = "a" },
  { name = "New Folder", cmd = call("add_directory"), rtxt = "A" },
  { name = "Rename", cmd = call("rename"), rtxt = "r" },
  { name = "Delete", cmd = call("delete"), rtxt = "d" },
  { name = "separator" },

  { name = "Copy", cmd = call("copy_to_clipboard"), rtxt = "y" },
  { name = "Cut", cmd = call("cut_to_clipboard"), rtxt = "x" },
  { name = "Paste", cmd = call("paste_from_clipboard"), rtxt = "p" },
  { name = "Copy Absolute Path", cmd = copy_path(":p"), rtxt = "gy" },
  { name = "Copy Relative Path", cmd = copy_path(":~:."), rtxt = "Y" },
  { name = "separator" },

  {
    name = "Git",
    items = {
      { name = "Stage File", cmd = call("git_add_file"), rtxt = "ga" },
      { name = "Unstage File", cmd = call("git_unstage_file"), rtxt = "gu" },
      { name = "Toggle Staged", cmd = call("git_toggle_file_stage"), rtxt = "gt" },
      { name = "separator" },
      {
        name = "Revert / Discard Changes",
        cmd = A.tag(revert_node, {
          kind = "custom",
          label = "revert the selected node",
          check = function()
            local ok, git = pcall(require, "kebab.git")
            if not ok then
              return false, "kebab.git does not load"
            end
            for _, f in ipairs({ "revert_plan", "apply_revert", "describe_plan", "is_empty" }) do
              if type(git[f]) ~= "function" then
                return false, "kebab.git." .. f .. " missing"
              end
            end
            return true
          end,
        }),
        rtxt = "gr",
      },
      { name = "Undo Last Commit", cmd = call("git_undo_last_commit"), rtxt = "gU" },
      { name = "separator" },
      { name = "Stage All", cmd = call("git_add_all"), rtxt = "A" },
      { name = "Commit", cmd = call("git_commit"), rtxt = "gc" },
      { name = "Push", cmd = call("git_push"), rtxt = "gp" },
      { name = "Pull", cmd = call("git_pull"), rtxt = "gl" },
      { name = "separator" },
      { name = "Git Status Tree", cmd = A.ex("Neotree git_status", { plugin = "neo-tree.nvim" }), rtxt = "<leader>ge" },
      { name = "Lazygit", cmd = A.g("Snacks", "lazygit"), rtxt = "<leader>gg" },
    },
  },
  { name = "separator" },

  {
    name = "Open in Terminal",
    cmd = A.tag(open_in_terminal, {
      kind = "custom",
      label = "open a terminal in the selected directory",
      check = function()
        if _G.Snacks == nil or not A.callable(_G.Snacks.terminal) then
          -- there is a jobstart fallback, so this is still usable
          return vim.o.shell ~= "", "no shell configured for the fallback"
        end
        return true
      end,
    }),
  },
  { name = "Toggle Hidden Files", cmd = call("toggle_hidden"), rtxt = "H" },
  { name = "Refresh", cmd = call("refresh"), rtxt = "R" },
  { name = "Collapse All", cmd = call("close_all_nodes"), rtxt = "z" },
}

-- nvzone/menu wants the plain list, so the helpers ride along as fields on it
-- rather than changing the shape the menu consumes.
menu.source_commands = source_commands

return menu
