-- Mouse-driven context menus, the closest terminal Neovim gets to a
-- graphical menu bar. Menu contents live in lua/menus/ide_editor.lua and ide_tree.lua.
-- Pinned, because this layer depends on how the plugin *behaves*, not only on
-- its public surface: `menu.open` is handed a list and iterates it, which is
-- why a helper parked on that list once stopped every menu from opening at
-- all. A floor cannot be expressed -- neither repo publishes tags -- so the
-- commit is pinned and `tests/spec/menu_open_spec.lua` is what says whether a
-- newer one still works. To move it: bump the commit, run ./tests/run.sh, and
-- run ./tests/pty/run.sh for the mouse paths.
local MENU_COMMIT = "7a0a4a2896b715c066cfbe320bdc048091874cc6" -- 2025-06-01
local VOLT_COMMIT = "620de1321f275ec9d80028c68d1b88b409c0c8b1" -- 2025-09-13

return {
  { "nvzone/volt", lazy = true, commit = VOLT_COMMIT },
  {
    "nvzone/menu",
    commit = MENU_COMMIT,
    dependencies = { "nvzone/volt" },
    keys = {
      {
        "<RightMouse>",
        function()
          require("menu.utils").delete_old_menus()
          -- move the cursor to where the click landed before building the menu
          vim.cmd.exec('"normal! \\<RightMouse>"')
          local winid = vim.fn.getmousepos().winid
          local ft = winid ~= 0 and vim.bo[vim.api.nvim_win_get_buf(winid)].filetype or ""
          -- A SQL buffer gets Run at the top level rather than two levels
          -- down under "Database", which is not where anyone looks after
          -- editing a query. The rows pane gets it too: that is where you are
          -- when you want the next page.
          -- The data source tree gets its own menu, because every entry
          -- there is about the node under the pointer: right-clicking a table
          -- and being offered "Browse Tables..." -- which then asks which
          -- table -- is the editor menu being shown in the wrong place.
          local SQL = { sql = true, dbout = true, mysql = true, plsql = true }
          local which = ft == "neo-tree" and "kebab.menus.tree"
            or (ft == "dbui" and "kebab.menus.dbtree")
            or (SQL[ft] and "kebab.menus.sql")
            or "kebab.menus.editor"
          -- watch for the windows this opens, so an action can close them
          -- even after the plugin has wiped their buffers out from under them
          require("kebab.menus.action").watch(which)
          require("menu").open(require(which), { mouse = true })
        end,
        mode = { "n", "v" },
        desc = "Context Menu",
      },
      {
        "<leader>M",
        function()
          require("kebab.menus.action").watch("kebab.menus.editor")
          require("menu").open(require("kebab.menus.editor"))
        end,
        desc = "Menu (File/Edit/Code/Run/Git/View)",
      },
    },
  },
}
