-- Semantic queries, for a caller that is not a person.
--
-- An agent working in a repository already has file I/O, grep and a shell. What
-- it cannot get from those is what the language server knows: where a symbol is
-- defined, who calls it, and whether the last edit introduced an error. This
-- exposes exactly that, as plain Lua tables that kebab.agent renders as JSON.
--
-- Read-only on purpose. Nothing here writes to the working tree, so an agent
-- driving it unattended cannot damage the repository.
local M = {}

-- LSP severities are 1-4; a name is far more useful to whatever reads the JSON.
local SEVERITY = { "error", "warn", "info", "hint" }

-- Reverse of vim.lsp.protocol.SymbolKind, which maps both ways and so cannot be
-- indexed numerically without care.
local function symbol_kind(n)
  local kinds = vim.lsp.protocol.SymbolKind
  for name, value in pairs(kinds) do
    if value == n and type(name) == "string" then
      return name
    end
  end
  return tostring(n)
end

---How long to wait for things, all overridable per call.
local function timeouts(opts)
  opts = opts or {}
  return {
    attach = opts.attach_timeout or 120000,
    -- A cold gopls or jdtls does not publish within 1.5s, and an unsettled
    -- result is reported as inconclusive rather than clean -- so this being
    -- generous costs a slow answer, where being mean costs a wrong one.
    settle = opts.settle or 5000,
    -- how long the diagnostic set has to stop changing before it is believed
    quiet = opts.quiet or 500,
    request = opts.request_timeout or 20000,
  }
end

---A diagnostic set, compared cheaply so "did it change" is answerable.
---@param list table[]
local function signature(list)
  local parts = {}
  for _, d in ipairs(list) do
    parts[#parts + 1] = table.concat({
      tostring(d.lnum),
      tostring(d.col),
      tostring(d.severity),
      tostring(d.message or ""),
    }, "\30")
  end
  table.sort(parts)
  return table.concat(parts, "\31")
end

---Wait until the diagnostics for `bufnr` have stopped changing.
---
---A language server publishes what it knows early and refines it, so the first
---set that arrives can be missing the diagnostic the caller came for.
---@param bufnr number
---@param first table[] the set already in hand
---@param t table timeouts
---@return table[] diagnostics
function M.stable_diagnostics(bufnr, first, t)
  local diags = first
  local sig = signature(diags)
  local stable_for = 0
  local deadline = vim.uv.now() + (t.settle or 5000)
  local step = 100
  while vim.uv.now() < deadline do
    vim.wait(step, function()
      return false
    end, 20)
    local now = vim.diagnostic.get(bufnr)
    local now_sig = signature(now)
    if now_sig == sig then
      stable_for = stable_for + step
      if stable_for >= (t.quiet or 500) then
        return now
      end
    else
      diags, sig, stable_for = now, now_sig, 0
    end
  end
  return vim.diagnostic.get(bufnr)
end

-- Buffers this module loaded, so only those are unloaded again.
local opened_by_us = {}

---An argument turned into an absolute path.
---
---Named separately so the path handling can be tested without opening a file.
---@param path string
---@return string absolute
function M.resolve_path(path)
  -- kebab.path.expand, not vim.fn.expand: the latter runs the shell for
  -- anything in backticks, and this path comes from a command line.
  return vim.fn.fnamemodify(require("kebab.path").expand(path), ":p")
end

---Open `path` and wait for a language server to attach to it.
---
---Reporting "no language server attached" rather than an empty result is the
---whole point: an agent must be able to tell "no errors" from "could not
---check".
---@param path string
---@param opts? table
---@return number|nil bufnr, string|nil err
function M.open(path, opts)
  local t = timeouts(opts)
  local full = M.resolve_path(path)
  local stat = vim.uv.fs_stat(full)
  if not stat then
    return nil, "no such file: " .. path
  end
  if stat.type == "directory" then
    -- fs_stat happily accepts one, and nothing would ever attach to it: a
    -- 120-second block and a permanent buffer for a certain failure.
    return nil, "not a file: " .. path
  end

  -- Whether *we* loaded it decides whether we may unload it afterwards. In the
  -- long-lived `kebab serve` instance every query used to add a loaded buffer
  -- and a didOpen'd document for good -- a few thousand files, a few thousand
  -- buffers -- and the failure path left one behind too.
  local existing = vim.fn.bufnr(full)
  local was_loaded = existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) == true
  local previous = vim.api.nvim_get_current_buf()

  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(full))
  if not ok then
    return nil, "could not open " .. path .. ": " .. tostring(err)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if not was_loaded then
    -- `previous` is where to step back to before unloading: :edit puts the
    -- queried file in the *current* window, so it is always visible and a
    -- plain "is it visible?" guard would refuse every release.
    opened_by_us[bufnr] = { previous = previous }
  end

  if not vim.wait(t.attach, function()
    return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
  end, 50) then
    M.release(bufnr)
    return nil, ("no language server attached to %s within %dms"):format(path, t.attach)
  end
  return bufnr
end

---Unload a buffer this module loaded, leaving one the user had alone.
---
---Called at the end of every query so a warm instance does not accumulate a
---buffer per file queried. A buffer that is on screen is never touched.
---@param bufnr number|nil
function M.release(bufnr)
  local info = bufnr and opened_by_us[bufnr]
  if not info then
    return false
  end
  opened_by_us[bufnr] = nil
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.api.nvim_get_current_buf() == bufnr then
    if info.previous and vim.api.nvim_buf_is_valid(info.previous) then
      pcall(vim.api.nvim_set_current_buf, info.previous)
    else
      pcall(vim.cmd, "enew")
    end
  end
  if vim.fn.bufwinid(bufnr) ~= -1 then
    -- still on screen somewhere else: someone is looking at it
    return false
  end
  return pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

---The attached clients' names, for reporting.
function M.clients(bufnr)
  local names = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    names[#names + 1] = c.name
  end
  table.sort(names)
  return names
end

-- ------------------------------------------------------------- diagnostics

---Diagnostics for a file.
---
---Caveat worth knowing: a clean file and a file whose server has not finished
---publishing look the same inside the settle window. `settled` says which
---happened, and a warm instance (`kebab serve`) makes the question moot because
---the server has already indexed.
---@param path string
---@param opts? table
---@return table|nil result, string|nil err
function M.diagnostics(path, opts)
  local t = timeouts(opts)
  local bufnr, err = M.open(path, opts)
  if not bufnr then
    return nil, err
  end

  -- Wait for diagnostics to arrive, but do not insist: a clean file never
  -- produces any.
  --
  -- Two races had to be closed here, both of which reported a file holding a
  -- compile error as clean *and* settled -- the worst possible answer for a
  -- gate. They showed up as a one-in-three flake in the suite.
  --
  --   1. The list was read twice: once in the wait predicate, once to build
  --      the result. A server republishing a file clears the set and sets it
  --      again, so the second read could land in the gap. The list is now
  --      kept from the predicate.
  --   2. The first publish is not the last. gopls announces what it has early
  --      and refines it, so stopping at "non-empty" could return a set that
  --      did not yet hold the compile error. So after the first publish, wait
  --      for the set to stop changing.
  local diags = vim.diagnostic.get(bufnr)
  local settled = #diags > 0
  if not settled then
    settled = vim.wait(t.settle, function()
      diags = vim.diagnostic.get(bufnr)
      return #diags > 0
    end, 50)
  end
  if settled then
    diags = M.stable_diagnostics(bufnr, diags, t)
  else
    -- one last look, for the genuinely clean case
    diags = vim.diagnostic.get(bufnr)
  end

  local out = {}
  for _, d in ipairs(diags) do
    out[#out + 1] = {
      file = vim.api.nvim_buf_get_name(bufnr),
      line = d.lnum + 1,
      col = d.col + 1,
      end_line = (d.end_lnum or d.lnum) + 1,
      end_col = (d.end_col or d.col) + 1,
      severity = SEVERITY[d.severity] or tostring(d.severity),
      source = d.source,
      code = d.code and tostring(d.code) or nil,
      message = d.message,
    }
  end
  table.sort(out, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.col < b.col
  end)
  local answer = {
    file = vim.api.nvim_buf_get_name(bufnr),
    clients = M.clients(bufnr),
    settled = settled or #out > 0,
    count = #out,
    diagnostics = out,
  }
  M.release(bufnr)
  return answer
end

-- ------------------------------------------------------------- positions

---Ask one request of every attached client and gather the answers.
---
---`params_for` may be a table (the same params for every client) or a function
---of the client, which is what differing offset encodings require: a buffer
---commonly has two clients with different encodings -- basedpyright utf-16 and
---ruff utf-8 on every Python file here -- and sending one client's byte column
---to the other resolves the wrong symbol.
---@param bufnr number
---@param method string
---@param params_for table|fun(client: table): table
---@param timeout number
---@return table[] results, string|nil err
local function request_all(bufnr, method, params_for, timeout)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  if #clients == 0 then
    return {}, ("no attached language server implements %s"):format(method)
  end
  local collected, pending, failed = {}, #clients, nil
  local refused = {}
  for _, client in ipairs(clients) do
    local params = type(params_for) == "function" and params_for(client) or params_for
    -- The boolean matters. A client whose RPC channel has closed is still
    -- handed back by get_clients -- client objects leave lsp.client._all only
    -- after two nested vim.schedules -- and request() then returns false
    -- without ever calling the handler. Ignoring that left `pending` stuck, so
    -- every query cost the full 20s timeout and then blamed the server for
    -- being slow, even when a healthy client had answered in 30ms.
    local sent = client:request(method, params, function(rerr, result)
      if rerr then
        failed = tostring(rerr.message or rerr)
      elseif result ~= nil then
        collected[#collected + 1] = result
      end
      pending = pending - 1
    end, bufnr)
    if sent == false then
      pending = pending - 1
      refused[#refused + 1] = client.name
    end
  end
  if not vim.wait(timeout, function()
    return pending == 0
  end, 20) then
    return collected, "the language server did not answer in time"
  end
  if #collected == 0 and #refused > 0 and not failed then
    return collected, ("%s rejected the request (the client is shutting down?)"):format(
      table.concat(refused, ", ")
    )
  end
  return collected, failed
end

---One line of a file, from a loaded buffer when there is one.
---
---`cache` is per call: a references result commonly holds dozens of hits in
---one file, and re-reading it for each would be silly.
---@param path string
---@param line1 number 1-based
---@param cache table
local function line_text(path, line1, cache)
  local lines = cache[path]
  if lines == nil then
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    else
      local ok, read = pcall(vim.fn.readfile, path)
      lines = ok and read or false
    end
    cache[path] = lines
  end
  if not lines then
    return nil
  end
  return lines[line1]
end

---An LSP character offset turned into a 1-based *byte* column.
---
---The raw `character + 1` is in the server's offset encoding, so on a line
---with non-ASCII before the symbol it is neither a byte column nor valid input
---to kebab's own commands -- and it disagreed with the columns `diagnostics`
---reports for the same file, which are byte-based. Feeding this tool's own
---output back into it pointed at the wrong token.
---@param path string
---@param line1 number 1-based line
---@param character number LSP character offset
---@param encoding string "utf-8" | "utf-16" | "utf-32"
---@param cache table
---@return number col 1-based byte column
local function byte_col(path, line1, character, encoding, cache)
  character = tonumber(character) or 0
  if character <= 0 then
    return 1
  end
  if encoding == "utf-8" then
    return character + 1
  end
  local text = line_text(path, line1, cache)
  if type(text) ~= "string" then
    return character + 1
  end
  local ok, byte = pcall(vim.str_byteindex, text, encoding, character, false)
  if ok and type(byte) == "number" then
    return byte + 1
  end
  -- An offset past the end of the line is not an error worth failing a query
  -- for; clamp rather than refuse.
  return math.min(character + 1, #text + 1)
end

---Flatten whatever shape a location response takes into a list.
---@param results table[]
---@param encoding string the offset encoding the answering client used
local function locations(results, encoding)
  local out = {}
  local cache = {}
  local function add(item)
    if type(item) ~= "table" then
      return
    end
    local uri = item.uri or item.targetUri
    local range = item.range or item.targetSelectionRange or item.targetRange
    if not uri or not range then
      return
    end
    local file = vim.uri_to_fname(uri)
    local line1 = range.start.line + 1
    local end_line1 = range["end"].line + 1
    out[#out + 1] = {
      file = file,
      line = line1,
      col = byte_col(file, line1, range.start.character, encoding, cache),
      end_line = end_line1,
      end_col = byte_col(file, end_line1, range["end"].character, encoding, cache),
    }
  end
  for _, result in ipairs(results) do
    -- a single Location, or a list of them
    if result.uri or result.targetUri then
      add(result)
    else
      for _, item in ipairs(result) do
        add(item)
      end
    end
  end
  return out
end

---The offset encoding to interpret a response with.
---
---Every client implementing the method, which in practice is one: the two-client
---case here is basedpyright (utf-16) plus ruff (utf-8), and only basedpyright
---answers definition/references/hover/documentSymbol.
---@param bufnr number
---@param method string
local function response_encoding(bufnr, method)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  return (clients[1] and clients[1].offset_encoding) or "utf-16"
end

---Position params for a 1-based line and column, which is what a person and a
---command line use; LSP counts from zero.
---
---Returns a function of the client, so each one is sent a position in its own
---offset encoding.
local function position_params(bufnr, line, col)
  local count = vim.api.nvim_buf_line_count(bufnr)
  line = math.max(1, math.min(tonumber(line) or 1, count))
  col = math.max(1, tonumber(col) or 1)
  -- make_position_params reads the cursor, so put it where we were asked
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    vim.api.nvim_set_current_buf(bufnr)
    win = vim.api.nvim_get_current_win()
  end
  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, win, { line, math.min(col - 1, #text) })
  return function(client)
    return vim.lsp.util.make_position_params(win, (client and client.offset_encoding) or "utf-16")
  end
end

---Where the symbol at a position is defined.
function M.definition(path, line, col, opts)
  local t = timeouts(opts)
  local bufnr, err = M.open(path, opts)
  if not bufnr then
    return nil, err
  end
  local params = position_params(bufnr, line, col)
  local results, rerr = request_all(bufnr, "textDocument/definition", params, t.request)
  local found = locations(results, response_encoding(bufnr, "textDocument/definition"))
  local clients = M.clients(bufnr)
  M.release(bufnr)
  if #found == 0 and rerr then
    return nil, rerr
  end
  return { query = { file = path, line = tonumber(line), col = tonumber(col) },
    clients = clients, count = #found, locations = found }
end

---Everywhere the symbol at a position is used.
function M.references(path, line, col, opts)
  opts = opts or {}
  local t = timeouts(opts)
  local bufnr, err = M.open(path, opts)
  if not bufnr then
    return nil, err
  end
  local base = position_params(bufnr, line, col)
  local params = function(client)
    local p = base(client)
    p.context = { includeDeclaration = opts.include_declaration ~= false }
    return p
  end
  local results, rerr = request_all(bufnr, "textDocument/references", params, t.request)
  local found = locations(results, response_encoding(bufnr, "textDocument/references"))
  local clients = M.clients(bufnr)
  M.release(bufnr)
  if #found == 0 and rerr then
    return nil, rerr
  end
  table.sort(found, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.col < b.col
  end)
  return { query = { file = path, line = tonumber(line), col = tonumber(col) },
    clients = clients, count = #found, locations = found }
end

-- ----------------------------------------------------------------- symbols

---@param ctx table { path, encoding, cache } so columns come out as bytes
local function flatten_symbols(items, out, depth, ctx)
  out = out or {}
  depth = depth or 0
  for _, item in ipairs(items or {}) do
    local range = item.selectionRange or item.range
      or (item.location and item.location.range)
    if range then
      local line1 = range.start.line + 1
      out[#out + 1] = {
        name = item.name,
        kind = symbol_kind(item.kind),
        detail = item.detail,
        depth = depth,
        line = line1,
        -- bytes, like the columns `diagnostics` reports, so one tool does not
        -- answer in two different coordinate systems
        col = byte_col(ctx.path, line1, range.start.character, ctx.encoding, ctx.cache),
      }
    end
    if item.children then
      flatten_symbols(item.children, out, depth + 1, ctx)
    end
  end
  return out
end

---The outline of a file: what is in it and where.
function M.symbols(path, opts)
  local t = timeouts(opts)
  local bufnr, err = M.open(path, opts)
  if not bufnr then
    return nil, err
  end
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local results, rerr = request_all(bufnr, "textDocument/documentSymbol", params, t.request)
  local out = {}
  local ctx = {
    path = vim.api.nvim_buf_get_name(bufnr),
    encoding = response_encoding(bufnr, "textDocument/documentSymbol"),
    cache = {},
  }
  for _, result in ipairs(results) do
    flatten_symbols(result, out, 0, ctx)
  end
  local name, clients = vim.api.nvim_buf_get_name(bufnr), M.clients(bufnr)
  M.release(bufnr)
  if #out == 0 and rerr then
    return nil, rerr
  end
  return { file = name, clients = clients, count = #out, symbols = out }
end

-- ------------------------------------------------------------------- hover

---What the server says about the symbol at a position: its type, its docs.
function M.hover(path, line, col, opts)
  local t = timeouts(opts)
  local bufnr, err = M.open(path, opts)
  if not bufnr then
    return nil, err
  end
  local params = position_params(bufnr, line, col)
  local results, rerr = request_all(bufnr, "textDocument/hover", params, t.request)
  local chunks = {}
  for _, result in ipairs(results) do
    local contents = result.contents
    if type(contents) == "string" then
      chunks[#chunks + 1] = contents
    elseif type(contents) == "table" then
      if contents.value then
        chunks[#chunks + 1] = contents.value
      else
        for _, part in ipairs(contents) do
          chunks[#chunks + 1] = type(part) == "string" and part or (part.value or "")
        end
      end
    end
  end
  local text = vim.trim(table.concat(chunks, "\n"))
  local clients = M.clients(bufnr)
  M.release(bufnr)
  if text == "" and rerr then
    return nil, rerr
  end
  return { query = { file = path, line = tonumber(line), col = tonumber(col) },
    clients = clients, text = text }
end

---Parse "path:line:col", the shape a command line and an editor both use.
---@param spec string
---@return string|nil path, number|nil line, number|nil col, string|nil err
function M.parse_position(spec)
  if type(spec) ~= "string" or spec == "" then
    return nil, nil, nil, "expected path:line:col"
  end
  -- rsplit, so a Windows-style or colon-bearing path still works
  local path, line, col = spec:match("^(.*):(%d+):(%d+)$")
  if not path then
    path, line = spec:match("^(.*):(%d+)$")
    col = "1"
  end
  if not path or path == "" then
    return nil, nil, nil, ("%q is not path:line:col"):format(spec)
  end
  return path, tonumber(line), tonumber(col)
end

return M
