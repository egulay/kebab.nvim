-- Language servers, debuggers, linters and formatters this layer expects.
--
-- Without this a fresh install has the plugins but no tooling, and every
-- language silently falls back to "no LSP attached".
--
-- The list is not written here: each language in lua/kebab/languages/ declares
-- the packages it needs, so adding a language cannot leave its language server
-- uninstalled by omission.
-- `KEBAB_NO_MASON_INSTALL=1` leaves the list empty, for a run that must be
-- deterministic rather than well equipped.
--
-- The clean-machine check (tests/ci) installs the layer and then runs the
-- suite, and `nvim --headless "+Lazy! sync" +qa` exits while mason is still
-- working: it says so -- "Neovim exited while the following packages were
-- installing", fourteen of them on the last run. So *which* tools exist while
-- the suite runs depends on what happened to finish in those few seconds,
-- which differs by run, machine and network. That is a flake generator, and
-- it produced a real one: a half-installed gopls that shadowed a working one,
-- because mason prepends its bin directory to PATH.
--
-- A test environment therefore installs its own tooling (CI installs Go,
-- gopls, Node, a JDK, a Rust toolchain system-wide) and turns this off. The
-- specs that need a tool then either run against a real one or skip with a
-- reason -- never against a stub.
return {
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      if vim.env.KEBAB_NO_MASON_INSTALL == "1" then
        return opts
      end
      vim.list_extend(opts.ensure_installed, require("kebab.registry").tools())
      return opts
    end,
  },
}
