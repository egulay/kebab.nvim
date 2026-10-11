-- Run/debug configurations and build tasks.
--
-- overseer supplies the task list and runner. The configurations themselves are
-- declared by each language in lua/kebab/languages/ and collected by the
-- registry, so adding Go's `go test ./...` is part of adding Go rather than a
-- separate edit here.
--
-- A project's own .vscode/launch.json needs no wiring: nvim-dap registers a
-- "dap.launch.json" config provider that reads it on demand and offers every
-- entry at pick time. This file used to call dap.ext.vscode.load_launchjs with
-- a type-to-filetype map, which is now deprecated -- and warned about on every
-- single startup. The map is obsolete too: it only mattered when configs were
-- copied into dap.configurations[filetype] up front.
return {
  {
    "stevearc/overseer.nvim",
    opts = function(_, opts)
      opts.templates = opts.templates or { "builtin" }
      return opts
    end,
    config = function(_, opts)
      local overseer = require("overseer")
      overseer.setup(opts)

      ---The task definition overseer gets, minus how it is gated.
      local function template_for(task)
        return {
          name = task.name,
          desc = task.desc,
          builder = function()
            -- cmd may be a function: ./mvnw vs mvn is only knowable now, and
            -- "%:p" has to mean the file open at the time the task is run.
            local cmd = type(task.cmd) == "function" and task.cmd() or vim.deepcopy(task.cmd)
            local args = vim.tbl_map(function(a)
              return a == "%:p" and vim.fn.expand("%:p") or a
            end, task.args or {})
            return { cmd = cmd, args = args, components = { "default" } }
          end,
        }
      end

      local markers_of = require("kebab.run").markers_of

      -- Per-project configurations from .kebab/run.json, as a provider so the
      -- file is re-read on each search: editing it takes effect without a
      -- restart, and switching project picks up the new one.
      overseer.register_template(require("kebab.runconfig").provider())

      -- Filetype gating overseer does itself; marker gating it does not.
      --
      -- `condition = { callback = fn }` is silently ignored -- overseer's
      -- condition_matches only understands filetype, dir and tags -- so every
      -- marker-gated task was offered in every project: `./mvnw test` in a Go
      -- repo, `cargo run` in a Spring one. Marker-gated tasks go through a
      -- provider instead, which is also the only way to test the real
      -- directory at search time rather than Neovim's cwd at startup.
      local marker_tasks = {}
      for _, task in ipairs(require("kebab.registry").tasks()) do
        if task.filetypes then
          local tmpl = template_for(task)
          tmpl.condition = { filetype = task.filetypes }
          overseer.register_template(tmpl)
        elseif markers_of(task) then
          marker_tasks[#marker_tasks + 1] = task
        else
          -- no marker and no filetype: it applies anywhere
          overseer.register_template(template_for(task))
        end
      end

      overseer.register_template(require("kebab.run").marker_provider(marker_tasks, template_for))
    end,
  },
}
