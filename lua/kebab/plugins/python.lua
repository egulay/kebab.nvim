-- Point basedpyright at the project's own virtualenv automatically, so
-- imports resolve without running <leader>cv first.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        basedpyright = {
          before_init = function(_, config)
            local root = config.root_dir
            if not root then
              return
            end
            for _, name in ipairs({ ".venv", "venv", ".env", "env" }) do
              local py = root .. "/" .. name .. "/bin/python"
              if vim.uv.fs_stat(py) then
                config.settings = config.settings or {}
                config.settings.python = vim.tbl_deep_extend(
                  "force",
                  config.settings.python or {},
                  { pythonPath = py }
                )
                return
              end
            end
          end,
        },
      },
    },
  },
}
