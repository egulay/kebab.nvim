-- The project tree behaves like a graphical IDE's project pane, and the
-- parameter hints LazyVim leaves switched off are turned on.
-- The always-on tree is registered from `init` below, which lazy.nvim runs
-- during setup -- before Neovim reads the file arguments, so the first
-- BufReadPost is not missed.
return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    init = function()
      require("kebab.explorer").setup()
    end,
    opts = {
      window = {
        width = 32,
        mappings = {
          -- Single left click expands/collapses a folder, the way the
          -- a graphical project pane does. Files still need <CR> or a
          -- double-click, so a stray click never opens a buffer.
          ["<LeftRelease>"] = function(state)
            local node = state.tree:get_node()
            if node and node.type == "directory" then
              require("neo-tree.sources.common.commands").toggle_node(state)
            end
          end,
          -- Git operations on the highlighted file. neo-tree only binds these
          -- in its git_status source by default, not in the file tree.
          ["ga"] = "git_add_file",
          ["gu"] = "git_unstage_file",
          ["gt"] = "git_toggle_file_stage",
          ["gr"] = "git_revert_file",
          ["gc"] = "git_commit",
          ["gp"] = "git_push",
          ["gl"] = "git_pull",
        },
      },
      filesystem = {
        -- keep the tree's selection on the file being edited
        follow_current_file = { enabled = true, leave_dirs_open = false },
        use_libuv_file_watcher = true,
        filtered_items = {
          visible = false,
          -- .env / .github / .gitlab-ci.yml should be visible; neo-tree hides
          -- dotfiles by default, which makes the tree look wrong next to it.
          hide_dotfiles = false,
          hide_gitignored = true,
          never_show = { ".git", "node_modules", ".DS_Store" },
        },
      },
    },
  },

  -- LazyVim's aerial extra loads on LazyFile only, so :AerialToggle does not
  -- exist until some file has been opened -- which makes "File Structure" dead
  -- in the Code and View menus when you come straight from the dashboard.
  -- A cmd trigger makes lazy.nvim stub the commands from startup.
  {
    "stevearc/aerial.nvim",
    cmd = { "AerialToggle", "AerialOpen", "AerialClose", "AerialNext", "AerialPrev", "AerialInfo", "AerialNavToggle" },
  },

  -- LazyVim ships signature help commented out. Parameter hints while you fill
  -- in a call matter on Spring/Mockito signatures.
  {
    "saghen/blink.cmp",
    opts = {
      signature = { enabled = true },
    },
  },
}
