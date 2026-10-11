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

      ---A task is offered when its marker file is in the project root, or when
      ---the buffer's filetype matches. Without a condition every language's
      ---tasks would show in every project.
      local function condition_for(task)
        if task.filetypes then
          return { filetype = task.filetypes }
        end
        local markers = task.marker
        if markers == nil then
          return nil
        end
        if type(markers) == "string" then
          markers = { markers }
        end
        return {
          callback = function()
            for _, m in ipairs(markers) do
              if vim.fn.filereadable(m) == 1 then
                return true
              end
            end
            return false
          end,
        }
      end

      -- Per-project configurations from .kebab/run.json, as a provider so the
      -- file is re-read on each search: editing it takes effect without a
      -- restart, and switching project picks up the new one.
      overseer.register_template(require("kebab.runconfig").provider())

      for _, task in ipairs(require("kebab.registry").tasks()) do
        overseer.register_template({
          name = task.name,
          desc = task.desc,
          priority = task.priority or 10,
          condition = condition_for(task),
          builder = function()
            -- cmd may be a function: ./mvnw vs mvn is only knowable now, and
            -- "%:p" has to mean the file open at the time the task is run.
            local cmd = type(task.cmd) == "function" and task.cmd() or vim.deepcopy(task.cmd)
            local args = vim.tbl_map(function(a)
              return a == "%:p" and vim.fn.expand("%:p") or a
            end, task.args or {})
            return { cmd = cmd, args = args, components = { "default" } }
          end,
        })
      end
    end,
  },
}
