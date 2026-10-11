-- Named code-generation entries, the way a graphical IDE's Generate menu has
-- them -- BACKLOG.md item 2.
--
-- The actions already exist: jdtls exposes "generate constructor", "generate
-- getters and setters", "override methods" and the rest as LSP *source* code
-- actions. The problem was discoverability: they were buried inside
-- <leader>ca along with every quick-fix, so you had to know they were there
-- and read a long list to find them.
--
-- Each language declares its own in lua/kebab/languages/, so this file names no
-- language and no action kind.
local M = {}

local registry = require("kebab.registry")

---Generators offered for `filetype`.
---@param filetype string
---@return table[]
function M.for_filetype(filetype)
  local out = {}
  for _, gen in ipairs(registry.collect("codegen")) do
    if gen.filetypes == nil or vim.tbl_contains(gen.filetypes, filetype) then
      out[#out + 1] = gen
    end
  end
  return out
end

---Generators offered for a buffer.
function M.for_buffer(bufnr)
  return M.for_filetype(vim.bo[bufnr or 0].filetype)
end

---Ask the server for the code actions of `kind` available at the cursor.
---
---Asking rather than assuming matters: an action kind that the attached server
---does not implement would otherwise fail silently, and the generate actions
---are exactly the ones a user cannot tell apart from "nothing happened".
---@param kind string
---@param bufnr? number
---@param on_result fun(actions: table[], err: string|nil)
function M.available(kind, bufnr, on_result)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/codeAction" })
  if #clients == 0 then
    return on_result({}, "No language server attached to this buffer")
  end

  local params = vim.lsp.util.make_range_params(0, clients[1].offset_encoding or "utf-16")
  params.context = { diagnostics = {}, only = { kind } }

  local collected, pending = {}, #clients
  for _, client in ipairs(clients) do
    client:request("textDocument/codeAction", params, function(_, result)
      for _, action in ipairs(result or {}) do
        collected[#collected + 1] = action
      end
      pending = pending - 1
      if pending == 0 then
        on_result(collected, nil)
      end
    end, bufnr)
  end
end

---Run a generator.
---
---`vim.lsp.buf.code_action` with `only` narrowed to one kind is what turns a
---named menu entry into the specific action, instead of the full <leader>ca
---list. `apply = true` skips the picker when the server offers exactly one.
---@param generator table
---@param opts? { bufnr?: number }
function M.run(generator, opts)
  opts = opts or {}
  if not generator or not generator.kind then
    return vim.notify("codegen: nothing to run", vim.log.levels.WARN)
  end
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()

  if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
    return vim.notify(
      ("%s needs a language server; none is attached to this buffer"):format(generator.name),
      vim.log.levels.WARN)
  end

  vim.lsp.buf.code_action({
    context = { only = { generator.kind }, diagnostics = {} },
    apply = true,
  })
end

---Offer every generator available for this buffer.
---@param opts? { bufnr?: number }
function M.pick(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local generators = M.for_buffer(bufnr)
  if #generators == 0 then
    return vim.notify(
      ("Nothing to generate for %s"):format(vim.bo[bufnr].filetype == "" and "this buffer" or vim.bo[bufnr].filetype),
      vim.log.levels.WARN)
  end
  vim.ui.select(generators, {
    prompt = "Generate",
    format_item = function(g) return g.name end,
  }, function(choice)
    if choice then
      M.run(choice, { bufnr = bufnr })
    end
  end)
end

---Find a generator by name, case-insensitively, for `:IdeGenerate <name>`.
---@param name string
---@param bufnr? number
function M.by_name(name, bufnr)
  local needle = name:lower()
  local generators = M.for_buffer(bufnr)
  for _, g in ipairs(generators) do
    if g.name:lower() == needle then
      return g
    end
  end
  for _, g in ipairs(generators) do
    if g.name:lower():find(needle, 1, true) then
      return g
    end
  end
  return nil
end

function M.setup()
  vim.api.nvim_create_user_command("IdeGenerate", function(cmd)
    if cmd.args == "" then
      return M.pick()
    end
    local gen = M.by_name(cmd.args)
    if not gen then
      local names = vim.tbl_map(function(g) return g.name end, M.for_buffer())
      return vim.notify(
        ("No generator matching %q (have: %s)"):format(cmd.args, table.concat(names, ", ")),
        vim.log.levels.WARN)
    end
    M.run(gen)
  end, {
    nargs = "?",
    desc = "Generate code (constructor, getters, toString, …)",
    complete = function(lead)
      local out = {}
      for _, g in ipairs(M.for_buffer()) do
        if g.name:lower():find(lead:lower(), 1, true) then
          out[#out + 1] = g.name
        end
      end
      return out
    end,
  })
end

return M
