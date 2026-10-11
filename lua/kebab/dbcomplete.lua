-- SQL completion backed by JDBC schema introspection.
--
-- vim-dadbod-completion gets some of the way: a table-name prefix completes,
-- and a column completes through a table alias. What it does not do, measured
-- against a live SQLite database over this layer's JDBC adapter, is offer the
-- bare table list or complete `customers.` into that table's columns -- the two
-- things you reach for most.
--
-- The schema is already available: KebabJdbc's `schema` mode returns every
-- table, column and type in one round trip. So this source answers from that,
-- with the type shown beside each column, which is the part that makes it feel
-- like a database IDE rather than word completion.
local M = {}

local jdbc = require("kebab.jdbc")

local SQL_FILETYPES = { sql = true, mysql = true, plsql = true }

-- url -> { tables = { [name] = { {name, type}, ... } }, order = { name, ... } }
local cache = {}

---Forget what was cached, for when the schema changes under you.
---@param url? string clears everything when omitted
function M.invalidate(url)
  if url then
    cache[url] = nil
  else
    cache = {}
  end
end

---Parse `schema` output into a table/column map.
---@param lines string[] each "table\tcolumn\ttype"
function M.parse_schema(lines)
  local schema = { tables = {}, order = {} }
  for _, line in ipairs(lines or {}) do
    local tbl, col, typ = line:match("^([^\t]+)\t([^\t]+)\t(.*)$")
    if tbl then
      if not schema.tables[tbl] then
        schema.tables[tbl] = {}
        schema.order[#schema.order + 1] = tbl
      end
      local cols = schema.tables[tbl]
      cols[#cols + 1] = { name = col, type = typ }
    end
  end
  return schema
end

---The schema for a URL, loading it if this is the first ask.
---@param url string
---@return table|nil schema, string|nil err
function M.schema(url)
  if cache[url] then
    return cache[url]
  end
  local lines, err = jdbc.run(url, "schema", { timeout = 120000 })
  if not lines then
    return nil, err
  end
  cache[url] = M.parse_schema(lines)
  return cache[url]
end

---Is the schema for this URL already loaded?
function M.loaded(url)
  return cache[url] ~= nil
end

-- --------------------------------------------------------------- parsing

---The word being completed, and its qualifier if there is one.
---
---"select customers.ful" -> qualifier "customers", prefix "ful"
---"select ful"           -> qualifier nil,         prefix "ful"
---@param line string text before the cursor
---@return string|nil qualifier, string prefix
function M.context(line)
  local qualifier, prefix = line:match("([%w_]+)%.([%w_]*)$")
  if qualifier then
    return qualifier, prefix
  end
  return nil, (line:match("([%w_]*)$") or "")
end

---Aliases declared in the buffer: { alias = table }.
---
---Resolving these is what makes `c.` work in `select c. from customers c`, and
---aliases are how anyone writes a join.
---@param text string the whole buffer
function M.aliases(text)
  local out = {}
  local lowered = (text or ""):lower()
  -- Both "from customers c" and "from customers as c", for FROM and JOIN. Lua
  -- patterns have no optional groups, so the "as" form is matched separately
  -- rather than with something like (?:as )?.
  for _, keyword in ipairs({ "from", "join" }) do
    for tbl, alias in lowered:gmatch(keyword .. "%s+([%w_%.]+)%s+as%s+([%w_]+)") do
      out[alias] = tbl
    end
    for tbl, alias in lowered:gmatch(keyword .. "%s+([%w_%.]+)%s+([%w_]+)") do
      -- "from customers where" is not an alias called "where"
      if not M.is_keyword(alias) and alias ~= "as" then
        out[alias] = tbl
      end
    end
  end
  return out
end

local KEYWORDS = {
  ["where"] = true, ["join"] = true, ["inner"] = true, ["left"] = true,
  ["right"] = true, ["full"] = true, ["outer"] = true, ["cross"] = true,
  ["on"] = true, ["group"] = true, ["order"] = true, ["limit"] = true,
  ["having"] = true, ["union"] = true, ["select"] = true, ["as"] = true,
  ["set"] = true, ["values"] = true, ["using"] = true, ["natural"] = true,
}

function M.is_keyword(word)
  return KEYWORDS[(word or ""):lower()] == true
end

---Which table a qualifier refers to: itself if it is a table, else whatever it
---is an alias for.
---@param schema table
---@param qualifier string
---@param buffer_text? string
function M.resolve_table(schema, qualifier, buffer_text)
  if schema.tables[qualifier] then
    return qualifier
  end
  -- case-insensitive match on the real table names
  local lowered = qualifier:lower()
  for _, name in ipairs(schema.order) do
    if name:lower() == lowered then
      return name
    end
    -- a schema-qualified name completes from its last segment too
    local leaf = name:match("([^%.]+)$")
    if leaf and leaf:lower() == lowered then
      return name
    end
  end
  if buffer_text then
    local target = M.aliases(buffer_text)[lowered]
    if target then
      for _, name in ipairs(schema.order) do
        if name:lower() == target or (name:match("([^%.]+)$") or ""):lower() == target then
          return name
        end
      end
    end
  end
  return nil
end

-- ------------------------------------------------------------------- items

local KIND = { table = 7, column = 5 } -- Class, Field -- matches the LSP kinds

---Completion items for a position.
---@param url string
---@param line string text before the cursor
---@param buffer_text? string
---@return table[] items
function M.items(url, line, buffer_text)
  local schema = cache[url]
  if not schema then
    return {}
  end
  local qualifier, prefix = M.context(line)
  local items = {}

  if qualifier then
    local tbl = M.resolve_table(schema, qualifier, buffer_text)
    if not tbl then
      return {}
    end
    for _, col in ipairs(schema.tables[tbl] or {}) do
      if prefix == "" or col.name:lower():find(prefix:lower(), 1, true) == 1 then
        items[#items + 1] = {
          label = col.name,
          kind = KIND.column,
          detail = col.type,
          documentation = ("%s.%s"):format(tbl, col.name),
        }
      end
    end
    return items
  end

  -- Unqualified: tables first, then every column, so an empty prefix still
  -- offers the table list -- which is the thing dadbod's source never does.
  for _, name in ipairs(schema.order) do
    if prefix == "" or name:lower():find(prefix:lower(), 1, true) == 1 then
      items[#items + 1] = {
        label = name,
        kind = KIND.table,
        detail = "table",
      }
    end
  end
  for _, name in ipairs(schema.order) do
    for _, col in ipairs(schema.tables[name] or {}) do
      if prefix ~= "" and col.name:lower():find(prefix:lower(), 1, true) == 1 then
        items[#items + 1] = {
          label = col.name,
          kind = KIND.column,
          detail = ("%s · %s"):format(col.type, name),
        }
      end
    end
  end
  return items
end

-- ------------------------------------------------------- blink.cmp source

---@class kebab.DbCompleteSource
local Source = {}
Source.__index = Source

function M.new()
  return setmetatable({}, Source)
end

function Source:enabled()
  if not SQL_FILETYPES[vim.bo.filetype] then
    return false
  end
  local url = vim.b.db
  return type(url) == "string" and url ~= "" and jdbc.subprotocol(url) ~= nil
end

function Source:get_trigger_characters()
  return { "." }
end

function Source:get_completions(ctx, callback)
  local url = vim.b.db
  if type(url) ~= "string" or url == "" then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return function() end
  end

  local line = (ctx.line or ""):sub(1, (ctx.cursor and ctx.cursor[2]) or #(ctx.line or ""))
  local buffer_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")

  local function answer()
    callback({
      context = ctx,
      items = M.items(url, line, buffer_text),
      is_incomplete_forward = false,
      is_incomplete_backward = false,
    })
  end

  if M.loaded(url) then
    answer()
    return function() end
  end

  -- First completion in a buffer pays for the introspection round trip. Doing
  -- it off the main loop keeps the keystroke that triggered it from blocking.
  vim.schedule(function()
    local _, err = M.schema(url)
    if err then
      vim.notify_once("kebab SQL completion: " .. tostring(err), vim.log.levels.WARN)
    end
    answer()
  end)
  return function() end
end

---Load the schema for a buffer's connection up front, so the first completion
---is instant. kebab.db calls this when attaching a connection.
function M.warm(url)
  if url == nil or url == "" or M.loaded(url) then
    return
  end
  vim.schedule(function()
    M.schema(url)
  end)
end

return M
