-- Mouse-driven context menus, the closest terminal Neovim gets to a
-- graphical menu bar. Menu contents live in lua/menus/ide_editor.lua and ide_tree.lua.
return {
  { "nvzone/volt", lazy = true },
  {
    "nvzone/menu",
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
          require("menu").open(require(which), { mouse = true })
        end,
        mode = { "n", "v" },
        desc = "Context Menu",
      },
      {
        "<leader>M",
        function()
          require("menu").open(require("kebab.menus.editor"))
        end,
        desc = "Menu (File/Edit/Code/Run/Git/View)",
      },
    },
  },
}
