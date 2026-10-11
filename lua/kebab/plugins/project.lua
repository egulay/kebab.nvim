-- Project create/open, wired to keys, the dashboard and which-key.
-- Logic lives in lua/kebab/project.lua.
--
-- <leader>p is free here because LazyVim only binds it in the yanky extra,
-- which is not enabled. Enabling coding.yanky later would collide.
return {
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      local keys = vim.tbl_get(opts, "dashboard", "preset", "keys")
      if keys then
        table.insert(keys, 1, { icon = " ", key = "p", desc = "Open Project", action = ":IdeOpenProject" })
        table.insert(keys, 2, { icon = " ", key = "N", desc = "New Project", action = ":IdeNewProject" })
      end
      return opts
    end,
  },
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>p", group = "project" },
        { "<leader>o", group = "task/run" },
      },
    },
  },
  {
    "LazyVim/LazyVim",
    init = function()
      require("kebab.project").setup()
      require("kebab.deps").setup()
      require("kebab.codegen").setup()
      require("kebab.templates").setup()
      require("kebab.scratch").setup()
      require("kebab.projectfiles").setup()
      require("kebab.runconfig").setup()
      require("kebab.follow").setup()
      require("kebab.cli").setup()
    end,
    keys = {
      { "<leader>po", "<cmd>IdeOpenProject<cr>", desc = "Open Project" },
      { "<leader>pn", "<cmd>IdeNewProject<cr>", desc = "New Project" },
      { "<leader>pr", function() require("persistence").load() end, desc = "Restore Session" },
      { "<leader>pk", "<cmd>IdeCheatsheet<cr>", desc = "Keymap Cheatsheet" },
      { "<leader>pD", "<cmd>IdeDoctor<cr>", desc = "Doctor" },
      { "<leader>pd", "<cmd>IdeAddDependency<cr>", desc = "Add Dependency" },
      { "<leader>cg", "<cmd>IdeGenerate<cr>", desc = "Generate Code" },
      -- <leader>fn is LazyVim's plain "New File" (:enew). Taking it would have
      -- silently broken existing muscle memory, so the template picker sits
      -- next to it on the shifted key.
      { "<leader>fN", "<cmd>IdeNewFile<cr>", desc = "New File from Template" },
      { "<leader>fS", "<cmd>IdeScratch<cr>", desc = "New Scratch File" },
      { "<leader>fs", "<cmd>IdeScratchList<cr>", desc = "Open Scratch File" },
      { "<leader>pf", "<cmd>IdeProjectFile<cr>", desc = "Generate Project File" },
      { "<leader>uf", "<cmd>IdeFollow<cr>", desc = "Toggle Follow External Edits" },
      { "<leader>or", "<cmd>IdeRunConfig<cr>", desc = "Run Configuration" },
      { "<leader>oe", "<cmd>IdeRunConfigEdit<cr>", desc = "Edit Run Configurations" },
    },
  },
}
