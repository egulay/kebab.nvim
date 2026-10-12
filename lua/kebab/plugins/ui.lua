-- The project tree behaves like a graphical IDE's project pane, and the
-- parameter hints LazyVim leaves switched off are turned on.
--
-- `confirm` is on, which is what gives the "Save changes to ...?" dialog on
-- the way out of an edited buffer, and a yes/no question instead of a refusal
-- for anything else that would lose work. Without it `:q` on a modified
-- buffer answers `E37: No write since last change`, which is a wall, not a
-- question -- a graphical editor asks, and so should this. It applies to every
-- buffer, code and SQL alike, since it is an editor option rather than
-- anything this layer does per filetype.
vim.o.confirm = true
-- The always-on tree is registered from `init` below, which lazy.nvim runs
-- during setup -- before Neovim reads the file arguments, so the first
-- BufReadPost is not missed.
return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    -- Pinned: the layer overrides two of this plugin's nine git markers by
    -- name, reads its sources through neo-tree.command, and depends on
    -- get_state_for_window returning nil outside a tree window. Moving it:
    -- bump, then ./tests/run.sh -- menu_tree_spec is what notices.
    commit = "ffdf8d93c8db197a5cab072a18cc8da69d490b81", -- 2026-10-05
    init = function()
      require("kebab.explorer").setup()
    end,
    opts = {
      default_component_configs = {
        git_status = {
          -- Two of neo-tree's nine default markers are plain Unicode dingbats
          -- -- `added = "✚"` (U+271A) and `deleted = "✖"` (U+2716) -- and a
          -- Nerd Font does not carry those: the one on this machine has every
          -- other symbol it uses and neither of these. So a file an agent had
          -- just *added* rendered as a tofu box, which is exactly when you are
          -- looking at the tree. These two are Nerd Font glyphs instead,
          -- checked present with `fc-list :charset=F067`.
          symbols = {
            added = "", -- nf-fa-plus, U+F067
            deleted = "", -- nf-fa-minus, U+F068
          },
        },
      },
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
          ["gc"] = "git_commit",
          ["gp"] = "git_push",
          ["gl"] = "git_pull",
          -- Bound here because the right-click menu advertises them, and an
          -- advertised key that does something else is worse than none.
          --
          -- gr is this layer's revert, not neo-tree's git_revert_file: that
          -- one is a plain `git checkout HEAD -- <path>`, which ignores
          -- untracked files -- exactly the bug the menu entry exists to fix.
          ["gr"] = function()
            require("kebab.menus.tree").actions.revert()
          end,
          -- gA, not A: A is add_directory in the filesystem tree.
          ["gA"] = "git_add_all",
          -- gU is bound in neo-tree's git_status source only.
          ["gU"] = "git_undo_last_commit",
          ["gy"] = function()
            require("kebab.menus.tree").actions.copy_absolute_path()
          end,
          -- gY, not Y: LazyVim binds Y to the absolute path.
          ["gY"] = function()
            require("kebab.menus.tree").actions.copy_relative_path()
          end,
        },
      },
      filesystem = {
        -- Double clicking an image, a PDF or any other file the editor cannot
        -- show hands it to the desktop. The BufReadCmd in
        -- `kebab.openexternal` catches every other way of opening one (the
        -- picker, `nvim logo.png`, `gf`), but only by extension: a pattern has
        -- to be known before the file is seen. Here the path is in hand and
        -- nothing has read it, so the content sniff is a 1 KB read and catches
        -- the long tail -- a `.bin`, a `.dat`, a compiled artifact with no
        -- suffix at all.
        commands = require("kebab.openexternal").neotree_commands(),
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
