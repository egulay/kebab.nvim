-- The SQL IDE.
--
-- LazyVim's sql extra gives vim-dadbod, dadbod-ui and dadbod-completion, all of
-- which shell out to a *native* client -- so a database you have no psql or
-- mysql binary for does not work at all. kebab.jdbc adds a dadbod adapter that
-- speaks JDBC with a driver downloaded from Maven Central, which is how
-- a dedicated database IDE does it, and autoload/db/adapter/jdbc.vim is what
-- makes :DB, :DBUI
-- and completion all go through it unchanged.
--
-- Completion gets a second source. Measured against a live database,
-- vim-dadbod-completion offers a table-name prefix and a column through an
-- alias, but not the bare table list and not `customers.` -> its columns. Since
-- kebab.jdbc already has the whole schema from DatabaseMetaData, kebab.dbcomplete
-- answers from that, with each column's type beside it.
return {
  {
    "tpope/vim-dadbod",
    -- The adapter and the connection store have to exist before the first
    -- :DB, and the store is what dadbod-ui reads for its connection list.
    init = function()
      require("kebab.db").setup()
    end,
  },

  {
    "kristijanhusak/vim-dadbod-ui",
    init = function()
      -- Open the result of clicking a table immediately, the way a database IDE
      -- shows you rows rather than a query you then have to run.
      vim.g.db_ui_execute_on_save = false
      vim.g.db_ui_auto_execute_table_helpers = 1
      vim.g.db_ui_show_database_icon = true
      vim.g.db_ui_use_nerd_fonts = true
      vim.g.db_ui_use_nvim_notify = true
      vim.g.db_ui_win_position = "left"
      vim.g.db_ui_winwidth = 36
      -- Query buffers belong with the rest of this layer's state, not in a
      -- project directory where they could be committed.
      local data = vim.fn.stdpath("data")
      vim.g.db_ui_save_location = data .. "/kebab/sql/queries"
      vim.g.db_ui_tmp_query_location = data .. "/kebab/sql/tmp"

      -- A double click opens the node under the pointer.
      --
      -- dadbod-ui maps <CR> and `o` and nothing else: it has no mouse support
      -- at all. This layer is explicitly for keyboard *and* mouse users, and
      -- without this the explorer is dead to a mouse -- clicking a connection
      -- does nothing, which is not what anyone arriving from a graphical IDE
      -- will read as "no mouse support".
      --
      -- The <LeftMouse> prefix is load-bearing: it is what moves the cursor to
      -- the clicked line before the action runs. Without it the action applies
      -- to wherever the cursor happened to be. `remap` likewise -- <Plug>
      -- mappings do not fire from a noremap rhs.
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("kebab_dbui_mouse", { clear = true }),
        pattern = "dbui",
        callback = function(ev)
          -- <LeftMouse> first so the cursor lands on the clicked line, then
          -- kebab's own handler: a table opens in the three-pane layout (the
          -- statement top right, its rows under it), and anything else falls
          -- through to dadbod-ui's own action. dadbod-ui on its own expands a
          -- table into a "List" child you then have to click, and puts the
          -- result wherever it likes.
          vim.keymap.set("n", "<2-LeftMouse>", function()
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<LeftMouse>", true, false, true), "n", false)
            -- after the click has been processed, so the cursor is on the
            -- clicked line rather than wherever it was
            vim.schedule(function()
              require("kebab.dbide").click()
            end)
          end, { buffer = ev.buf, desc = "Open the node under the pointer" })
        end,
      })
    end,
    -- A spec with only `keys` owns commands that do not exist until the key is
    -- pressed, so `nvim -c DBUI` -- which is what `kebab db` runs -- failed
    -- with "Not an editor command". Declaring them makes lazy stub them from
    -- startup. Same trap as AerialToggle and the Flutter entries.
    cmd = { "DBUI", "DBUIToggle", "DBUIAddConnection", "DBUIFindBuffer", "DBUILastQueryInfo" },
    keys = {
      -- <leader>DD rather than <leader>D: the whole of <leader>d* belongs to
      -- the debugger (da/db/dc/dt/dp/de and a dozen more), so the database
      -- namespace has to be the shifted one, and a group prefix cannot also be
      -- a mapping. LazyVim's sql extra binds <leader>D to this directly; that
      -- override is declared in tests/spec/keymaps_spec.lua.
      --
      -- `false` is how lazy.nvim *removes* an inherited key. Declaring
      -- <leader>DD alone does not take <leader>D away -- lazy merges `keys`
      -- lists rather than replacing them -- so <leader>D stayed a live
      -- DBUIToggle mapping as well as the group prefix. Pressing <leader>Dt at
      -- typing speed then toggled the DB explorer and swallowed the `t`,
      -- because which-key runs a node that is both a keymap and a group.
      { "<leader>D", false },
      { "<leader>DD", "<cmd>DBUIToggle<cr>", desc = "Database Explorer" },
    },
  },

  -- The schema-backed completion source, alongside dadbod's own.
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      opts.sources = opts.sources or {}
      opts.sources.default = opts.sources.default or {}
      if not vim.tbl_contains(opts.sources.default, "kebab_db") then
        table.insert(opts.sources.default, "kebab_db")
      end
      opts.sources.providers = opts.sources.providers or {}
      opts.sources.providers.kebab_db = {
        name = "DB",
        module = "kebab.dbcomplete",
        -- Above dadbod's source: when both answer, the one that knows the
        -- column's type should win.
        score_offset = 5,
      }
      return opts
    end,
  },

  {
    "LazyVim/LazyVim",
    keys = {
      { "<leader>Da", "<cmd>IdeDbAdd<cr>", desc = "Add Connection" },
      { "<leader>Dc", "<cmd>IdeDbConnect<cr>", desc = "Attach Connection to Buffer" },
      { "<leader>Dt", "<cmd>IdeDbTables<cr>", desc = "Browse Tables" },
      { "<leader>Dq", "<cmd>IdeDbConsole<cr>", desc = "New SQL Console" },
      { "<leader>Dp", "<cmd>IdeDbPing<cr>", desc = "Test Connection" },
      { "<leader>De", "<cmd>IdeDbEdit<cr>", desc = "Edit Connections File" },
    },
  },

  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>D", group = "database" },
      },
    },
  },
}
