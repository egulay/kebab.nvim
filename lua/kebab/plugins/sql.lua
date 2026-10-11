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
    end,
    keys = {
      -- <leader>DD rather than <leader>D: the whole of <leader>d* belongs to
      -- the debugger (da/db/dc/dt/dp/de and a dozen more), so the database
      -- namespace has to be the shifted one, and a group prefix cannot also be
      -- a mapping. LazyVim's sql extra binds <leader>D to this directly; that
      -- override is declared in tests/spec/keymaps_spec.lua.
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
