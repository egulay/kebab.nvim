-- JDBC: drivers from Maven Central, connections over JDBC.
--
-- The pure logic is tested unconditionally. The parts that need the network or
-- a JVM run against a real SQLite database and skip with a reason when the
-- machine cannot do it, rather than pretending.
local H = ...
local J = require("kebab.jdbc")

H.describe("the driver registry", function()
  H.it("covers the databases worth covering", function()
    local keys = vim.tbl_map(function(d) return d.key end, J.drivers())
    for _, want in ipairs({ "postgresql", "mysql", "mariadb", "sqlite", "sqlserver", "oracle", "h2", "duckdb", "clickhouse" }) do
      H.ok(vim.tbl_contains(keys, want), want .. " should have a driver")
    end
  end)

  H.it("gives every driver a label, coordinates and a URL template", function()
    for _, d in ipairs(J.drivers()) do
      H.ok(type(d.label) == "string" and d.label ~= "", d.key .. " needs a label")
      H.ok(type(d.coords) == "table" and #d.coords > 0, d.key .. " needs Maven coordinates")
      H.ok(type(d.url) == "string" and d.url:match("^jdbc:"), d.key .. " needs a jdbc: URL template")
      for _, coord in ipairs(d.coords) do
        local group, artifact = J.parse_coord(coord)
        H.ok(group and artifact, ("%s has a malformed coordinate %q"):format(d.key, coord))
      end
    end
  end)

  H.it("gives a file-backed driver no port, and a server-backed one a port", function()
    for _, d in ipairs(J.drivers()) do
      if d.file then
        H.ok(d.url:match("{file}"), d.key .. " is file-backed so its URL needs {file}")
      else
        H.ok(d.default_port, d.key .. " should have a default port")
        H.ok(d.url:match("{host}"), d.key .. " needs {host}")
      end
    end
  end)

  H.it("names mysql's transitive dependency, which is needed at runtime", function()
    local mysql = J.driver("mysql")
    H.ok(#mysql.coords >= 2, "mysql-connector-j alone is not enough: " .. vim.inspect(mysql.coords))
    H.ok(table.concat(mysql.coords, " "):match("protobuf"), "protobuf-java should be included")
  end)

  H.it("merges a user's own driver by key", function()
    local saved = vim.g.kebab_jdbc_drivers
    vim.g.kebab_jdbc_drivers = {
      { key = "firebird", label = "Firebird", coords = { "org.firebirdsql.jdbc:jaybird" },
        url = "jdbc:firebirdsql://{host}:{port}/{database}", default_port = 3050 },
      { key = "postgresql", label = "Postgres (mine)" },
    }
    local keys = vim.tbl_map(function(d) return d.key end, J.drivers())
    H.ok(vim.tbl_contains(keys, "firebird"), "a new driver should be added")
    H.eq("Postgres (mine)", J.driver("postgresql").label, "an override should apply")
    H.ok(#J.driver("postgresql").coords > 0, "and the rest of it should survive the merge")
    vim.g.kebab_jdbc_drivers = saved
    H.eq("PostgreSQL", J.driver("postgresql").label)
  end)
end)

H.describe("reading a JDBC URL", function()
  H.it("extracts the subprotocol", function()
    H.eq("postgresql", J.subprotocol("jdbc:postgresql://host:5432/db"))
    H.eq("sqlite", J.subprotocol("jdbc:sqlite:/tmp/a.db"))
    H.eq("oracle", J.subprotocol("jdbc:oracle:thin:@host:1521/orcl"))
  end)

  H.it("rejects anything that is not a JDBC URL", function()
    for _, bad in ipairs({ "sqlite:/tmp/a.db", "postgres://h/db", "", "jdbc:", "nonsense" }) do
      H.eq(nil, J.subprotocol(bad), ("%q should not parse"):format(bad))
    end
    H.eq(nil, J.subprotocol(nil))
  end)

  H.it("finds the driver a URL needs", function()
    H.eq("PostgreSQL", J.driver_for("jdbc:postgresql://h/db").label)
    H.eq("SQLite", J.driver_for("jdbc:sqlite:/tmp/a.db").label)
  end)

  H.it("explains an unknown database, listing the ones it knows", function()
    local d, err = J.driver_for("jdbc:cobol:whatever")
    H.falsy(d)
    H.matches("No driver registered", err)
    H.matches("postgresql", err, "it should list what is available")
  end)

  H.it("explains a URL that is not JDBC at all", function()
    local d, err = J.driver_for("postgres://h/db")
    H.falsy(d)
    H.matches("not a JDBC URL", err)
  end)
end)

H.describe("building a JDBC URL", function()
  H.it("fills in host, port and database", function()
    H.eq("jdbc:postgresql://db.local:5432/shop",
      J.build_url(J.driver("postgresql"), { host = "db.local", database = "shop" }))
  end)

  H.it("uses an explicit port over the default", function()
    H.eq("jdbc:postgresql://db.local:6543/shop",
      J.build_url(J.driver("postgresql"), { host = "db.local", port = 6543, database = "shop" }))
  end)

  H.it("defaults the host to localhost", function()
    H.matches("//localhost:3306/", J.build_url(J.driver("mysql"), { database = "shop" }))
  end)

  H.it("expands a path for a file-backed database", function()
    local url = J.build_url(J.driver("sqlite"), { file = "~/db/shop.sqlite" })
    H.eq("jdbc:sqlite:" .. vim.fn.expand("~") .. "/db/shop.sqlite", url)
  end)

  H.it("builds a URL every driver's own parser accepts", function()
    for _, d in ipairs(J.drivers()) do
      local url = J.build_url(d, { host = "h", database = "db", file = "/tmp/x" })
      H.eq(d.key, J.subprotocol(url), d.key .. " should build a URL it can read back")
    end
  end)
end)

H.describe("Maven coordinates and cache paths", function()
  H.it("parses group:artifact and group:artifact:version", function()
    local g, a, v = J.parse_coord("org.postgresql:postgresql")
    H.eq({ "org.postgresql", "postgresql" }, { g, a })
    H.eq(nil, v)
    g, a, v = J.parse_coord("org.postgresql:postgresql:42.7.4")
    H.eq({ "org.postgresql", "postgresql", "42.7.4" }, { g, a, v })
  end)

  H.it("rejects a malformed coordinate", function()
    for _, bad in ipairs({ "", "onlyone", ":artifact", "group:" }) do
      H.eq(nil, (J.parse_coord(bad)), ("%q should not parse"):format(bad))
    end
  end)

  H.it("mirrors Maven's own layout, so the cache is recognisable", function()
    H.matches("/jars/org/postgresql/postgresql/42%.7%.4/postgresql%-42%.7%.4%.jar$",
      J.jar_path("org.postgresql", "postgresql", "42.7.4"))
  end)

  H.it("builds the right Maven Central URL", function()
    H.eq("https://repo1.maven.org/maven2/org/xerial/sqlite-jdbc/3.47.1.0/sqlite-jdbc-3.47.1.0.jar",
      J.maven_url("org.xerial", "sqlite-jdbc", "3.47.1.0"))
  end)

  H.it("keeps the cache out of the project", function()
    local saved = vim.g.kebab_jdbc_dir
    vim.g.kebab_jdbc_dir = nil
    local dir = J.cache_dir()
    vim.g.kebab_jdbc_dir = saved
    H.matches(vim.pesc(vim.fn.stdpath("data")), dir, "driver jars must never land in a repository")
  end)
end)

H.describe("the runner", function()
  H.it("ships with the plugin", function()
    local src = J.source()
    H.ok(src, "java/KebabJdbc.java should be on the runtimepath")
    H.ok(H.exists(src))
    H.matches("public final class KebabJdbc", H.read(src))
  end)

  H.it("compiles, and caches the result", function()
    if vim.fn.executable("javac") == 0 then
      H.skip("javac is not on PATH")
    end
    local saved = vim.g.kebab_jdbc_dir
    vim.g.kebab_jdbc_dir = H.tmpdir("jdbc-compile")
    local out, err = J.compile()
    H.ok(out, tostring(err))
    H.ok(H.exists(out .. "/KebabJdbc.class"), "it should have produced a class file")
    -- second call must not recompile
    local before = vim.uv.fs_stat(out .. "/KebabJdbc.class").mtime.sec
    local again = J.compile()
    H.eq(out, again)
    H.eq(before, vim.uv.fs_stat(out .. "/KebabJdbc.class").mtime.sec, "it should not recompile")
    vim.g.kebab_jdbc_dir = saved
  end)
end)

-- Everything below needs a JVM and, on a cold cache, the network. The cache
-- directory is the real one on purpose: the 12MB driver is downloaded once and
-- reused by later runs, which is also what a user experiences.
H.describe("talking to a real database over JDBC", function()
  local db, url

  local function requires_jdbc()
    if vim.fn.executable("java") == 0 or vim.fn.executable("javac") == 0 then
      H.skip("a JDK is needed for JDBC")
    end
    if vim.fn.executable("sqlite3") == 0 then
      H.skip("sqlite3 is needed to build the fixture")
    end
  end

  ---A fixture database, built with the sqlite3 CLI but read over JDBC.
  local function fixture()
    if db then
      return db, url
    end
    db = H.tmpdir("jdbc-db") .. "/shop.sqlite"
    local sql = table.concat({
      "CREATE TABLE customers (id INTEGER PRIMARY KEY, full_name TEXT, email TEXT);",
      "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total_cents INTEGER);",
      "INSERT INTO customers (full_name, email) VALUES ('Ada Lovelace','ada@example.com');",
      "INSERT INTO customers (full_name, email) VALUES ('Alan Turing','alan@example.com');",
      "INSERT INTO orders (customer_id, total_cents) VALUES (1, 4999);",
    }, "\n")
    local res = vim.system({ "sqlite3", db }, { stdin = sql, text = true }):wait(30000)
    H.eq(0, res.code, "fixture creation failed: " .. tostring(res.stderr))
    url = "jdbc:sqlite:" .. db
    return db, url
  end

  H.it("downloads the driver and assembles a classpath", function()
    requires_jdbc()
    local _, u = fixture()
    local cp, err = J.ensure(u)
    H.ok(cp, tostring(err))
    H.matches("sqlite%-jdbc.*%.jar", cp, "the driver jar should be on the classpath")
    H.matches("classes", cp, "and so should the compiled runner")
  end)

  H.it("reports the driver as installed once it is", function()
    requires_jdbc()
    local _, u = fixture()
    H.ok(J.ensure(u), "precondition: the driver installs")
    H.eq(true, J.installed(J.driver("sqlite")),
      "after a successful install the driver must report as installed")
  end)

  H.it("connects", function()
    requires_jdbc()
    local _, u = fixture()
    local lines, err = J.run(u, "ping")
    H.ok(lines, tostring(err))
    H.matches("SQLite", lines[1], "ping should name the database product")
  end)

  H.it("lists tables through DatabaseMetaData", function()
    requires_jdbc()
    local _, u = fixture()
    local lines, err = J.run(u, "tables")
    H.ok(lines, tostring(err))
    H.ok(vim.tbl_contains(lines, "customers"))
    H.ok(vim.tbl_contains(lines, "orders"))
  end)

  H.it("lists a table's columns with their types", function()
    requires_jdbc()
    local _, u = fixture()
    local lines, err = J.run(u, "columns", { args = { "customers" } })
    H.ok(lines, tostring(err))
    H.eq(3, #lines, vim.inspect(lines))
    H.matches("^id\tINTEGER", lines[1])
    H.matches("^full_name\tTEXT", lines[2])
  end)

  H.it("dumps the whole schema in one round trip, for completion", function()
    requires_jdbc()
    local _, u = fixture()
    local lines, err = J.run(u, "schema")
    H.ok(lines, tostring(err))
    H.eq(6, #lines, "3 customers columns + 3 orders columns: " .. vim.inspect(lines))
    H.matches("^customers\tid\tINTEGER", lines[1])
  end)

  H.it("runs a query and prints an aligned table", function()
    requires_jdbc()
    local _, u = fixture()
    local lines, err = J.run(u, "query", { stdin = "select full_name, email from customers order by id" })
    H.ok(lines, tostring(err))
    local text = table.concat(lines, "\n")
    H.matches("full_name", text)
    H.matches("Ada Lovelace", text)
    H.matches("Alan Turing", text)
    H.matches("%(2 rows%)", text, "it should say how many rows came back")
    H.matches("|", text, "and align the columns")
  end)

  H.it("runs a join", function()
    requires_jdbc()
    local _, u = fixture()
    local lines, err = J.run(u, "query",
      { stdin = "select c.full_name, o.total_cents from customers c join orders o on o.customer_id = c.id" })
    H.ok(lines, tostring(err))
    H.matches("4999", table.concat(lines, "\n"))
  end)

  H.it("reports an update count rather than an empty grid", function()
    requires_jdbc()
    local _, u = fixture()
    local lines, err = J.run(u, "query", { stdin = "update customers set email = email where id = 1" })
    H.ok(lines, tostring(err))
    H.matches("1 row affected", table.concat(lines, "\n"))
  end)

  H.it("passes a SQL error back instead of failing silently", function()
    requires_jdbc()
    local _, u = fixture()
    local lines, err = J.run(u, "query", { stdin = "select * from no_such_table" })
    H.falsy(lines)
    H.matches("no such table", err)
  end)

  H.it("explains a missing driver rather than saying 'no suitable driver'", function()
    requires_jdbc()
    -- A URL whose driver is not registered never reaches the JVM.
    local lines, err = J.run("jdbc:cobol:x", "ping")
    H.falsy(lines)
    H.matches("No driver registered", err)
  end)

  H.it("leaves no warm process behind for the next spec", function()
    J.shutdown_all()
    H.eq(0, J.daemon_count())
  end)
end)

-- The warm process. Measured on this machine: a one-shot query costs ~180ms,
-- almost all of it one-time per-process driver initialisation, while the same
-- query on a process that is already up costs ~0.2ms. These tests check both
-- that it is faster and -- more importantly -- that it is still correct.
H.describe("the warm JDBC process", function()
  local url

  local function requires_jdbc()
    if vim.fn.executable("java") == 0 or vim.fn.executable("javac") == 0 then
      H.skip("a JDK is needed for JDBC")
    end
    if vim.fn.executable("sqlite3") == 0 then
      H.skip("sqlite3 is needed to build the fixture")
    end
  end

  local function fixture()
    if url then
      return url
    end
    local db = H.tmpdir("warm-db") .. "/w.sqlite"
    local res = vim.system({ "sqlite3", db }, {
      stdin = "create table t(id integer primary key, a text);"
        .. "insert into t(a) values('x'),('y');",
      text = true,
    }):wait(30000)
    H.eq(0, res.code)
    url = "jdbc:sqlite:" .. db
    return url
  end

  local function with_daemon(fn)
    local saved = vim.g.kebab_jdbc_daemon
    vim.g.kebab_jdbc_daemon = true
    local ok, err = pcall(fn)
    J.shutdown_all()
    vim.g.kebab_jdbc_daemon = saved
    if not ok then error(err, 0) end
  end

  H.it("is on by default, and can be turned off", function()
    local saved = vim.g.kebab_jdbc_daemon
    vim.g.kebab_jdbc_daemon = nil
    H.eq(true, J.daemon_enabled())
    vim.g.kebab_jdbc_daemon = false
    H.eq(false, J.daemon_enabled())
    vim.g.kebab_jdbc_daemon = saved
  end)

  H.it("starts one process per connection and reuses it", function()
    requires_jdbc()
    with_daemon(function()
      local u = fixture()
      -- Earlier tests in this file run through J.run too, so the starting
      -- state has to be established rather than assumed.
      J.shutdown_all()
      H.eq(0, J.daemon_count())
      H.ok(J.run(u, "tables"), "first call should work")
      H.eq(1, J.daemon_count(), "it should have started a process")
      H.ok(J.run(u, "tables"))
      H.ok(J.run(u, "tables"))
      H.eq(1, J.daemon_count(), "and reused it rather than starting more")
    end)
  end)

  H.it("gives the same answers as a one-shot run", function()
    -- The whole point: a faster path that returns something different would be
    -- worse than the slow one.
    requires_jdbc()
    local u = fixture()
    local saved = vim.g.kebab_jdbc_daemon

    vim.g.kebab_jdbc_daemon = false
    local cold_tables = J.run(u, "tables")
    local cold_cols = J.run(u, "columns", { args = { "t" } })
    local cold_schema = J.run(u, "schema")
    local cold_query = J.run(u, "query", { stdin = "select * from t order by id" })

    vim.g.kebab_jdbc_daemon = true
    local warm_tables = J.run(u, "tables")
    local warm_cols = J.run(u, "columns", { args = { "t" } })
    local warm_schema = J.run(u, "schema")
    local warm_query = J.run(u, "query", { stdin = "select * from t order by id" })
    J.shutdown_all()
    vim.g.kebab_jdbc_daemon = saved

    H.eq(cold_tables, warm_tables, "tables should match")
    H.eq(cold_cols, warm_cols, "columns should match")
    H.eq(cold_schema, warm_schema, "schema should match")
    H.eq(cold_query, warm_query, "query output should match")
  end)

  H.it("is dramatically faster once up", function()
    requires_jdbc()
    with_daemon(function()
      local u = fixture()
      J.run(u, "query", { stdin = "select 1" }) -- pay the start-up

      local t0 = vim.uv.hrtime()
      for _ = 1, 10 do
        H.ok(J.run(u, "query", { stdin = "select * from t" }))
      end
      local mean = (vim.uv.hrtime() - t0) / 1e6 / 10
      -- A one-shot run is ~180ms here. Asserting a generous 40ms keeps this
      -- from being a flaky benchmark while still failing loudly if the warm
      -- path silently stops being used.
      H.ok(mean < 40, ("expected a warm query well under 40ms, got %.1fms"):format(mean))
    end)
  end)

  H.it("handles SQL containing newlines and sentinel-looking lines", function()
    -- Why the protocol is length-prefixed rather than sentinel-delimited.
    requires_jdbc()
    with_daemon(function()
      local u = fixture()
      local lines, err = J.run(u, "query", {
        stdin = "select *\nfrom t\n-- OK\t0\n-- --KEBAB-END--\norder by id",
      })
      H.ok(lines, tostring(err))
      H.matches("%(2 rows%)", table.concat(lines, "\n"))
    end)
  end)

  H.it("passes a SQL error back and stays usable", function()
    requires_jdbc()
    with_daemon(function()
      local u = fixture()
      local bad, err = J.run(u, "query", { stdin = "select * from nope" })
      H.falsy(bad)
      H.matches("no such table", err)
      -- the process must survive a bad query
      H.eq(1, J.daemon_count(), "a SQL error should not kill the process")
      H.ok(J.run(u, "tables"), "and it should still answer")
    end)
  end)

  H.it("answers many requests in order", function()
    requires_jdbc()
    with_daemon(function()
      local u = fixture()
      for i = 1, 15 do
        local lines, err = J.run(u, "query", { stdin = ("select %d as n"):format(i) })
        H.ok(lines, tostring(err))
        H.matches(tostring(i), table.concat(lines, "\n"), "response " .. i .. " should match its request")
      end
    end)
  end)

  H.it("shuts down cleanly, and again is a no-op", function()
    requires_jdbc()
    local u = fixture()
    vim.g.kebab_jdbc_daemon = true
    J.run(u, "tables")
    H.eq(1, J.daemon_count())
    H.eq(true, J.shutdown(u))
    H.eq(0, J.daemon_count())
    H.eq(false, J.shutdown(u), "shutting down twice should be harmless")
    J.shutdown_all()
  end)

  H.it("restarts after a shutdown", function()
    requires_jdbc()
    with_daemon(function()
      local u = fixture()
      J.run(u, "tables")
      J.shutdown(u)
      H.ok(J.run(u, "tables"), "it should start a fresh process")
      H.eq(1, J.daemon_count())
    end)
  end)

  H.it("falls back to a one-shot run when the process cannot start", function()
    -- A URL with no registered driver never gets a process; the caller should
    -- still get the real error rather than a hang.
    local lines, err = J.run("jdbc:cobol:x", "ping")
    H.falsy(lines)
    H.matches("No driver registered", err)
  end)
end)

H.describe("picking a cached driver version", function()
  H.it("compares versions numerically, not as strings", function()
    H.ok(J.version_lt("9.4.1212", "42.6.0"), "42.6.0 is newer, though it sorts lower as a string")
    H.falsy(J.version_lt("42.6.0", "9.4.1212"))
    H.ok(J.version_lt("2.0", "2.0.1"))
    H.falsy(J.version_lt("2.0.1", "2.0"))
    H.ok(J.version_lt("2.0-rc1", "2.0"), "a pre-release is older than the release")
    H.falsy(J.version_lt("2.0", "2.0-rc1"))
    H.falsy(J.version_lt("1.2.3", "1.2.3"))
    H.ok(J.version_lt("2.2.224", "2.3.0"))
  end)

  H.it("takes the newest jar on disk, whatever order readdir gives", function()
    local cache = H.tmpdir("jdbc-cache")
    local saved = vim.g.kebab_jdbc_dir
    vim.g.kebab_jdbc_dir = cache
    -- two cached versions of one driver, the older one created last. A unique
    -- coordinate keeps resolve()'s memo table out of it, and because both are
    -- cached no network lookup is needed.
    for _, v in ipairs({ "42.6.0", "9.4.1212" }) do
      local dir = ("%s/jars/io/example/fakedriver/%s"):format(cache, v)
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile({ "" }, ("%s/fakedriver-%s.jar"):format(dir, v))
    end
    local spec, err = J.resolve("io.example:fakedriver")
    vim.g.kebab_jdbc_dir = saved
    H.ok(spec, tostring(err))
    H.eq("42.6.0", spec.version, "an old driver would fail to authenticate against a modern server")
  end)
end)

H.describe("building a JDBC url", function()
  -- gsub treats % in a replacement string as an escape, so an unescaped
  -- substitution silently rewrites the path.
  H.it("keeps a percent sign in a path or database name", function()
    H.eq(
      "jdbc:sqlite:/tmp/100%/shop.sqlite",
      J.build_url({ url = "jdbc:sqlite:{file}" }, { file = "/tmp/100%/shop.sqlite" })
    )
    H.eq(
      "jdbc:postgresql://h:5432/a%1b",
      J.build_url(
        { url = "jdbc:postgresql://{host}:{port}/{database}", default_port = 5432 },
        { host = "h", database = "a%1b" }
      )
    )
  end)
end)

-- A timeout used to fall through to a one-shot run of the *same* payload, so a
-- statement the server had already executed was applied a second time and the
-- caller was told it succeeded.
H.describe("a request that times out", function()
  local function requires_jdbc()
    if vim.fn.executable("java") == 0 or vim.fn.executable("javac") == 0 then
      H.skip("a JDK is needed for JDBC")
    end
    if vim.fn.executable("sqlite3") == 0 then
      H.skip("sqlite3 is needed to build the fixture")
    end
  end

  H.it("is reported, and never re-runs the statement", function()
    requires_jdbc()
    local db = H.tmpdir("jdbc-timeout") .. "/t.sqlite"
    local res = vim.system({ "sqlite3", db }, {
      stdin = "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);",
      text = true,
    }):wait(30000)
    H.eq(0, res.code, "fixture creation failed")
    local url = "jdbc:sqlite:" .. db

    -- warm it first, so the next frame really does reach a live JVM
    local ok, err = J.run(url, "query", { stdin = "select 1", timeout = 120000 })
    H.ok(ok, tostring(err))

    local lines, run_err = J.run(url, "query", { stdin = "insert into t (v) values ('x')", timeout = 1 })
    H.falsy(lines, "a timeout is a failure, not a success")
    H.matches("did not answer", run_err)
    H.matches("may already have run", run_err, "the user has to be told it might have been applied")

    -- give the warm process time to finish and commit before counting
    vim.wait(4000, function() return false end, 100)
    local count = vim.trim(vim.fn.system({ "sqlite3", db, "select count(*) from t where v='x'" }))
    H.ok(count == "0" or count == "1", "the insert must not be applied twice, got " .. count)
    J.shutdown(url)
  end)

  H.it("still falls back when the warm process never started", function()
    requires_jdbc()
    -- nothing was sent, so a one-shot retry is safe and must still happen
    local saved = vim.g.kebab_jdbc_daemon
    vim.g.kebab_jdbc_daemon = false
    local lines, err = J.run("jdbc:sqlite::memory:", "query", { stdin = "select 1", timeout = 60000 })
    vim.g.kebab_jdbc_daemon = saved
    H.ok(lines, "the one-shot path is still the fallback: " .. tostring(err))
  end)

  H.it("spells a sub-second timeout in milliseconds", function()
    H.eq("1ms", J.describe_timeout(1))
    H.eq("300s", J.describe_timeout(300000))
    H.eq("1.5s", J.describe_timeout(1500))
  end)
end)

-- A multi-statement payload went to a single Statement.execute(), and SQLite's
-- driver compiles only the first statement -- so everything after the first `;`
-- silently never ran while the bridge reported success. A half-applied
-- migration is the worst answer available, so the splitting is done in the
-- bridge rather than hoped for from the driver.
H.describe("running a script of several statements", function()
  local db, url

  local function requires_jdbc()
    if vim.fn.executable("java") == 0 or vim.fn.executable("javac") == 0 then
      H.skip("a JDK is needed for JDBC")
    end
    if vim.fn.executable("sqlite3") == 0 then
      H.skip("sqlite3 is needed to build the fixture")
    end
  end

  local function fixture()
    if db then
      return db, url
    end
    db = H.tmpdir("jdbc-script") .. "/s.sqlite"
    local sql = table.concat({
      "CREATE TABLE c (id INTEGER PRIMARY KEY, v TEXT);",
      "CREATE TABLE user_data (a TEXT, b TEXT);",
      "CREATE TABLE userXdata (zzz TEXT);",
      "CREATE TABLE wide (name TEXT);",
      "INSERT INTO wide (name) VALUES ('東京都中央区'),('ok');",
      "CREATE TABLE blobs (b BLOB);",
      "INSERT INTO blobs (b) VALUES (x'deadbeef');",
    }, "\n")
    local res = vim.system({ "sqlite3", db }, { stdin = sql, text = true }):wait(30000)
    H.eq(0, res.code, "fixture creation failed: " .. tostring(res.stderr))
    url = "jdbc:sqlite:" .. db
    return db, url
  end

  local function run(sql)
    local _, u = fixture()
    return J.run(u, "query", { stdin = sql, timeout = 120000 })
  end

  local function count()
    local lines = run("select count(*) from c")
    return tonumber((table.concat(lines or {}, "\n"):match("(%d+)")))
  end

  H.it("applies every statement, not just the first", function()
    requires_jdbc()
    local before = count()
    local lines, err = run("insert into c (v) values ('a');\ninsert into c (v) values ('b');")
    H.ok(lines, tostring(err))
    H.eq(2, select(2, table.concat(lines, "\n"):gsub("row affected", "")), "both inserts should report")
    H.eq(before + 2, count(), "both rows should be there")
  end)

  H.it("does not split on a semicolon inside a literal or a comment", function()
    requires_jdbc()
    local before = count()
    H.ok(run("insert into c (v) values ('a;b');"))
    H.eq(before + 1, count())
    local lines = run("select v from c where v = 'a;b'")
    H.matches("a;b", table.concat(lines or {}, "\n"), "the literal should be intact")

    -- a comment holding a semicolon, and a trailing one
    local ok2, err2 = run("-- a comment with ; in it\nselect count(*) from c; /* trailing ; */")
    H.ok(ok2, tostring(err2))
    H.ok(run("select 1; -- just a comment"), "a trailing comment is not a statement")
  end)

  H.it("says which statement failed, and how many had applied", function()
    requires_jdbc()
    local before = count()
    local lines, err = run("insert into c (v) values ('y'); insert into nosuch values (1);")
    H.falsy(lines, "the script failed")
    H.matches("statement 2 of 2", err, "it has to name the one that failed: " .. tostring(err))
    H.matches("1 applied", err, "and say how far it got: " .. tostring(err))
    H.eq(before + 1, count(), "the first statement really did apply")
  end)

  H.it("treats a comment-only payload as nothing to run", function()
    requires_jdbc()
    local lines, err = run("/* only a comment */")
    H.falsy(lines)
    H.matches("nothing to run", err)
  end)

  -- query() and columns() used to call System.exit(2), which in serve mode
  -- killed the JVM mid-protocol: no reply, the shared connection never closed,
  -- and every other request queued on it failed.
  H.it("a bad request fails the request, not the warm process", function()
    requires_jdbc()
    local _, u = fixture()
    H.ok(J.run(u, "query", { stdin = "select 1", timeout = 120000 }), "warm it up first")
    local daemons = J.daemon_count()
    H.ok(daemons > 0, "there should be a warm process")

    local lines, err = J.run(u, "query", { stdin = "   ", timeout = 60000 })
    H.falsy(lines)
    H.matches("nothing to run", err)
    H.eq(daemons, J.daemon_count(), "the warm process must survive a bad request")
    H.ok(J.run(u, "query", { stdin = "select 1", timeout = 60000 }), "and still answer the next one")

    local cols, cerr = J.run(u, "columns", { args = { "" }, timeout = 60000 })
    H.falsy(cols)
    H.matches("table name", cerr)
    H.eq(daemons, J.daemon_count(), "same for a bad columns request")
  end)

  H.it("does not read `_` in a table name as a wildcard", function()
    requires_jdbc()
    local _, u = fixture()
    local lines, err = J.run(u, "columns", { args = { "user_data" }, timeout = 60000 })
    H.ok(lines, tostring(err))
    local text = table.concat(lines, "\n")
    H.matches("^a\t", text)
    H.falsy(text:find("zzz"), "userXdata's column must not be attributed to user_data: " .. text)
  end)

  H.it("renders a blob as hex, not a Java identity hash", function()
    requires_jdbc()
    local lines, err = run("select b from blobs")
    H.ok(lines, tostring(err))
    local text = table.concat(lines, "\n")
    H.matches("0xdeadbeef", text, "got: " .. text)
    H.falsy(text:find("%[B@"), "an identity hash is a different value every run: " .. text)
  end)

  H.it("aligns a grid by display width, not UTF-16 length", function()
    requires_jdbc()
    local lines, err = run("select name from wide")
    H.ok(lines, tostring(err))
    -- the separator row is as wide as the widest cell, and a 6-character CJK
    -- string occupies 12 columns
    local sep
    for _, l in ipairs(lines) do
      if l:match("^%-+$") then
        sep = l
      end
    end
    H.ok(sep, "there should be a separator row: " .. table.concat(lines, "|"))
    H.eq(12, #sep, "the column should be 12 display columns wide, got " .. #sep)
  end)
end)

-- vim.wait pumps vim.schedule callbacks, so a second jdbc.run on the same URL
-- used to start *inside* the first one's wait. The per-URL process is a single
-- slot: whichever request timed out first called M.shutdown(url), killing the
-- JVM mid-statement and failing the other in-flight request.
H.describe("two requests on one connection", function()
  local function requires_jdbc()
    if vim.fn.executable("java") == 0 or vim.fn.executable("javac") == 0 then
      H.skip("a JDK is needed for JDBC")
    end
    if vim.fn.executable("sqlite3") == 0 then
      H.skip("sqlite3 is needed to build the fixture")
    end
  end

  H.it("does not let the second corrupt or kill the first", function()
    requires_jdbc()
    local db = H.tmpdir("jdbc-reentrant") .. "/r.sqlite"
    local res = vim.system({ "sqlite3", db }, {
      stdin = "CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('alpha');",
      text = true,
    }):wait(30000)
    H.eq(0, res.code, tostring(res.stderr))
    local url = "jdbc:sqlite:" .. db

    -- warm it, so the next request really goes to a live process
    H.ok(J.run(url, "query", { stdin = "select 1", timeout = 120000 }))

    -- fires inside the first request's vim.wait
    local second = {}
    vim.schedule(function()
      second.lines, second.err = J.run(url, "query", { stdin = "select 'beta' as b", timeout = 60000 })
    end)
    local first, ferr = J.run(url, "query", { stdin = "select v from t", timeout = 60000 })

    H.ok(first, "the first request must still be answered: " .. tostring(ferr))
    H.matches("alpha", table.concat(first, "\n"), "and with its own result")

    H.wait(60000, function()
      return second.lines ~= nil or second.err ~= nil
    end, "the second request should finish too")
    H.ok(second.lines, "the second must not be lost: " .. tostring(second.err))
    H.matches("beta", table.concat(second.lines, "\n"), "and get its own result, not the first's")

    -- and the connection is still usable afterwards
    local after, aerr = J.run(url, "query", { stdin = "select v from t", timeout = 60000 })
    H.ok(after, "the process must survive both: " .. tostring(aerr))
    H.matches("alpha", table.concat(after, "\n"))
    J.shutdown(url)
  end)
end)

-- A driver jar is fetched over the network and then put on a classpath that
-- `java` executes, so it is worth knowing it is the jar Maven Central
-- published. Central publishes a .sha1 beside every artifact, so this costs
-- one extra GET.
H.describe("trusting a downloaded driver jar", function()
  H.it("rejects a version string that is really a path", function()
    H.ok(J.is_version("42.6.0"))
    H.ok(J.is_version("2.2.224"))
    H.ok(J.is_version("1.0-rc1"))
    H.ok(J.is_version("9.4.1212.jre7"), "a real postgres version")
    -- <release>../../../etc/evil</release> became part of a filesystem path,
    -- and mkdir -p would have created it
    H.falsy(J.is_version("../../../etc/evil"))
    H.falsy(J.is_version("a/b"))
    H.falsy(J.is_version(""))
    H.falsy(J.is_version("x; rm -rf /"))
    H.falsy(J.is_version(nil))
    H.falsy(J.is_version(string.rep("9", 70)), "implausibly long")
  end)

  H.it("refuses to cache a jar whose checksum does not match", function()
    if vim.fn.executable("curl") == 0 then
      H.skip("curl is needed to fetch the published checksum")
    end
    if vim.fn.executable("sha1sum") == 0 and vim.fn.executable("shasum") == 0 then
      H.skip("no sha1sum available")
    end
    local dir = H.tmpdir("jar-verify")
    local fake = dir .. "/tampered.jar"
    H.write(fake, "not a jar at all")
    local url = J.maven_url("org.xerial", "sqlite-jdbc", "3.46.0.0")
    local ok, err = J.verify_jar(fake, url)
    if ok then
      H.skip("could not reach Maven Central to fetch the checksum")
    end
    H.falsy(ok)
    H.matches("Checksum mismatch", err, "got: " .. tostring(err))
  end)

  H.it("accepts the jar Maven Central actually published", function()
    if vim.fn.executable("curl") == 0 or vim.fn.executable("java") == 0 then
      H.skip("curl and a JDK are needed")
    end
    local saved = vim.g.kebab_jdbc_dir
    local strict = vim.g.kebab_jdbc_require_checksum
    vim.g.kebab_jdbc_dir = H.tmpdir("jar-fetch")
    vim.g.kebab_jdbc_require_checksum = true
    local path, err = J.fetch_jar("org.xerial:sqlite-jdbc:3.46.0.0")
    vim.g.kebab_jdbc_dir = saved
    vim.g.kebab_jdbc_require_checksum = strict
    if not path then
      H.skip("could not reach Maven Central: " .. tostring(err))
    end
    H.ok(H.exists(path), "the jar should be cached at " .. path)
    H.falsy(H.exists(path .. ".part"), "and no partial file left behind")
  end)
end)

-- Warm processes are keyed by URL, but credentials are baked into the process
-- environment once, at spawn. Two saved connections can share a URL and differ
-- only in user, so a "readonly" connection reused a daemon started as "admin"
-- and executed as admin, silently -- while the one-shot path, which passes the
-- environment per run, behaved correctly.
H.describe("a warm process and the credentials it was started with", function()
  H.it("is not reused for a different user on the same URL", function()
    if vim.fn.executable("java") == 0 or vim.fn.executable("javac") == 0 then
      H.skip("a JDK is needed for JDBC")
    end
    if vim.fn.executable("sqlite3") == 0 then
      H.skip("sqlite3 is needed to build the fixture")
    end
    local db = H.tmpdir("jdbc-creds") .. "/c.sqlite"
    local res = vim.system({ "sqlite3", db }, { stdin = "create table t (v text);", text = true }):wait(30000)
    H.eq(0, res.code, tostring(res.stderr))
    local url = "jdbc:sqlite:" .. db

    local saved = vim.g.kebab_db_credentials
    local function run_as(user)
      vim.g.kebab_db_credentials = { [url] = { user = user, password = user } }
      local lines, err = J.run(url, "query", { stdin = "select 1", timeout = 120000 })
      H.ok(lines, tostring(err))
      return J.daemon_pid(url)
    end

    local ok, err = pcall(function()
      local first = run_as("readonly")
      H.ok(first, "a warm process should be running")
      H.eq(first, run_as("readonly"), "the same credentials must reuse it")
      local other = run_as("admin")
      H.ok(other ~= first, "a different user must get its own process, not admin rights by accident")
      H.ok(run_as("readonly") ~= other, "and back again")
    end)
    vim.g.kebab_db_credentials = saved
    J.shutdown(url)
    H.ok(ok, tostring(err))
  end)
end)
