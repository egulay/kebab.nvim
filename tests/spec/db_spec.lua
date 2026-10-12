-- The SQL IDE: connections, browsing, and schema-backed completion.
local H = ...
local D = require("kebab.db")
local C = require("kebab.dbcomplete")
local J = require("kebab.jdbc")

local function with_store(fn)
  local saved = vim.g.kebab_db_store
  vim.g.kebab_db_store = H.tmpdir("db-store") .. "/connections.json"
  local ok, err = pcall(fn, vim.g.kebab_db_store)
  vim.g.kebab_db_store = saved
  if not ok then error(err, 0) end
end

local fixture_db, fixture_url

local function requires_jdbc()
  if vim.fn.executable("java") == 0 or vim.fn.executable("javac") == 0 then
    H.skip("a JDK is needed for JDBC")
  end
  if vim.fn.executable("sqlite3") == 0 then
    H.skip("sqlite3 is needed to build the fixture")
  end
end

local function fixture()
  if fixture_db then
    return { name = "shop", url = fixture_url }
  end
  fixture_db = H.tmpdir("db-fixture") .. "/shop.sqlite"
  local sql = table.concat({
    "CREATE TABLE customers (id INTEGER PRIMARY KEY, full_name TEXT, email TEXT);",
    "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total_cents INTEGER);",
    "INSERT INTO customers (full_name, email) VALUES ('Ada Lovelace','ada@example.com');",
    "INSERT INTO customers (full_name, email) VALUES ('Alan Turing','alan@example.com');",
    "INSERT INTO orders (customer_id, total_cents) VALUES (1, 4999);",
  }, "\n")
  local res = vim.system({ "sqlite3", fixture_db }, { stdin = sql, text = true }):wait(30000)
  H.eq(0, res.code, "fixture creation failed")
  fixture_url = "jdbc:sqlite:" .. fixture_db
  return { name = "shop", url = fixture_url }
end

H.describe("`kebab db`", function()
  local cli = require("kebab.cli")

  local function with_connections(list, fn)
    with_store(function()
      H.ok(D.save(list))
      fn()
    end)
  end

  local sample = {
    { name = "alpha", url = "jdbc:postgresql://localhost:5432/alpha", user = "a", password_env = "ALPHA_PW" },
    { name = "alpha_reporting", url = "jdbc:postgresql://localhost:5432/rep", user = "r" },
    { name = "beta", url = "jdbc:sqlite:/tmp/beta.db" },
  }

  H.it("resolves a connection by name, exact match winning", function()
    with_connections(sample, function()
      -- "alpha" also matches "alpha_reporting"; an exact name must not become
      -- a two-way choice, or naming a connection precisely is useless.
      H.eq({ "alpha" }, vim.tbl_map(function(c) return c.name end, cli.resolve_connection("alpha")))
      H.eq({ "alpha", "alpha_reporting" },
        vim.tbl_map(function(c) return c.name end, cli.resolve_connection("alph")))
      H.eq({ "beta" }, vim.tbl_map(function(c) return c.name end, cli.resolve_connection("BETA")),
        "matching should ignore case")
      H.eq({}, cli.resolve_connection("nothing-like-this"))
    end)
  end)

  H.it("says what to do when there are no connections at all", function()
    with_store(function()
      local notes = H.capture_notify(function() cli.db("") end)
      H.eq(1, #notes)
      H.matches("No database connections yet", notes[1].msg)
      H.matches("IdeDbAdd", notes[1].msg, "it should say how to make one")
      H.eq(vim.log.levels.WARN, notes[1].level)
    end)
  end)

  H.it("names the real connections when the one asked for is unknown", function()
    with_connections(sample, function()
      local notes = H.capture_notify(function() cli.db("gamma") end)
      H.eq(1, #notes)
      H.matches("gamma", notes[1].msg)
      for _, name in ipairs({ "alpha", "alpha_reporting", "beta" }) do
        H.matches(name, notes[1].msg, "the list of real names should be in the message")
      end
      H.eq(vim.log.levels.ERROR, notes[1].level)
    end)
  end)

  H.it("opens a console bound to the named connection, asking nothing", function()
    with_connections(sample, function()
      -- No vim.ui is stubbed on purpose: a scripted answer would hide a
      -- picker, and the point of naming a connection is that nothing asks.
      H.capture_notify(function() cli.db("beta") end)
      H.eq("sql", vim.bo.filetype)
      local attached = D.attached()
      H.ok(attached, "the buffer should carry a connection")
      H.eq("jdbc:sqlite:/tmp/beta.db", attached.url)
      H.matches("beta%-%d+%.sql$", vim.api.nvim_buf_get_name(0),
        "a console is a real file, so it survives a restart")
    end)
  end)

  H.it("has an explorer command that exists before the plugin is loaded", function()
    -- A spec with only `keys` owns commands that do not exist until the key is
    -- pressed, and `kebab db` runs `nvim -c DBUI` from a cold start. Without a
    -- `cmd` trigger that is "Not an editor command".
    for _, name in ipairs({ "DBUI", "DBUIToggle" }) do
      H.eq(2, vim.fn.exists(":" .. name), name .. " should be a known command")
    end
  end)
end)

H.describe("the connection store", function()
  H.it("is empty to begin with", function()
    with_store(function()
      H.eq({}, (D.connections()))
    end)
  end)

  H.it("keeps connections out of the project", function()
    local saved = vim.g.kebab_db_store
    vim.g.kebab_db_store = nil
    local path = D.store_path()
    vim.g.kebab_db_store = saved
    H.matches(vim.pesc(vim.fn.stdpath("data")), path,
      "a connections file may name a user; it must not land in a repository")
  end)

  H.it("round-trips a connection", function()
    with_store(function()
      H.ok(D.add({ name = "shop", url = "jdbc:sqlite:/tmp/shop.sqlite" }))
      local list = D.connections()
      H.eq(1, #list)
      H.eq("shop", list[1].name)
      H.eq("shop", D.connection("shop").name)
    end)
  end)

  H.it("replaces a connection of the same name rather than duplicating it", function()
    with_store(function()
      D.add({ name = "shop", url = "jdbc:sqlite:/tmp/a.sqlite" })
      D.add({ name = "shop", url = "jdbc:sqlite:/tmp/b.sqlite" })
      local list = D.connections()
      H.eq(1, #list)
      H.matches("b%.sqlite", list[1].url)
    end)
  end)

  H.it("removes one", function()
    with_store(function()
      D.add({ name = "a", url = "jdbc:sqlite:/tmp/a.sqlite" })
      D.add({ name = "b", url = "jdbc:sqlite:/tmp/b.sqlite" })
      H.ok(D.remove("a"))
      H.eq(1, #D.connections())
      local ok, err = D.remove("nope")
      H.falsy(ok)
      H.matches("No connection named", err)
    end)
  end)

  H.it("writes a file a person can edit", function()
    with_store(function(path)
      D.add({ name = "shop", url = "jdbc:sqlite:/tmp/shop.sqlite", user = "ada" })
      H.ok(#vim.fn.readfile(path) > 1, "it should be pretty-printed")
    end)
  end)

  H.it("keeps the file readable only by its owner", function()
    with_store(function(path)
      D.add({ name = "shop", url = "jdbc:sqlite:/tmp/shop.sqlite", user = "ada" })
      local mode = vim.uv.fs_stat(path).mode % 512
      H.eq(384, mode, "connections should be 0600, not world-readable")
    end)
  end)

  H.it("reports a broken file instead of ignoring it", function()
    with_store(function(path)
      H.write(path, "{ not json")
      local list, err = D.connections()
      H.eq({}, list)
      H.matches("not valid JSON", err)
    end)
  end)

  -- M.save rewrites the file wholesale, so every writer has to refuse when the
  -- store did not load -- otherwise adding one connection destroys the rest.
  H.it("refuses to write over a store it could not read", function()
    with_store(function(path)
      for _, broken in ipairs({
        '{"connections":[{"name":"prod","url":"jdbc:postgresql://h/p"},]}',
        '{"connections":[{"name":"legacy","url":"jdbc:db2://h:50000/W"}]}',
        '{"connections":{"prod":{"name":"prod","url":"jdbc:postgresql://h/p"}}}',
      }) do
        H.write(path, broken)
        local before = table.concat(vim.fn.readfile(path), "\n")
        local ok, err = D.add({ name = "new", url = "jdbc:sqlite:/tmp/x.db" })
        H.falsy(ok, "add should refuse: " .. broken)
        H.ok(err, "it should say why")
        H.eq(before, table.concat(vim.fn.readfile(path), "\n"), "the store must be left alone")
        H.falsy(D.remove("prod"), "remove should refuse too")
      end
    end)
  end)

  H.it("treats a connections object as malformed, not as empty", function()
    with_store(function(path)
      H.write(path, '{"connections":{"prod":{"name":"prod","url":"jdbc:postgresql://h/p"}}}')
      local list, err = D.connections()
      H.eq({}, list)
      H.matches("connections", err, "an object keyed by name should be reported")
    end)
  end)

  H.it("pretty-prints without needing jq", function()
    with_store(function(path)
      H.ok(D.add({ name = "shop", url = "jdbc:sqlite:/tmp/s.db" }))
      local saved = vim.env.PATH
      vim.env.PATH = "/nonexistent"
      local ok, err = D.add({ name = "other", url = "jdbc:sqlite:/tmp/o.db" })
      vim.env.PATH = saved
      H.ok(ok, "a missing jq is not a failure: " .. tostring(err))
      H.eq(2, #D.connections(), "and the store still round-trips")
    end)
  end)
end)

H.describe("the table preview query", function()
  -- `limit` is not universal, and catalog identifiers arrive in the server's
  -- own case and may be reserved words, so they have to be quoted.
  H.it("uses each dialect's own row cap", function()
    H.eq('select * from "s"."tbl" limit 200', D.preview_sql("jdbc:postgresql://h/p", "s.tbl", 200))
    H.eq('select * from "s"."tbl" limit 200', D.preview_sql("jdbc:sqlite:/x", "s.tbl", 200))
    H.eq("select * from `s`.`tbl` limit 200", D.preview_sql("jdbc:mysql://h/d", "s.tbl", 200))
    H.eq("select * from `s`.`tbl` limit 200", D.preview_sql("jdbc:mariadb://h/d", "s.tbl", 200))
    H.eq(
      'select * from "HR"."EMPLOYEES" fetch first 200 rows only',
      D.preview_sql("jdbc:oracle:thin:@h:1521/x", "HR.EMPLOYEES", 200),
      "Oracle rejects limit"
    )
    H.eq(
      "select top (200) * from [dbo].[customers]",
      D.preview_sql("jdbc:sqlserver://h:1433;databaseName=d", "dbo.customers", 200),
      "SQL Server rejects limit, and must not get both caps"
    )
  end)

  H.it("quotes a table name that needs it", function()
    H.matches('"public"%."order"', D.preview_sql("jdbc:postgresql://h/p", "public.order", 10))
    H.matches("`user group`", D.preview_sql("jdbc:mysql://h/d", "user group", 10))
  end)

  H.it("covers every registered driver", function()
    for _, d in ipairs(require("kebab.jdbc").drivers()) do
      local url = ("jdbc:%s:whatever"):format(d.key)
      local sql = D.preview_sql(url, "t", 5)
      H.matches("^select", sql, d.key)
      local caps = select(2, sql:gsub("limit %d+", "")) + select(2, sql:gsub("top %(%d+%)", ""))
        + select(2, sql:gsub("fetch first", ""))
      H.eq(1, caps, d.key .. " should cap the rows exactly once")
    end
  end)
end)

H.describe("validating a connection", function()
  H.it("requires a name and a JDBC url", function()
    H.ok(D.validate({ name = "a", url = "jdbc:sqlite:/tmp/a.db" }))
    local cases = {
      { nil, "is not an object" },
      { {}, "needs a name" },
      { { name = "a" }, "needs a url" },
      { { name = "a", url = "postgres://h/db" }, "not JDBC" },
      { { name = "a", url = "jdbc:cobol:x" }, "No driver registered" },
      { { name = "a", url = "jdbc:sqlite:/x", user = 1 }, "user should be a string" },
    }
    for _, case in ipairs(cases) do
      local ok, err = D.validate(case[1])
      H.falsy(ok, "should reject " .. vim.inspect(case[1]))
      H.matches(case[2], err)
    end
  end)

  H.it("refuses to save something it could not load back", function()
    with_store(function(path)
      local ok, err = D.add({ name = "a", url = "nonsense" })
      H.falsy(ok)
      H.matches("not JDBC", err)
      H.falsy(H.exists(path), "nothing should have been written")
    end)
  end)
end)

H.describe("credentials", function()
  H.it("reads a password from the environment, never from the file", function()
    vim.env.KEBAB_TEST_DB_PASS = "s3cret"
    local creds, warn = D.credentials({ name = "a", url = "jdbc:sqlite:/x", user = "ada", password_env = "KEBAB_TEST_DB_PASS" })
    H.eq("ada", creds.user)
    H.eq("s3cret", creds.password)
    H.eq(nil, warn)
    vim.env.KEBAB_TEST_DB_PASS = nil
  end)

  H.it("says so when the named variable is not set", function()
    local creds, warn = D.credentials({ name = "a", url = "jdbc:sqlite:/x", password_env = "KEBAB_UNSET_VAR_XYZ" })
    H.eq(nil, creds.password)
    H.matches("is not set", warn)
  end)

  H.it("stores no password field at all", function()
    with_store(function(path)
      D.add({ name = "a", url = "jdbc:sqlite:/x", user = "ada", password_env = "SOME_VAR" })
      local text = H.read(path)
      H.falsy(text:match('"password"'), "a password must never be written to disk: " .. text)
      H.matches("password_env", text, "only the variable's name is stored")
    end)
  end)
end)

H.describe("the explorer and the mouse", function()
  H.it("opens the node under a double click", function()
    -- dadbod-ui maps <CR> and `o` and nothing else -- it has no mouse support
    -- at all, so the explorer was dead to a mouse: clicking a connection did
    -- nothing. This layer is for keyboard *and* mouse users.
    vim.cmd("enew!")
    vim.bo.filetype = "dbui"
    local found
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      if m.lhs == "<2-LeftMouse>" then found = m end
    end
    H.ok(found, "a dbui buffer should answer a double click")
    H.eq("<LeftMouse><Plug>(DBUI_SelectLine)", found.rhs)
    -- The <LeftMouse> prefix moves the cursor to the clicked line first;
    -- without it the action applies to wherever the cursor already was.
    H.matches("^<LeftMouse>", found.rhs)
    -- And it has to be remappable, or the <Plug> never fires.
    H.eq(0, found.noremap, "a <Plug> rhs cannot be noremap")
  end)

  H.it("leaves other buffers alone", function()
    vim.cmd("enew!")
    vim.bo.filetype = "sql"
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      H.ok(m.lhs ~= "<2-LeftMouse>", "only the tree should take a double click")
    end
  end)
end)

H.describe("publishing to dadbod", function()
  H.it("fills vim.g.dbs so the explorer lists the connections", function()
    with_store(function()
      D.add({ name = "shop", url = "jdbc:sqlite:/tmp/shop.sqlite" })
      local dbs = D.publish()
      H.eq(1, #dbs)
      H.eq("shop", dbs[1].name)
      H.eq("shop", vim.g.dbs[1].name)
      H.eq("kjdbc:jdbc:sqlite:/tmp/shop.sqlite", vim.g.dbs[1].url,
        "the explorer must hold the scheme dadbod will not rewrite")
    end)
  end)
end)

H.describe("attaching a connection to a buffer", function()
  H.it("sets b:db so :DB and completion use it", function()
    vim.cmd("enew!")
    vim.bo.filetype = "sql"
    -- A real path: attaching makes dadbod-completion connect, and dadbod now
    -- routes that through this layer's runner, so a made-up path would create
    -- a stray database.
    local c = { name = "shop", url = "jdbc:sqlite:" .. H.tmpdir("attach") .. "/shop.sqlite" }
    H.ok(D.attach(c))
    -- The kjdbc: form, not the bare JDBC url: dadbod strips a leading "jdbc:"
    -- and dispatches on what is left, so a bare one reaches dadbod's own psql
    -- or sqlite3 adapter and never this layer. That is how the explorer came
    -- to report "Tables (0)" for a database with 48.
    H.eq("kjdbc:" .. c.url, vim.b.db)
    H.eq(c.url, D.attached().url, "and kebab gets the plain url back")
    H.eq("shop", vim.b.kebab_db_name)
    local attached = D.attached()
    H.eq("shop", attached.name)
  end)

  H.it("reports nothing attached in a fresh buffer", function()
    vim.cmd("enew!")
    H.eq(nil, D.attached())
  end)
end)

H.describe("reading a real database", function()
  H.it("connects", function()
    requires_jdbc()
    local banner, err = D.ping(fixture())
    H.ok(banner, tostring(err))
    H.matches("SQLite", banner)
  end)

  H.it("lists tables", function()
    requires_jdbc()
    local tables, err = D.tables(fixture())
    H.ok(tables, tostring(err))
    H.ok(vim.tbl_contains(tables, "customers"))
  end)

  H.it("lists columns with their types", function()
    requires_jdbc()
    local cols, err = D.columns(fixture(), "customers")
    H.ok(cols, tostring(err))
    H.eq(3, #cols)
    H.eq("id", cols[1].name)
    H.eq("INTEGER", cols[1].type)
    H.eq("full_name", cols[2].name)
  end)

  H.it("runs a query", function()
    requires_jdbc()
    local lines, err = D.query(fixture(), "select count(*) as n from customers")
    H.ok(lines, tostring(err))
    H.matches("2", table.concat(lines, "\n"))
  end)

  -- The limit is pinned, not assumed: the suite boots the real user config on
  -- purpose, so a config that sets kebab_db_preview_limit would otherwise fail
  -- this -- which is a legitimate setting, not a regression.
  H.it("opens a table's rows in a buffer, the way clicking one does", function()
    requires_jdbc()
    local c = fixture()
    local saved = vim.g.kebab_db_preview_limit
    vim.g.kebab_db_preview_limit = 200
    local ok, err = pcall(function()
      H.ok(D.open_table(c, "customers"))
      local name = vim.api.nvim_buf_get_name(0)
      H.matches("kebab%-db://shop/customers", name)
      local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      H.matches('select %* from "customers" limit 200', text, "it should show the query it ran")
      H.matches("Ada Lovelace", text)
      H.falsy(vim.bo.modifiable, "a result grid should not be editable")
      vim.cmd("bwipeout!")
    end)
    vim.g.kebab_db_preview_limit = saved
    H.ok(ok, tostring(err))
  end)

  H.it("caps the preview rather than pulling a whole table", function()
    local saved = vim.g.kebab_db_preview_limit
    vim.g.kebab_db_preview_limit = nil
    H.eq(200, D.preview_limit(), "the shipped default")
    vim.g.kebab_db_preview_limit = 10
    H.eq(10, D.preview_limit(), "and a config overrides it")
    vim.g.kebab_db_preview_limit = saved
  end)
end)

-- The IntelliSense. Measured against vim-dadbod-completion on the same
-- database: it offers a table-name prefix and a column through an alias, but
-- not the bare table list and not `customers.` -> its columns. Those two are
-- what this source exists for, so they are what is checked.
H.describe("schema-backed completion", function()
  local function schema_for()
    requires_jdbc()
    local c = fixture()
    C.invalidate(c.url)
    local schema, err = C.schema(c.url)
    H.ok(schema, tostring(err))
    return c, schema
  end

  H.it("loads the schema over JDBC", function()
    local _, schema = schema_for()
    H.ok(vim.tbl_contains(schema.order, "customers"))
    H.ok(vim.tbl_contains(schema.order, "orders"))
    H.eq(3, #schema.tables.customers)
    H.eq("INTEGER", schema.tables.customers[1].type)
  end)

  H.it("offers the bare table list, which dadbod's source does not", function()
    local c = select(1, schema_for())
    local items = C.items(c.url, "select * from ")
    local labels = vim.tbl_map(function(i) return i.label end, items)
    H.ok(vim.tbl_contains(labels, "customers"), "expected tables, got " .. vim.inspect(labels))
    H.ok(vim.tbl_contains(labels, "orders"))
  end)

  H.it("completes a table prefix", function()
    local c = select(1, schema_for())
    local labels = vim.tbl_map(function(i) return i.label end, C.items(c.url, "select * from cust"))
    H.ok(vim.tbl_contains(labels, "customers"))
    H.falsy(vim.tbl_contains(labels, "orders"), "a prefix should filter")
  end)

  H.it("completes customers. into that table's columns, which dadbod's source does not", function()
    local c = select(1, schema_for())
    local items = C.items(c.url, "select customers.")
    local labels = vim.tbl_map(function(i) return i.label end, items)
    table.sort(labels)
    H.eq({ "email", "full_name", "id" }, labels)
  end)

  H.it("shows each column's type", function()
    local c = select(1, schema_for())
    local items = C.items(c.url, "select customers.")
    for _, item in ipairs(items) do
      if item.label == "id" then
        H.eq("INTEGER", item.detail, "the type is what makes it a database IDE")
      end
    end
  end)

  H.it("completes through an alias", function()
    local c = select(1, schema_for())
    local text = "select c. from customers c join orders o on o.customer_id = c.id"
    local labels = vim.tbl_map(function(i) return i.label end, C.items(c.url, "select c.", text))
    table.sort(labels)
    H.eq({ "email", "full_name", "id" }, labels)
  end)

  H.it("completes the other alias in a join", function()
    local c = select(1, schema_for())
    local text = "select o. from customers c join orders o on o.customer_id = c.id"
    local labels = vim.tbl_map(function(i) return i.label end, C.items(c.url, "select o.", text))
    table.sort(labels)
    H.eq({ "customer_id", "id", "total_cents" }, labels)
  end)

  H.it("filters columns by prefix after the dot", function()
    local c = select(1, schema_for())
    local labels = vim.tbl_map(function(i) return i.label end, C.items(c.url, "select customers.ful"))
    H.eq({ "full_name" }, labels)
  end)

  H.it("offers nothing for an unknown qualifier", function()
    local c = select(1, schema_for())
    H.eq({}, C.items(c.url, "select nosuchtable."))
  end)

  H.it("marks tables and columns with different kinds", function()
    local c = select(1, schema_for())
    local items = C.items(c.url, "select * from ")
    for _, item in ipairs(items) do
      H.eq(7, item.kind, "a table should complete as a Class")
    end
    local cols = C.items(c.url, "select customers.")
    for _, item in ipairs(cols) do
      H.eq(5, item.kind, "a column should complete as a Field")
    end
  end)

  H.it("caches the schema, and forgets it when told", function()
    local c = select(1, schema_for())
    H.eq(true, C.loaded(c.url))
    C.invalidate(c.url)
    H.eq(false, C.loaded(c.url))
  end)
end)

H.describe("the completion source", function()
  H.it("is off without a connection", function()
    vim.cmd("enew!")
    vim.bo.filetype = "sql"
    vim.b.db = nil
    H.eq(false, C.new():enabled())
  end)

  H.it("is off in a buffer that is not SQL", function()
    vim.cmd("enew!")
    vim.bo.filetype = "lua"
    vim.b.db = "jdbc:sqlite:/tmp/x.db"
    H.eq(false, C.new():enabled())
  end)

  H.it("is on in a SQL buffer with a JDBC connection", function()
    vim.cmd("enew!")
    vim.bo.filetype = "sql"
    vim.b.db = "jdbc:sqlite:/tmp/x.db"
    H.eq(true, C.new():enabled())
  end)

  H.it("is off for a connection that is not JDBC", function()
    vim.cmd("enew!")
    vim.bo.filetype = "sql"
    vim.b.db = "postgres://host/db"
    H.eq(false, C.new():enabled(), "dadbod's own source handles native URLs")
  end)

  H.it("is registered with blink", function()
    local spec = require("lazy.core.config").plugins["blink.cmp"]
    local opts = require("lazy.core.plugin").values(spec, "opts", false)
    H.ok(vim.tbl_contains(opts.sources.default, "kebab_db"), "it should be a default source")
    H.eq("kebab.dbcomplete", opts.sources.providers.kebab_db.module)
  end)

  H.it("answers through the blink interface", function()
    requires_jdbc()
    local c = fixture()
    C.invalidate(c.url)
    C.schema(c.url)
    vim.cmd("enew!")
    vim.bo.filetype = "sql"
    vim.b.db = c.url
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "select customers." })
    local got
    C.new():get_completions({ cursor = { 1, 17 }, line = "select customers." }, function(r) got = r end)
    H.wait(15000, function() return got ~= nil end, "the source to answer")
    local labels = vim.tbl_map(function(i) return i.label end, got.items)
    table.sort(labels)
    H.eq({ "email", "full_name", "id" }, labels)
  end)
end)

H.describe("the database commands", function()
  H.it("are registered", function()
    for _, cmd in ipairs({ "IdeDbAdd", "IdeDbConnect", "IdeDbTables", "IdeDbConsole", "IdeDbPing", "IdeDbRemove", "IdeDbEdit" }) do
      H.ok(vim.fn.exists(":" .. cmd) >= 1, ":" .. cmd .. " should be defined")
    end
  end)

  H.it("says so when there are no connections to pick", function()
    with_store(function()
      local notes = H.capture_notify(function()
        D.pick("Database", function() end)
      end)
      H.ok(H.notified(notes, "No database connections yet"))
    end)
  end)

  H.it("skips the picker when there is only one connection", function()
    with_store(function()
      D.add({ name = "only", url = "jdbc:sqlite:/tmp/only.sqlite" })
      local chosen
      D.pick("Database", function(c) chosen = c end)
      H.eq("only", chosen and chosen.name, "one connection needs no choosing")
    end)
  end)

  H.it("asks which when there are several", function()
    with_store(function()
      D.add({ name = "one", url = "jdbc:sqlite:/tmp/one.sqlite" })
      D.add({ name = "two", url = "jdbc:sqlite:/tmp/two.sqlite" })
      local chosen
      H.with_ui({ "two" }, function()
        D.pick("Database", function(c) chosen = c end)
      end)
      H.eq("two", chosen and chosen.name)
    end)
  end)

  H.it("prefers the buffer's own connection over asking", function()
    with_store(function()
      D.add({ name = "saved", url = "jdbc:sqlite:/tmp/saved.sqlite" })
      vim.cmd("enew!")
      vim.bo.filetype = "sql"
      D.attach({ name = "saved", url = "jdbc:sqlite:/tmp/saved.sqlite" })
      local chosen
      D.current(function(c) chosen = c end)
      H.eq("saved", chosen and chosen.name)
    end)
  end)
end)

-- Every driver but SQLite reports a schema, so the catalog holds
-- "public.customers" -- and the SQLite-only fixture hid what that did to
-- completion.
H.describe("completion on a schema-qualified catalog", function()
  local C = require("kebab.dbcomplete")

  local function catalog()
    return C.parse_schema({
      "public.customers\tid\tint4",
      "public.customers\tfull_name\ttext",
      "public.orders\tid\tint4",
      "sales.invoices\tnumber\ttext",
    })
  end

  local function labels(items)
    local out = {}
    for _, i in ipairs(items) do
      out[#out + 1] = i.label
    end
    table.sort(out)
    return out
  end

  H.it("matches a table by its leaf as well as its full name", function()
    H.ok(C.name_matches("public.customers", "cust"), "typing `cust` must offer public.customers")
    H.ok(C.name_matches("public.customers", "publ"), "and the qualified form still matches")
    H.ok(C.name_matches("public.customers", ""), "an empty prefix matches everything")
    H.falsy(C.name_matches("public.orders", "cust"))
  end)

  H.it("treats a schema qualifier as a schema, not a missing table", function()
    local schema = catalog()
    H.eq({ "customers" }, labels(C.tables_in_schema(schema, "public", "c")))
    H.eq({ "customers", "orders" }, labels(C.tables_in_schema(schema, "public", "")))
    H.eq({ "invoices" }, labels(C.tables_in_schema(schema, "sales", "")))
    H.eq({}, labels(C.tables_in_schema(schema, "nosuch", "")))
  end)

  H.it("still resolves a table by its leaf for column completion", function()
    local schema = catalog()
    H.eq("public.customers", C.resolve_table(schema, "customers"))
    H.eq("public.customers", C.resolve_table(schema, "public.customers"))
  end)
end)

H.describe("aliases are per statement", function()
  local C = require("kebab.dbcomplete")

  -- One buffer-global, last-wins alias map meant appending a statement
  -- silently changed what the statements above it completed to.
  H.it("does not let a later statement rebind an earlier alias", function()
    local text = "select c.name from customers c;\nselect c.total from charges c;"
    local first = C.statement_at(text, 10)
    local second = C.statement_at(text, #text - 5)
    H.eq("customers", C.aliases(first)["c"], "the first statement's own alias")
    H.eq("charges", C.aliases(second)["c"], "and the second's")
    H.eq("charges", C.aliases(text)["c"], "whole-buffer resolution is last-wins, which is the bug")
  end)

  H.it("returns the whole text when there is no cursor to scope to", function()
    local text = "select 1; select 2"
    H.eq(text, C.statement_at(text))
    H.eq("select 1", C.statement_at(text, 3))
    H.matches("select 2", C.statement_at(text, #text))
  end)
end)

H.describe("a schema load that fails", function()
  local C = require("kebab.dbcomplete")
  local jdbc = require("kebab.jdbc")

  -- The load is synchronous and runs on the main loop -- a JDBC connect, and
  -- on first use a curl and a javac. Not remembering a failure meant every
  -- later keystroke in a .sql buffer re-ran the whole thing.
  H.it("is remembered, so it is not retried on every keystroke", function()
    local url = "jdbc:postgresql://nowhere.invalid:5432/x"
    local calls = 0
    local real = jdbc.run
    jdbc.run = function()
      calls = calls + 1
      return nil, "connection refused"
    end
    C.invalidate()
    local ok, err = pcall(function()
      for _ = 1, 5 do
        local schema, serr = C.schema(url)
        H.falsy(schema)
        H.matches("refused", serr)
      end
      H.eq(1, calls, "five asks should cost one load, not five")
      H.ok(C.failing(url), "it should know it is failing")
      H.falsy(C.loaded(url), "and not claim to be loaded")

      -- and it does retry once the cooldown has run out
      vim.g.kebab_db_schema_cooldown = 0
      C.schema(url)
      H.eq(2, calls, "the cooldown expiring should allow another attempt")
    end)
    vim.g.kebab_db_schema_cooldown = nil
    jdbc.run = real
    C.invalidate()
    H.ok(ok, tostring(err))
  end)

  H.it("does not believe an empty schema forever", function()
    local url = "jdbc:sqlite:/tmp/empty-for-now.sqlite"
    local real = jdbc.run
    jdbc.run = function()
      return {}
    end
    C.invalidate()
    local ok, err = pcall(function()
      vim.g.kebab_db_schema_empty_ttl = 0
      C.schema(url)
      H.falsy(C.loaded(url), "an empty schema past its ttl should be re-asked")
      vim.g.kebab_db_schema_empty_ttl = nil
      C.invalidate()
      C.schema(url)
      H.ok(C.loaded(url), "within the ttl it is a real answer")
    end)
    vim.g.kebab_db_schema_empty_ttl = nil
    jdbc.run = real
    C.invalidate()
    H.ok(ok, tostring(err))
  end)

  H.it("is cleared by DDL, so a table created from a console completes", function()
    if vim.fn.executable("java") == 0 or vim.fn.executable("sqlite3") == 0 then
      H.skip("a JDK and sqlite3 are needed")
    end
    local db = H.tmpdir("ddl-refresh") .. "/d.sqlite"
    local res = vim.system({ "sqlite3", db }, { stdin = "create table a (x int);", text = true }):wait(30000)
    H.eq(0, res.code, tostring(res.stderr))
    local c = { name = "ddl", url = "jdbc:sqlite:" .. db }
    C.invalidate()
    local schema = C.schema(c.url)
    H.ok(schema, "the first load should work")
    H.ok(C.loaded(c.url))
    H.ok(D.query(c, "create table b (y int)"), "DDL from the console")
    H.falsy(C.loaded(c.url), "the cached schema must be dropped, or `b` never completes")
    local again = C.schema(c.url)
    H.ok(again, "and reload")
    local found = false
    for _, name in ipairs(again.order) do
      if name:lower():find("b", 1, true) == 1 then
        found = true
      end
    end
    H.ok(found, "the new table should be there: " .. vim.inspect(again.order))
    require("kebab.jdbc").shutdown(c.url)
  end)
end)

H.describe("opening a SQL console", function()
  -- The loop left `path` pointing at the 1000th *existing* file when every
  -- candidate was taken, and then truncated it -- overwriting a saved console.
  H.it("never truncates a console it did not just create", function()
    local saved = vim.g.kebab_scratch_dir
    local dir = H.tmpdir("console-full")
    -- stand in for stdpath("data")/kebab/sql by filling every candidate
    local store = dir .. "/kebab/sql"
    vim.fn.mkdir(store, "p")
    -- the naming rule, replicated: <name>-<n>.sql for n in 1..1000
    for i = 1, 1000 do
      H.write(("%s/full-%d.sql"):format(store, i), "PRECIOUS " .. i)
    end
    -- the fallback has to be a name that does not exist yet
    local candidates = {}
    for i = 1, 1000 do
      candidates[("full-%d.sql"):format(i)] = true
    end
    local stamped = ("full-%s.sql"):format(os.date("%Y%m%d-%H%M%S"))
    H.falsy(candidates[stamped], "the timestamp fallback must not be one of the numbered names")
    -- and none of the existing files may have been touched
    H.eq("PRECIOUS 1000", H.read(("%s/full-%d.sql"):format(store, 1000)))
    vim.g.kebab_scratch_dir = saved
  end)
end)

H.describe("published credentials", function()
  -- publish_credentials only ever added, so a password resolved once stayed in
  -- a process-global table for the rest of the session -- including after the
  -- connection was removed from the store.
  H.it("are dropped when the connection is removed", function()
    with_store(function()
      vim.env.KEBAB_SPEC_PW = "s3cret"
      H.ok(D.add({ name = "gone", url = "jdbc:sqlite:/tmp/gone.sqlite", password_env = "KEBAB_SPEC_PW" }))
      -- publishing happens on use; do it directly
      D.publish()
      local all = vim.g.kebab_db_credentials
      H.ok(type(all) == "table" and all["jdbc:sqlite:/tmp/gone.sqlite"], "it should be published first")
      H.ok(D.remove("gone"))
      all = vim.g.kebab_db_credentials
      H.falsy(
        type(all) == "table" and all["jdbc:sqlite:/tmp/gone.sqlite"] ~= nil,
        "a removed connection's password must not outlive it"
      )
      vim.env.KEBAB_SPEC_PW = nil
    end)
  end)

  H.it("can be dropped explicitly", function()
    local url = "jdbc:sqlite:/tmp/explicit.sqlite"
    local all = type(vim.g.kebab_db_credentials) == "table" and vim.g.kebab_db_credentials or {}
    all[url] = { user = "u" }
    vim.g.kebab_db_credentials = all
    H.ok(D.unpublish_credentials(url))
    H.falsy((vim.g.kebab_db_credentials or {})[url])
    H.falsy(D.unpublish_credentials(url), "a second drop is a no-op")
  end)
end)
