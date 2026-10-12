-- The SQL IDE: saved connections, table browsing, query buffers.
--
-- kebab.jdbc does the talking; this is the part a person uses. The shape is
-- a dedicated database IDE's: add a data source once, pick it for a console,
-- browse tables,
-- open one to see its rows.
--
-- Connections live in stdpath("data"), never in the project, and a password is
-- never stored -- a connection names an *environment variable* to read it from
-- instead. Committing a password by accident is a bigger problem than typing
-- `export` once.
local M = {}

local jdbc = require("kebab.jdbc")

---Where SQL consoles and statement panes are kept.
---
---Overridable because the test suite must not write into the user's own data
---directory -- a spec did, and the editor then asked whether to save it.
function M.sql_dir()
  local dir = vim.g.kebab_db_sql_dir and require("kebab.path").expand(vim.g.kebab_db_sql_dir)
    or (vim.fn.stdpath("data") .. "/kebab/sql")
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.store_path()
  return (vim.g.kebab_db_store and require("kebab.path").expand(vim.g.kebab_db_store))
    or (vim.fn.stdpath("data") .. "/kebab/connections.json")
end

-- ------------------------------------------------------------------- store

---@class kebab.DbConnection
---@field name string
---@field url string          a JDBC URL
---@field user? string
---@field password_env? string name of an environment variable holding the password

---Saved connections.
---@return kebab.DbConnection[] connections, string|nil err
function M.connections()
  local path = M.store_path()
  if not vim.uv.fs_stat(path) then
    return {}, nil
  end
  local ok, text = pcall(function()
    return table.concat(vim.fn.readfile(path), "\n")
  end)
  if not ok then
    return {}, "Could not read " .. path
  end
  if vim.trim(text) == "" then
    return {}, nil
  end
  local decoded
  ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    return {}, ("%s is not valid JSON: %s"):format(path, tostring(decoded))
  end
  local list = type(decoded) == "table" and (decoded.connections or (vim.islist(decoded) and decoded)) or nil
  -- An object keyed by name is the obvious thing to try when hand-editing,
  -- and it is a table -- so it has to be rejected by shape, not by type, or
  -- every saved connection silently reads back as zero.
  if not require("kebab.jsonfile").is_array(list) then
    return {}, path .. ' should have a "connections" list'
  end
  local out = {}
  for i, c in ipairs(list) do
    local valid, err = M.validate(c, i)
    if not valid then
      return {}, err
    end
    out[#out + 1] = c
  end
  return out, nil
end

---@param c any
---@param index? number
function M.validate(c, index)
  local where = index and ("connection %d"):format(index) or "connection"
  if type(c) ~= "table" then
    return false, where .. " is not an object"
  end
  if type(c.name) ~= "string" or c.name == "" then
    return false, where .. " needs a name"
  end
  where = ("connection %q"):format(c.name)
  if type(c.url) ~= "string" or c.url == "" then
    return false, where .. " needs a url"
  end
  if not jdbc.subprotocol(c.url) then
    return false, ("%s has a url that is not JDBC: %s"):format(where, c.url)
  end
  local _, derr = jdbc.driver_for(c.url)
  if derr then
    return false, ("%s: %s"):format(where, derr)
  end
  for _, field in ipairs({ "user", "password_env" }) do
    if c[field] ~= nil and type(c[field]) ~= "string" then
      return false, ("%s %s should be a string"):format(where, field)
    end
  end
  return true
end

---Write connections back, pretty-printed so the file stays hand-editable.
function M.save(connections)
  for i, c in ipairs(connections) do
    local ok, err = M.validate(c, i)
    if not ok then
      return false, err
    end
  end
  local path = M.store_path()
  local encoded = vim.json.encode({ connections = connections })
  local wrote, werr = require("kebab.fs").write_lines(path, require("kebab.jsonfile").pretty(encoded))
  if not wrote then
    return false, werr
  end
  -- a connections file may hold a username; keep it to the owner
  pcall(vim.uv.fs_chmod, path, 384) -- 0600
  return true
end

---@param name string
function M.connection(name)
  local list, err = M.connections()
  if err then
    return nil, err
  end
  for _, c in ipairs(list) do
    if c.name == name then
      return c, nil
    end
  end
  return nil, nil
end

---Add a connection, replacing one of the same name.
function M.add(connection)
  local ok, err = M.validate(connection)
  if not ok then
    return false, err
  end
  -- Refusing here is the whole point: M.save rewrites the file wholesale, so
  -- adding to a store that failed to load would replace every saved
  -- connection with just this one.
  local list, lerr = M.connections()
  if lerr then
    return false, ("%s (fix it, or :IdeDbEdit, before adding a connection)"):format(lerr)
  end
  for i, c in ipairs(list) do
    if c.name == connection.name then
      local old_url = c.url
      list[i] = connection
      local saved, serr = M.save(list)
      if saved and old_url and old_url ~= connection.url then
        -- The warm process for the old URL still holds a connection to a
        -- database this name no longer refers to; M.remove could not reclaim
        -- it afterwards, because it only knows the current URL.
        pcall(function()
          require("kebab.jdbc").shutdown(old_url)
        end)
      end
      return saved, serr
    end
  end
  list[#list + 1] = connection
  return M.save(list)
end

function M.remove(name)
  local list, lerr = M.connections()
  if lerr then
    return false, lerr
  end
  for i, c in ipairs(list) do
    if c.name == name then
      table.remove(list, i)
      -- Its warm process is holding a connection to a database we are
      -- forgetting about, and its password should not outlive it either.
      pcall(function()
        require("kebab.jdbc").shutdown(c.url)
      end)
      M.unpublish_credentials(c.url)
      local ok, err = M.save(list)
      return ok, err
    end
  end
  return false, ("No connection named %q"):format(tostring(name))
end

-- ------------------------------------------------------------- credentials

---Credentials for a connection, read from the environment at use time so no
---password is ever written to disk by this layer.
---@param c kebab.DbConnection
function M.credentials(c)
  local creds = {}
  if c.user and c.user ~= "" then
    creds.user = c.user
  end
  if c.password_env and c.password_env ~= "" then
    local value = vim.env[c.password_env]
    if value == nil or value == "" then
      return creds, ("%s is not set, so %q has no password"):format(c.password_env, c.name)
    end
    creds.password = value
  end
  return creds, nil
end

---Publish credentials where kebab.jdbc can find them for this URL.
local function publish_credentials(c)
  local creds, warn = M.credentials(c)
  local all = vim.g.kebab_db_credentials
  all = type(all) == "table" and all or {}
  all[c.url] = creds
  vim.g.kebab_db_credentials = all
  return warn
end

---Drop a connection's published credentials.
---
---Re-read a url's credentials from the environment, now.
---
---M.publish() publishes what the environment held *at startup*. Two things
---break that: a shell that had not sourced the env file yet (the usual case --
---a password is exported in one terminal and the editor was started from
---another), and `:let $PG_PASSWORD = '...'` inside the session, which has to
---work as the escape hatch it looks like. The dadbod adapter calls this before
---every run, so the credentials are whatever the environment says right now.
---@param url string
---@return string|nil warn why there is no password, if there is none
function M.ensure_credentials(url)
  for _, c in ipairs((M.connections())) do
    if c.url == url then
      return publish_credentials(c)
    end
  end
  return nil
end

---Drop a url's published credentials.
---
---They used to accumulate: publish_credentials only ever added, so a password
---resolved once stayed in a process-global table for the rest of the session,
---including after the connection was removed from the store.
---@param url string
function M.unpublish_credentials(url)
  local all = vim.g.kebab_db_credentials
  if type(all) ~= "table" or all[url] == nil then
    return false
  end
  all[url] = nil
  vim.g.kebab_db_credentials = all
  return true
end

-- ------------------------------------------------------------------ dadbod

---Expose saved connections to vim-dadbod-ui, which reads vim.g.dbs.
function M.publish()
  local list, lerr = M.connections()
  if lerr then
    vim.notify(lerr, vim.log.levels.ERROR)
    return nil, lerr
  end
  local dbs = {}
  for _, c in ipairs(list) do
    publish_credentials(c)
    -- dadbod strips a leading "jdbc:" and then dispatches on what is left,
    -- so the explorer has to hold the kjdbc: form or it talks to psql.
    dbs[#dbs + 1] = { name = c.name, url = jdbc.dadbod_url(c.url) }
  end
  vim.g.dbs = dbs
  return dbs, nil
end

---Attach a connection to a buffer, so :DB and completion use it.
---
---The re-fetch matters: vim-dadbod-completion populates its cache from a
---`FileType sql` autocmd, which fires *before* b:db exists. Without this,
---completion in a standalone .sql file stays empty for the whole session --
---which is exactly what a scratch file is.
---@param c kebab.DbConnection
---@param bufnr? number
function M.attach(c, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local warn = publish_credentials(c)
  vim.b[bufnr].db = jdbc.dadbod_url(c.url)
  vim.b[bufnr].kebab_db_name = c.name
  pcall(vim.fn["vim_dadbod_completion#fetch"], bufnr)
  -- Load the schema now so the first completion is instant rather than paying
  -- for a JDBC round trip on a keystroke.
  pcall(function()
    require("kebab.dbcomplete").warm(c.url)
  end)
  if warn then
    vim.notify(warn, vim.log.levels.WARN)
  end
  return true
end

---The connection attached to a buffer, if any.
function M.attached(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local url = jdbc.plain_url(vim.b[bufnr].db)
  if url == nil or url == "" then
    return nil
  end
  return { name = vim.b[bufnr].kebab_db_name or url, url = url }
end

-- -------------------------------------------------------------- operations

---Test a connection. Returns the server banner, or nil plus the reason.
function M.ping(c)
  publish_credentials(c)
  local lines, err = jdbc.run(c.url, "ping", { timeout = 60000 })
  if not lines then
    return nil, err
  end
  return lines[1]
end

---How a table is built: columns, key, foreign keys both ways, indexes.
---@param c kebab.DbConnection
---@param table_name string
function M.structure(c, table_name)
  publish_credentials(c)
  return jdbc.run(c.url, "structure", { args = { table_name }, timeout = 90000 })
end

---Tables for a connection.
function M.tables(c)
  publish_credentials(c)
  return jdbc.run(c.url, "tables", { timeout = 90000 })
end

---Columns of a table, as { name, type, nullable }.
function M.columns(c, table_name)
  publish_credentials(c)
  local lines, err = jdbc.run(c.url, "columns", { args = { table_name }, timeout = 90000 })
  if not lines then
    return nil, err
  end
  local out = {}
  for _, line in ipairs(lines) do
    local name, typ, nullable = line:match("^([^\t]*)\t([^\t]*)\t(.*)$")
    if name then
      out[#out + 1] = { name = name, type = typ, nullable = nullable }
    end
  end
  return out
end

---Does this statement change the shape of the database?
---@param sql string
local function is_ddl(sql)
  local head = (sql or ""):gsub("^%s*", ""):lower()
  return head:match("^create") ~= nil
    or head:match("^drop") ~= nil
    or head:match("^alter") ~= nil
    or head:match("^truncate") ~= nil
    or head:match("^comment") ~= nil
end

---Run SQL and return the output lines.
function M.query(c, sql)
  publish_credentials(c)
  local lines, err = jdbc.run(c.url, "query", { stdin = sql, timeout = 300000 })
  -- Creating a table from a console is the scratch-database workflow, and the
  -- completion schema would otherwise keep answering from before it existed --
  -- nothing else ever invalidated it.
  if lines and is_ddl(sql) then
    pcall(function()
      require("kebab.dbcomplete").invalidate(c.url)
    end)
  end
  return lines, err
end

---How many rows a table preview shows. A database IDE pages; this just caps.
function M.preview_limit()
  return tonumber(vim.g.kebab_db_preview_limit) or 200
end

-- How each dialect spells "the first N rows", and what it quotes identifiers
-- with. The names come straight from the driver's catalog, so they are in the
-- server's own case and may be reserved words -- quoting them is not optional.
-- How each database is asked for one page.
--
-- Spelled out per driver, every one of them, rather than as a table of
-- exceptions over a silent default. The default version was indefensible on
-- sight: reading it you could not tell whether PostgreSQL was handled (it was,
-- through the default) and a driver added later would inherit LIMIT/OFFSET
-- whether or not that is its syntax -- Firebird wants `ROWS`, DB2 `FETCH
-- FIRST`, Oracle before 12c needed a ROWNUM subquery. That is a decision, and
-- it should not be made by omission. `paging_spec` fails if a registered
-- driver has no entry here.
--
-- Placeholders are named because Lua's string.format has no positional
-- arguments and the clauses want them in different orders.
--
-- The statement is wrapped rather than extended --
-- `select * from ( <theirs> ) kebab_page <clause>` -- so a query the user
-- wrote keeps its own LIMIT, ORDER BY, CTE or UNION intact.
local LIMIT_OFFSET = "select * from ({sql}) kebab_page limit {size} offset {offset}"
local OFFSET_FETCH = "select * from ({sql}) kebab_page offset {offset} rows fetch next {size} rows only"

local PAGING = {
  -- LIMIT n OFFSET m: what each of these documents
  postgresql = LIMIT_OFFSET,
  sqlite = LIMIT_OFFSET,
  mysql = LIMIT_OFFSET,
  mariadb = LIMIT_OFFSET,
  h2 = LIMIT_OFFSET,
  duckdb = LIMIT_OFFSET,
  clickhouse = LIMIT_OFFSET,
  -- OFFSET m ROWS FETCH NEXT n ROWS ONLY: the SQL:2008 spelling
  oracle = OFFSET_FETCH, -- 12c and later; earlier needs a ROWNUM subquery
  -- SQL Server refuses OFFSET without an ORDER BY to attach it to, and the
  -- statement being wrapped may not have one. `(select null)` is the
  -- documented way to say "no particular order" and costs nothing.
  sqlserver = "select * from ({sql}) kebab_page order by (select null) offset {offset} rows fetch next {size} rows only",
}

local DIALECTS = {
  oracle = { quote = '"', tail = "fetch first %d rows only" },
  sqlserver = { quote = "[", head = "top (%d) " },
  mysql = { quote = "`" },
  mariadb = { quote = "`" },
}

---Which databases this layer can ask for a page.
---@return string[] subprotocols
function M.paging_dialects()
  return vim.tbl_keys(PAGING)
end

-- How each database is asked for a query plan.
--
-- `prefix` is a single statement: the plan comes back as its result. `steps`
-- is for the two that cannot do it in one -- SQL Server turns a session
-- setting on, runs the statement, turns it off; Oracle stores the plan and
-- then selects it out of a table function. Those need the *same connection*
-- for all three, so they only work through the warm process; db.explain says
-- so rather than returning a plan for a connection that was never set up.
--
-- analyze actually runs the statement. It is a separate action for that
-- reason, and refused for anything that is not a select.
local EXPLAIN = {
  postgresql = {
    prefix = "explain (format text) %s",
    analyze = "explain (analyze, buffers, format text) %s",
  },
  -- `explain` alone gives SQLite's bytecode; the query plan is the useful one
  sqlite = { prefix = "explain query plan %s" },
  mysql = { prefix = "explain %s", analyze = "explain analyze %s" },
  mariadb = { prefix = "explain %s", analyze = "explain analyze %s" },
  h2 = { prefix = "explain %s", analyze = "explain analyze %s" },
  duckdb = { prefix = "explain %s", analyze = "explain analyze %s" },
  clickhouse = { prefix = "explain %s" },
  sqlserver = {
    steps = { "set showplan_all on", "%s", "set showplan_all off" },
    plan_step = 2,
    needs_session = true,
  },
  oracle = {
    steps = { "explain plan for %s", "select plan_table_output from table(dbms_xplan.display())" },
    plan_step = 2,
    needs_session = true,
  },
}

---The statements to run to get a plan for `sql`, and which one answers.
---@param url string
---@param sql string
---@param analyze? boolean also execute the statement and report what happened
---@return string[]|nil steps, integer|nil plan_step, string|nil err
function M.explain_steps(url, sql, analyze)
  local how = EXPLAIN[jdbc.subprotocol(url) or ""]
  if not how then
    return nil, nil, "this layer does not know how to explain a query on that database"
  end
  local inner = (sql:gsub("%s*;%s*$", ""))
  if analyze then
    if not inner:lower():match("^%s*with%s") and not inner:lower():match("^%s*select%s") then
      -- ANALYZE executes. On an insert or an update that is a surprise nobody
      -- wants from a button labelled "explain".
      return nil, nil, "analyze runs the statement, so it is only offered for a select"
    end
    if not how.analyze then
      return nil, nil, "that database has no analyze; plain explain is available"
    end
    return { how.analyze:format(inner) }, 1, nil
  end
  if how.steps then
    local steps = {}
    for i, step in ipairs(how.steps) do
      steps[i] = step:find("%%s") and step:format(inner) or step
    end
    return steps, how.plan_step, nil
  end
  return { how.prefix:format(inner) }, 1, nil
end

---Does this database need one connection for all the steps?
---@param url string
function M.explain_needs_session(url)
  local how = EXPLAIN[jdbc.subprotocol(url) or ""]
  return how ~= nil and how.needs_session == true
end

---Which databases this layer can explain a query on.
function M.explain_dialects()
  return vim.tbl_keys(EXPLAIN)
end

---A statement that counts the rows `sql` would return.
---
---Wrapped, like a page is, so it counts the user's own statement rather than a
---table -- a filtered select has its own total. Separate from paging on
---purpose: an industry SQL editor does not count by default either, because
---`count(*)` on a large table is a full scan and nobody asked for one.
---@param url string
---@param sql string
---@return string
function M.count_sql(url, sql)
  local inner = (sql:gsub("%s*;%s*$", ""))
  return ("select count(*) as kebab_rows from (%s) kebab_count"):format(inner)
end

---A statement that asks the server for one page of `sql`.
---
---Server-side on purpose. The first version of paging read the whole result
---set and skipped rows on the client, so page 50 of a hundred-row page size
---pulled five thousand rows across the connection to show a hundred -- a
---workaround, not paging.
---
---nil for a database with no entry above, which is not a failure: kebab.dbide
---then pages on the cursor instead, which is slower, dialect-free and always
---correct.
---@param url string
---@param sql string the statement to page
---@param offset number rows to skip
---@param size number rows to return
---@return string|nil
function M.page_sql(url, sql, offset, size)
  local template = PAGING[jdbc.subprotocol(url) or ""]
  if not template then
    return nil
  end
  -- a trailing semicolon or whitespace would land inside the parentheses
  local inner = (sql:gsub("%s*;%s*$", ""))
  local values = {
    sql = inner,
    offset = tostring(math.floor(offset)),
    size = tostring(math.floor(size)),
  }
  -- a function replacement, because gsub treats % in a replacement *string*
  -- as an escape and a statement is full of them
  return (template:gsub("{(%w+)}", function(key)
    return values[key] or ("{" .. key .. "}")
  end))
end

---Quote one dotted catalog identifier for a dialect: schema.name -> "schema"."name".
---@param name string
---@param quote string
local function quote_identifier(name, quote)
  local open, close = quote, quote
  if quote == "[" then
    open, close = "[", "]"
  end
  local parts = {}
  for part in tostring(name):gmatch("[^.]+") do
    -- doubling the closing quote is how every one of these dialects escapes it
    parts[#parts + 1] = open .. part:gsub(vim.pesc(close), close .. close) .. close
  end
  if #parts == 0 then
    return open .. close
  end
  return table.concat(parts, ".")
end

---The SQL a table preview runs. Dialect-aware: `limit` is not universal --
---Oracle and SQL Server both reject it, and they are both registered drivers.
---@param url string a JDBC URL
---@param table_name string
---@param limit number
---@param url string
---@param table_name string
---@param limit? number nil for no limit clause at all, which is what the
---                     paged result grid wants: the statement shown to the
---                     user is the one they would have written, and the page
---                     size is the grid's business.
function M.preview_sql(url, table_name, limit)
  local d = DIALECTS[jdbc.subprotocol(url) or ""] or {}
  if limit == nil then
    return ("select * from %s"):format(quote_identifier(table_name, d.quote or '"'))
  end
  local head = d.head and d.head:format(limit) or ""
  -- a dialect caps rows either in the select list or in a trailing clause,
  -- never both: `top (n) ... limit n` is a syntax error on SQL Server
  local tail = ""
  if d.tail then
    tail = " " .. d.tail:format(limit)
  elseif not d.head then
    tail = (" limit %d"):format(limit)
  end
  return ("select %s* from %s%s"):format(head, quote_identifier(table_name, d.quote or '"'), tail)
end

---Open a table's rows in a scratch buffer, the way double-clicking a table in
---a database IDE does.
---@param c kebab.DbConnection
---@param table_name string
function M.open_table(c, table_name)
  local sql = M.preview_sql(c.url, table_name, M.preview_limit())
  local lines, err = M.query(c, sql)
  if not lines then
    vim.notify(err, vim.log.levels.ERROR)
    return false
  end
  vim.cmd("new")
  local buf = vim.api.nvim_get_current_buf()
  -- Make it a scratch buffer *before* naming it. Naming can fail (E95 when a
  -- previous preview of the same table is still open), and if it throws first
  -- the user is left in an ordinary modifiable buffer with swap enabled where
  -- a read-only grid was expected.
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local base = ("kebab-db://%s/%s"):format(c.name, table_name)
  local name, n = base, 1
  while vim.fn.bufexists(name) == 1 do
    n = n + 1
    name = ("%s#%d"):format(base, n)
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend({ "-- " .. sql, "" }, lines))
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "dbout"
  return true
end

-- -------------------------------------------------------------- interactive

---Pick a connection, then do something with it.
---@param prompt string
---@param cb fun(c: kebab.DbConnection)
function M.pick(prompt, cb)
  local list, err = M.connections()
  if err then
    return vim.notify(err, vim.log.levels.ERROR)
  end
  if #list == 0 then
    return vim.notify("No database connections yet (:IdeDbAdd creates one)", vim.log.levels.WARN)
  end
  if #list == 1 then
    return cb(list[1])
  end
  vim.ui.select(list, {
    prompt = prompt,
    format_item = function(c)
      local driver = jdbc.driver_for(c.url)
      return ("%-22s %-12s %s"):format(c.name, driver and driver.label or "?", c.url)
    end,
  }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

---The connection to act on: the one attached to this buffer, else ask.
function M.current(cb)
  local attached = M.attached()
  if attached then
    -- a buffer's own connection carries no stored user/password_env, so prefer
    -- the saved entry with the same url when there is one
    for _, c in ipairs((M.connections())) do
      if c.url == attached.url then
        return cb(c)
      end
    end
    return cb(attached)
  end
  M.pick("Database", cb)
end

---Add a connection by answering a few questions.
function M.add_interactive()
  local drivers = jdbc.drivers()
  vim.ui.select(drivers, {
    prompt = "Database",
    format_item = function(d)
      return ("%-12s %s"):format(d.key, d.label)
    end,
  }, function(driver)
    if not driver then
      return
    end
    vim.ui.input({ prompt = "Connection name: " }, function(name)
      if not name or vim.trim(name) == "" then
        return
      end
      local function finish(parts)
        local connection = {
          name = vim.trim(name),
          url = jdbc.build_url(driver, parts),
          user = parts.user ~= "" and parts.user or nil,
          password_env = parts.password_env ~= "" and parts.password_env or nil,
        }
        local ok, err = M.add(connection)
        if not ok then
          return vim.notify(err, vim.log.levels.ERROR)
        end
        M.publish()
        vim.notify(("Added %q — testing the connection…"):format(connection.name))
        vim.schedule(function()
          local banner, perr = M.ping(connection)
          if banner then
            vim.notify(("%s: connected to %s"):format(connection.name, banner))
          else
            vim.notify(("%s saved, but connecting failed:\n%s"):format(connection.name, tostring(perr)),
              vim.log.levels.WARN)
          end
        end)
      end

      if driver.file then
        vim.ui.input({ prompt = "Database file: ", completion = "file" }, function(file)
          if not file or vim.trim(file) == "" then
            return
          end
          finish({ file = vim.trim(file), user = "", password_env = "" })
        end)
        return
      end

      vim.ui.input({ prompt = "Host: ", default = "localhost" }, function(host)
        if host == nil then return end
        vim.ui.input({ prompt = "Port: ", default = tostring(driver.default_port or "") }, function(port)
          if port == nil then return end
          vim.ui.input({ prompt = "Database: " }, function(database)
            if database == nil then return end
            vim.ui.input({ prompt = "User: " }, function(user)
              if user == nil then return end
              vim.ui.input({
                prompt = "Env var holding the password (blank for none): ",
              }, function(password_env)
                if password_env == nil then return end
                finish({
                  host = vim.trim(host) ~= "" and vim.trim(host) or "localhost",
                  port = tonumber(port) or driver.default_port,
                  database = vim.trim(database),
                  user = vim.trim(user),
                  password_env = vim.trim(password_env),
                })
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

---Browse the tables of a connection and open one.
function M.browse()
  M.current(function(c)
    local tables, err = M.tables(c)
    if not tables then
      return vim.notify(err, vim.log.levels.ERROR)
    end
    if #tables == 0 then
      return vim.notify(("%s has no tables"):format(c.name), vim.log.levels.INFO)
    end
    vim.ui.select(tables, { prompt = ("Tables in %s"):format(c.name) }, function(choice)
      if choice then
        M.open_table(c, choice)
      end
    end)
  end)
end

---A new SQL buffer bound to a connection, the way a database IDE opens a console.
---
---With no connection it asks, or takes the one the current buffer is already
---bound to. `kebab db <name>` passes one, so nothing is asked.
---@param connection? kebab.DbConnection
function M.console(connection)
  local with = connection and function(cb) return cb(connection) end or M.current
  with(function(c)
    local dir = M.sql_dir()
    -- The loop used to leave `path` pointing at the 1000th *existing* file
    -- when every candidate was taken, and then truncate it -- overwriting a
    -- saved console. A timestamp cannot collide, and nothing is written over.
    local stem = c.name:gsub("[^%w%-_]", "_")
    local path
    for i = 1, 1000 do
      local candidate = ("%s/%s-%d.sql"):format(dir, stem, i)
      if not vim.uv.fs_stat(candidate) then
        path = candidate
        break
      end
    end
    if not path then
      path = ("%s/%s-%s.sql"):format(dir, stem, os.date("%Y%m%d-%H%M%S"))
      if vim.uv.fs_stat(path) then
        path = ("%s/%s-%s.sql"):format(dir, stem, tostring(vim.uv.hrtime()))
      end
    end
    local wrote, werr = require("kebab.fs").write_lines(path, { ("-- %s"):format(c.name), "", "" })
    if not wrote then
      return vim.notify(werr, vim.log.levels.ERROR)
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.bo.filetype = "sql"
    M.attach(c)
    vim.notify(("SQL console on %s — press %s to run the statement under the cursor")
      :format(c.name, require("kebab.keys").human("<C-CR>")))
  end)
end

function M.setup()
  -- Make saved connections visible to vim-dadbod-ui without waiting for a
  -- command to be run.
  pcall(M.publish)

  -- A warm JDBC process per connection is what makes queries cost 0.2ms
  -- instead of 180ms, but it is a child process holding an open database
  -- connection -- so it has to be closed on the way out.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("kebab_db", { clear = true }),
    callback = function()
      pcall(function()
        require("kebab.jdbc").shutdown_all()
      end)
    end,
  })

  vim.api.nvim_create_user_command("IdeDbStatus", function()
    local jdbc = require("kebab.jdbc")
    local list = M.connections()
    vim.notify(("Connections: %d\nWarm JDBC processes: %d")
      :format(#list, jdbc.daemon_count()))
  end, { desc = "Report database connections and warm processes" })

  vim.api.nvim_create_user_command("IdeDbDisconnect", function()
    local jdbc = require("kebab.jdbc")
    local n = jdbc.daemon_count()
    jdbc.shutdown_all()
    vim.notify(("Closed %d warm JDBC process%s"):format(n, n == 1 and "" or "es"))
  end, { desc = "Close the warm JDBC processes" })

  vim.api.nvim_create_user_command("IdeDbAdd", function()
    M.add_interactive()
  end, { desc = "Add a database connection" })

  vim.api.nvim_create_user_command("IdeDbConnect", function()
    M.pick("Attach to this buffer", function(c)
      M.attach(c)
      vim.notify(("%s attached to this buffer"):format(c.name))
    end)
  end, { desc = "Attach a database connection to this buffer" })

  vim.api.nvim_create_user_command("IdeDbTables", function()
    M.browse()
  end, { desc = "Browse tables and open one" })

  vim.api.nvim_create_user_command("IdeDbConsole", function()
    M.console()
  end, { desc = "New SQL console bound to a connection" })

  vim.api.nvim_create_user_command("IdeDbPing", function()
    M.current(function(c)
      local banner, err = M.ping(c)
      vim.notify(banner and (c.name .. ": " .. banner) or (c.name .. ": " .. tostring(err)),
        banner and vim.log.levels.INFO or vim.log.levels.ERROR)
    end)
  end, { desc = "Test a database connection" })

  vim.api.nvim_create_user_command("IdeDbRemove", function()
    M.pick("Remove which connection", function(c)
      vim.ui.select({ "No", "Yes" }, { prompt = ("Remove %q?"):format(c.name) }, function(answer)
        if answer ~= "Yes" then
          return
        end
        local ok, err = M.remove(c.name)
        vim.notify(ok and ("Removed " .. c.name) or tostring(err),
          ok and vim.log.levels.INFO or vim.log.levels.ERROR)
        if ok then
          M.publish()
        end
      end)
    end)
  end, { desc = "Remove a database connection" })

  vim.api.nvim_create_user_command("IdeDbEdit", function()
    local path = M.store_path()
    if not vim.uv.fs_stat(path) then
      M.save({})
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end, { desc = "Edit the database connections file" })
end

return M
