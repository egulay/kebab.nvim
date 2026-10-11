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
          local which = ft == "neo-tree" and "kebab.menus.tree" or "kebab.menus.editor"
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
