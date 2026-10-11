-- Language servers, debuggers, linters and formatters this layer expects.
--
-- Without this a fresh install has the plugins but no tooling, and every
-- language silently falls back to "no LSP attached".
--
-- The list is not written here: each language in lua/kebab/languages/ declares
-- the packages it needs, so adding a language cannot leave its language server
-- uninstalled by omission.
return {
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, require("kebab.registry").tools())
      return opts
    end,
  },
}
