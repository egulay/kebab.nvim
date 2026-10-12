-- Language servers, debuggers, linters and formatters this layer expects.
--
-- Without this a fresh install has the plugins but no tooling, and every
-- language silently falls back to "no LSP attached".
--
-- The list is not written here: each language in lua/kebab/languages/ declares
-- the packages it needs, so adding a language cannot leave its language server
-- uninstalled by omission.
-- `KEBAB_MASON_ONLY` narrows the list, for a run that has to be repeatable.
--
-- The clean-machine check installs the layer and then runs the suite, and
-- `nvim --headless "+Lazy! sync" +qa` exits while mason is still working: it
-- says so -- "Neovim exited while the following packages were installing",
-- fourteen of them on one run. So *which* tools exist while the suite runs is
-- decided by what happened to finish in those few seconds, which differs by
-- run, machine and network. That is a flake generator, and it produced one: a
-- half-installed gopls that shadowed a working one, because mason prepends its
-- bin directory to PATH.
--
-- Emptying the list was the first attempt and it was worse: with mason
-- managing nothing, *nothing enables the language server* either, so eleven
-- specs waited out a 120s attach budget against a gopls that was sitting on
-- PATH unused. Deterministic and equipped are not opposites -- the fix is to
-- install a short, known list and wait for it, which `tests/ci/bootstrap.sh`
-- does.
--
--   KEBAB_MASON_ONLY unset   every tool the languages declare (the default)
--   KEBAB_MASON_ONLY=gopls   only that, so the wait is seconds
--
-- An *empty* value is the same as unset, and not by choice: `vim.env.X` reads
-- an empty variable as nil even when the shell exported it empty, which is the
-- same quirk that makes `$KEBAB_PROJECT_ROOTS=""` fall through to the
-- defaults.
return {
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      local only = vim.env.KEBAB_MASON_ONLY
      if only ~= nil then
        -- *Replaces* the list rather than adding to it. `opts` arrives
        -- carrying LazyVim's own extras' packages, so appending left delve,
        -- gofumpt, goimports, prettier, sqlfluff and friends installing --
        -- nine of them, still going when the editor exited -- while the one
        -- server the suite needs had been removed. A run that waits for mason
        -- has to be able to wait for a list it chose.
        local wanted = {}
        for name in only:gmatch("[^,%s]+") do
          wanted[#wanted + 1] = name
        end
        opts.ensure_installed = wanted
        return opts
      end
      vim.list_extend(opts.ensure_installed, require("kebab.registry").tools())
      return opts
    end,
  },
}
