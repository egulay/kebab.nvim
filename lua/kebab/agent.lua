-- The non-interactive face of the semantic queries: what `kebab diagnostics`
-- and friends run.
--
-- Separate from kebab.lsp so the queries stay plain Lua tables that tests can
-- assert on, and all the rendering, exit codes and argument handling live in
-- one place.
local M = {}

local lsp = require("kebab.lsp")

M.COMMANDS = { "diagnostics", "definition", "references", "symbols", "hover" }

---Is `name` one of the commands?
function M.is_command(name)
  return vim.tbl_contains(M.COMMANDS, name)
end

-- ----------------------------------------------------------------- render

local function relative(file)
  return vim.fn.fnamemodify(file, ":~:.")
end

---Human-readable output. Locations are printed `file:line:col` so they are
---greppable and an editor can jump straight to them.
---@param command string
---@param result table
---@return string[]
function M.render_text(command, result)
  local lines = {}
  if command == "diagnostics" then
    for _, d in ipairs(result.diagnostics) do
      lines[#lines + 1] = ("%s:%d:%d: %s: %s%s"):format(
        relative(d.file), d.line, d.col, d.severity, d.message,
        d.source and (" [" .. d.source .. "]") or "")
    end
    if #lines == 0 then
      lines[#lines + 1] = ("%s: no diagnostics (%s)"):format(
        relative(result.file), table.concat(result.clients, ", "))
      if not result.settled then
        lines[#lines + 1] =
          "note: the server had not published anything yet; `kebab serve` keeps one warm"
      end
    end
  elseif command == "definition" or command == "references" then
    for _, l in ipairs(result.locations) do
      lines[#lines + 1] = ("%s:%d:%d"):format(relative(l.file), l.line, l.col)
    end
    if #lines == 0 then
      lines[#lines + 1] = "no " .. command .. " found"
    end
  elseif command == "symbols" then
    for _, s in ipairs(result.symbols) do
      lines[#lines + 1] = ("%s:%d:%d: %s%s (%s)%s"):format(
        relative(result.file), s.line, s.col, ("  "):rep(s.depth), s.name, s.kind,
        s.detail and ("  " .. s.detail) or "")
    end
    if #lines == 0 then
      lines[#lines + 1] = "no symbols found"
    end
  elseif command == "hover" then
    if result.text == "" then
      lines[#lines + 1] = "nothing to show here"
    else
      for line in (result.text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
      end
      while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
      end
    end
  end
  return lines
end

---Run a command and return its result, or nil plus a reason.
---@param command string
---@param args string[] the positional arguments after the command
---@param opts? table
function M.query(command, args, opts)
  opts = opts or {}
  args = args or {}
  if not M.is_command(command) then
    return nil, ("unknown command %q (have: %s)"):format(
      tostring(command), table.concat(M.COMMANDS, ", "))
  end

  local target = args[1]
  if target == nil or target == "" then
    return nil, command .. " needs a file" ..
      ((command == "diagnostics" or command == "symbols") and "" or " position (path:line:col)")
  end

  if command == "diagnostics" then
    return lsp.diagnostics(target, opts)
  elseif command == "symbols" then
    return lsp.symbols(target, opts)
  end

  local path, line, col, perr = lsp.parse_position(target)
  if not path then
    return nil, perr
  end
  if command == "definition" then
    return lsp.definition(path, line, col, opts)
  elseif command == "references" then
    return lsp.references(path, line, col, opts)
  elseif command == "hover" then
    return lsp.hover(path, line, col, opts)
  end
end

---Everything a caller needs: the rendered text and the exit code.
---
---The exit code reports whether the *query* worked, not what it found -- an
---agent asking "are there errors" wants the answer in the output, not a crash.
---`--exit-code` opts into failing on an error-severity diagnostic, which is the
---shape a pre-commit check wants. It has three outcomes, because "clean" and
---"the server never answered" must not look the same to a gate:
---
---  0  the file is clean, and the server said so
---  1  an error-severity diagnostic was reported
---  2  inconclusive -- nothing was published within the settle window
---
---Without `--exit-code` the code still only reports whether the *query* worked.
---@return string output, number code
function M.report(command, args, opts)
  opts = opts or {}
  local result, err = M.query(command, args, opts)
  if not result then
    local payload = opts.json
      and vim.json.encode({ ok = false, error = tostring(err) })
      or ("error: " .. tostring(err))
    return payload, 1
  end

  local code = 0
  if opts.exit_code and command == "diagnostics" then
    for _, d in ipairs(result.diagnostics) do
      if d.severity == "error" then
        code = 1
        break
      end
    end
    -- A gate must not read "nothing published yet" as "nothing wrong". This is
    -- the difference between a pre-commit hook that works and one that passes
    -- whenever the language server is cold.
    if code == 0 and not result.settled then
      code = 2
    end
  end

  if opts.json then
    local payload = vim.tbl_extend("keep", { ok = true, command = command }, result)
    return vim.json.encode(payload), code
  end
  return table.concat(M.render_text(command, result), "\n"), code
end

-- ------------------------------------------------------------------ remote
--
-- What a warm instance runs when `kebab --server <sock> …` asks it something.
-- Arguments arrive as one JSON string because it has to survive shell ->
-- VimScript -> Lua quoting, and JSON is the only encoding all three agree on.

---@param payload string JSON: { command, args, opts }
---@return string the exit code on the first line, then the output
---
---Not JSON on the way back: the caller would need a JSON parser to read it, and
---the only structured field is a number. A code on the first line means one RPC
---round trip and no parser -- and the output may itself be JSON, which nesting
---would only have to be unwrapped again.
function M.remote(payload)
  local ok, request = pcall(vim.json.decode, payload)
  if not ok or type(request) ~= "table" then
    return "2\nerror: malformed request"
  end
  local okr, output, code = pcall(M.report, request.command, request.args, request.opts)
  if not okr then
    return "1\nerror: " .. tostring(output)
  end
  return tostring(code) .. "\n" .. output
end

---The entry point for a one-shot invocation. Prints and quits.
---@param command string
---@param args string[]
---@param opts table
function M.main(command, args, opts)
  local output, code = M.report(command, args, opts)
  io.write(output .. "\n")
  vim.cmd(code == 0 and "qa!" or ("cq " .. code))
end

return M
