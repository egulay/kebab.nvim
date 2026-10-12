-- Drive this layer against a real database server. @see tests/db/servers.sh
--
-- Not a spec in tests/spec: those must run anywhere in under five seconds,
-- and this needs a server. It is the answer to "the SQL Server and Oracle
-- code paths were written and never executed" -- every check below goes
-- through the layer's own modules, so what is proved is the layer and not the
-- driver.
--
-- Environment: KEBAB_DB_STORE a connections file holding one connection,
-- CONN its name, SEED a file of statements to create the fixture.
local store = vim.env.KEBAB_DB_STORE
local name = vim.env.CONN
local seed_path = vim.env.SEED

vim.g.kebab_db_store = store
-- A driver jar is downloaded per run into a cache of its own, so a failure
-- here cannot be a stale jar from another test.
vim.g.kebab_jdbc_dir = vim.fn.tempname() .. "-jars"

local db = require("kebab.db")
local jdbc = require("kebab.jdbc")

local pass, fail = 0, 0
local function ok(what)
  pass = pass + 1
  io.write(("ok   %s\n"):format(what))
end
local function bad(what, why)
  fail = fail + 1
  io.write(("FAIL %s\n     %s\n"):format(what, tostring(why or "")))
end
---@param what string
---@param got any
---@param want string a pattern the joined output must contain
local function want_match(what, got, want)
  local text = type(got) == "table" and table.concat(got, "\n") or tostring(got)
  if text:lower():find(want:lower()) then
    return ok(what)
  end
  bad(what, ("wanted /%s/ in: %s"):format(want, text:sub(1, 400)))
end

local c = db.connection(name)
if not c then
  bad("the connection is readable", "no connection called " .. tostring(name))
  io.write(("\n%d passed, %d failed\n"):format(pass, fail))
  vim.cmd("cq")
end

-- ------------------------------------------------------------------ the basics

do
  local valid, err = db.validate(c, 1)
  if valid then
    ok("the url is one this layer recognises (" .. tostring(jdbc.subprotocol(c.url)) .. ")")
  else
    bad("the url is one this layer recognises", err)
  end
end

do
  -- This is also the driver download: Maven Central, with the .sha1 checked.
  local banner, err = db.ping(c)
  if banner then
    ok("connects, and the server says what it is: " .. banner)
  else
    bad("connects", err)
  end
end

-- --------------------------------------------------------------- the fixture

do
  local seed = table.concat(vim.fn.readfile(seed_path), "\n")
  -- Dropped first so a rerun against a kept container starts clean. Failure
  -- is expected the first time, which is why it is not a check.
  for _, drop in ipairs({ "drop table kebab_lines", "drop table kebab_items" }) do
    pcall(db.query, c, drop)
  end
  local lines, err = db.query(c, seed)
  if lines then
    -- A multi-statement script: SQLite's driver compiles only the first, which
    -- is why KebabJdbc splits them. Here it has to hold for this driver too.
    ok("runs a multi-statement script (" .. tostring(#lines) .. " lines of output)")
  else
    bad("runs a multi-statement script", err)
  end
end

-- ------------------------------------------------------------------ the reads

do
  local tables, err = db.tables(c)
  if tables then
    want_match("lists the tables it just created", tables, "kebab_items")
  else
    bad("lists the tables", err)
  end
end

do
  local cols, err = db.columns(c, "kebab_items")
  if cols then
    local names = {}
    for _, col in ipairs(cols) do
      names[#names + 1] = col.name:lower()
    end
    want_match("reads the columns, with types", table.concat(names, ","), "label")
  else
    bad("reads the columns", err)
  end
end

do
  -- DatabaseMetaData, per driver: columns with sizes, the primary key, foreign
  -- keys both directions, indexes in column order.
  local lines, err = db.structure(c, "kebab_items")
  if not lines then
    bad("shows how the table is built", err)
  else
    local text = table.concat(lines, "\n")
    want_match("structure: the columns", text, "label")
    want_match("structure: the primary key", text, "id")
    want_match("structure: the index", text, "ix_kebab_items_label")
    -- the other direction: kebab_lines references this table
    want_match("structure: what references it", text, "kebab_lines")
  end
end

do
  -- The data source tree lists what `tables` returns, and on these two drivers
  -- that was almost entirely the server's own catalog: 616 tables on a fresh
  -- SQL Server (589 of them `sys`), 2051 on a fresh Oracle. Finding your own
  -- table in that is the difference between a usable tree and an unusable one.
  local tables = db.tables(c) or {}
  local SYSTEM = { "sys.", "information_schema.", "SYS.", "INFORMATION_SCHEMA.", "XDB.", "MDSYS." }
  local offenders = {}
  for _, name in ipairs(tables) do
    for _, prefix in ipairs(SYSTEM) do
      if name:sub(1, #prefix) == prefix then
        offenders[#offenders + 1] = name
      end
    end
  end
  if #offenders == 0 then
    ok(("the tree is not flooded with the catalog (%d tables, none of them system)"):format(#tables))
  else
    bad("the tree is not flooded with the catalog",
      ("%d system tables, e.g. %s"):format(#offenders, offenders[1]))
  end
end

do
  -- A name typed in the wrong case used to return an empty structure panel
  -- with no error: Oracle stores `kebab_items` as `KEBAB_ITEMS`, and
  -- DatabaseMetaData matches exactly. The name from the tree always worked,
  -- which is why clicking was fine and typing was not.
  local cols, err = db.columns(c, "kebab_items")
  if cols and #cols > 0 then
    ok(("a lower-case table name still resolves (%d columns)"):format(#cols))
  else
    bad("a lower-case table name still resolves", err or "no columns came back")
  end
  local upper, uerr = db.columns(c, "KEBAB_ITEMS")
  if upper and #upper > 0 then
    ok("and so does an upper-case one")
  else
    bad("and so does an upper-case one", uerr or "no columns came back")
  end
end

-- -------------------------------------------------------------------- paging

do
  local sql = "select id, label from kebab_items"
  local page1 = db.page_sql(c.url, sql, 0, 2)
  local page2 = db.page_sql(c.url, sql, 2, 2)
  local rows1, err1 = db.query(c, page1)
  local rows2, err2 = db.query(c, page2)
  if not rows1 then
    bad("the first page is a statement this database accepts", err1 .. " :: " .. page1)
  else
    want_match("pages: the first page has the first row", rows1, "alpha")
  end
  if not rows2 then
    bad("the second page is a statement this database accepts", err2 .. " :: " .. page2)
  else
    local text = table.concat(rows2, "\n")
    if text:lower():find("gamma") and not text:lower():find("alpha") then
      ok("pages: the second page moved past the first")
    else
      bad("pages: the second page moved past the first", text:sub(1, 300))
    end
  end
end

do
  local total = db.count_sql(c.url, "select id from kebab_items")
  local lines, err = db.query(c, total)
  if lines then
    want_match("counts the rows a statement would return", lines, "3")
  else
    bad("counts the rows", err .. " :: " .. total)
  end
end

-- ------------------------------------------------------------------- explain

do
  local steps, plan_step, err = db.explain_steps(c.url, "select id from kebab_items", false)
  if not steps then
    bad("knows how to explain a query here", err)
  else
    ok(("explain is %d step(s), the plan comes from step %d"):format(#steps, plan_step))
    -- SQL Server and Oracle both need every step on the *same* connection,
    -- which only the warm process provides. Run them in order and read the
    -- step that answers.
    local out, perr
    for i, step in ipairs(steps) do
      local lines, serr = db.query(c, step)
      if i == plan_step then
        out, perr = lines, serr
      end
    end
    if out and #out > 0 then
      ok("explain returns a plan (" .. #out .. " lines)")
    else
      bad("explain returns a plan", perr or "no output")
    end
  end
end

-- ------------------------------------------------------- the warm process

do
  local before = jdbc.daemon_pid and jdbc.daemon_pid(c.url) or nil
  db.query(c, "select 1 as one from kebab_items")
  local after = jdbc.daemon_pid and jdbc.daemon_pid(c.url) or nil
  if before and after and before == after then
    ok("the warm process is reused rather than restarted (pid " .. tostring(after) .. ")")
  elseif after then
    ok("a warm process is running (pid " .. tostring(after) .. ")")
  else
    -- Not a failure: the daemon can be off, and the one-shot path is correct.
    io.write("skip the warm process is not in use here\n")
  end
end

do
  -- Completion reads the schema through the driver's metadata, in one call.
  -- `table_names` only reads the cache, so the fetch is the thing to drive.
  local complete = require("kebab.dbcomplete")
  complete.invalidate(c.url)
  local schema, serr = complete.schema(c.url)
  if not schema then
    bad("completion can fetch the schema", serr)
  else
    local names = complete.table_names(c.url)
    want_match("completion sees the schema", table.concat(names, ","), "kebab_items")
    local found = false
    for table_name, columns in pairs(schema.tables or {}) do
      if table_name:lower():find("kebab_items") and #columns > 0 then
        found = true
      end
    end
    if found then
      ok("completion sees the columns of a table too")
    else
      bad("completion sees the columns of a table too",
        "kebab_items has no columns in the parsed schema")
    end
  end
end

-- ------------------------------------------------------------------ teardown

pcall(db.query, c, "drop table kebab_lines")
pcall(db.query, c, "drop table kebab_items")
pcall(function()
  jdbc.shutdown(c.url)
end)

io.write(("\n%s: %d passed, %d failed\n"):format(name, pass, fail))
if fail > 0 then
  vim.cmd("cq")
end
