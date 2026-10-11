-- JDBC: drivers fetched from Maven Central, connections over JDBC.
--
-- This is how a dedicated database IDE works, rather than how vim-dadbod does.
-- dadbod shells out to the
-- native client -- psql, mysql, sqlite3 -- so a database you have no client
-- installed for simply does not work. JDBC needs only a driver jar and the JVM,
-- and `DatabaseMetaData` gives real schema introspection instead of guessing
-- from SQL text.
--
-- Deliberately not using Maven to *fetch* the jars. `mvn
-- dependency:build-classpath` could not resolve its own plugin on this machine
-- even with Maven Central reachable, and requiring mvn at all would exclude
-- anyone who has a JDK but no Maven. A jar is an HTTPS GET from
-- repo1.maven.org, so that is what this does; the transitive dependencies that
-- matter are few enough to name in the registry.
local M = {}

-- ------------------------------------------------------------------ drivers

---@class kebab.JdbcDriver
---@field key string        subprotocol, i.e. the bit after "jdbc:"
---@field label string
---@field coords string[]   Maven coordinates, "group:artifact" or "group:artifact:version"
---@field url string        a template for building a URL
---@field default_port? number
---@field file? boolean     true for file-backed databases (sqlite, duckdb, h2)

local BUILTIN = {
  {
    key = "postgresql",
    label = "PostgreSQL",
    coords = { "org.postgresql:postgresql" },
    url = "jdbc:postgresql://{host}:{port}/{database}",
    default_port = 5432,
  },
  {
    key = "mysql",
    label = "MySQL",
    -- mysql-connector-j is the one common driver with a transitive dependency
    -- that is actually needed at runtime.
    coords = { "com.mysql:mysql-connector-j", "com.google.protobuf:protobuf-java" },
    url = "jdbc:mysql://{host}:{port}/{database}",
    default_port = 3306,
  },
  {
    key = "mariadb",
    label = "MariaDB",
    coords = { "org.mariadb.jdbc:mariadb-java-client" },
    url = "jdbc:mariadb://{host}:{port}/{database}",
    default_port = 3306,
  },
  {
    key = "sqlite",
    label = "SQLite",
    coords = { "org.xerial:sqlite-jdbc" },
    url = "jdbc:sqlite:{file}",
    file = true,
  },
  {
    key = "sqlserver",
    label = "SQL Server",
    coords = { "com.microsoft.sqlserver:mssql-jdbc" },
    url = "jdbc:sqlserver://{host}:{port};databaseName={database};encrypt=false",
    default_port = 1433,
  },
  {
    key = "oracle",
    label = "Oracle",
    coords = { "com.oracle.database.jdbc:ojdbc11" },
    url = "jdbc:oracle:thin:@{host}:{port}/{database}",
    default_port = 1521,
  },
  {
    key = "h2",
    label = "H2",
    coords = { "com.h2database:h2" },
    url = "jdbc:h2:{file}",
    file = true,
  },
  {
    key = "duckdb",
    label = "DuckDB",
    coords = { "org.duckdb:duckdb_jdbc" },
    url = "jdbc:duckdb:{file}",
    file = true,
  },
  {
    key = "clickhouse",
    label = "ClickHouse",
    coords = { "com.clickhouse:clickhouse-jdbc" },
    url = "jdbc:clickhouse://{host}:{port}/{database}",
    default_port = 8123,
  },
}

---Known drivers, with the user's own merged in by key -- the same extension
---point shape as lua/kebab/languages/.
---@return kebab.JdbcDriver[]
function M.drivers()
  local out = vim.deepcopy(BUILTIN)
  local extra = vim.g.kebab_jdbc_drivers
  if type(extra) == "function" then
    local ok, res = pcall(extra)
    extra = ok and res or nil
  end
  if type(extra) == "table" then
    for _, driver in ipairs(extra) do
      if type(driver) == "table" and driver.key then
        local replaced = false
        for i, existing in ipairs(out) do
          if existing.key == driver.key then
            out[i] = vim.tbl_deep_extend("force", existing, driver)
            replaced = true
            break
          end
        end
        if not replaced then
          out[#out + 1] = driver
        end
      end
    end
  end
  return out
end

---@param key string
---@return kebab.JdbcDriver|nil
function M.driver(key)
  for _, d in ipairs(M.drivers()) do
    if d.key == key then
      return d
    end
  end
  return nil
end

---The subprotocol of a JDBC URL: "jdbc:postgresql://..." -> "postgresql".
---@param url string
---@return string|nil
function M.subprotocol(url)
  if type(url) ~= "string" then
    return nil
  end
  local sub = url:match("^jdbc:([%w_]+):")
  if sub == "oracle" then
    return "oracle"
  end
  return sub
end

---The driver a URL needs.
---@param url string
---@return kebab.JdbcDriver|nil, string|nil err
function M.driver_for(url)
  local sub = M.subprotocol(url)
  if not sub then
    return nil, ("%q is not a JDBC URL (expected jdbc:<database>:...)"):format(tostring(url))
  end
  local driver = M.driver(sub)
  if not driver then
    local keys = vim.tbl_map(function(d) return d.key end, M.drivers())
    table.sort(keys)
    return nil, ("No driver registered for jdbc:%s: (have: %s)"):format(sub, table.concat(keys, ", "))
  end
  return driver
end

-- -------------------------------------------------------------------- paths

function M.cache_dir()
  return (vim.g.kebab_jdbc_dir and require("kebab.path").expand(vim.g.kebab_jdbc_dir))
    or (vim.fn.stdpath("data") .. "/kebab/jdbc")
end

---Split "group:artifact" or "group:artifact:version".
---@param coord string
---@return string|nil group, string|nil artifact, string|nil version
function M.parse_coord(coord)
  local parts = vim.split(coord or "", ":", { plain = true })
  if #parts < 2 or parts[1] == "" or parts[2] == "" then
    return nil, nil, nil
  end
  return parts[1], parts[2], (parts[3] ~= "" and parts[3] or nil)
end

---Where a jar is cached, mirroring Maven's own layout so it is recognisable.
function M.jar_path(group, artifact, version)
  return ("%s/jars/%s/%s/%s/%s-%s.jar")
    :format(M.cache_dir(), group:gsub("%.", "/"), artifact, version, artifact, version)
end

function M.maven_url(group, artifact, version)
  return ("https://repo1.maven.org/maven2/%s/%s/%s/%s-%s.jar")
    :format(group:gsub("%.", "/"), artifact, version, artifact, version)
end

-- ----------------------------------------------------------------- download

---The newest release of an artifact, from Maven's own metadata.
---@param group string
---@param artifact string
---@return string|nil version, string|nil err
function M.latest_version(group, artifact)
  local url = ("https://repo1.maven.org/maven2/%s/%s/maven-metadata.xml")
    :format(group:gsub("%.", "/"), artifact)
  local res = vim.system({ "curl", "-sfL", "--max-time", "30", url }, { text = true }):wait(40000)
  if res.code ~= 0 then
    return nil, ("Could not reach Maven Central for %s:%s"):format(group, artifact)
  end
  local version = (res.stdout or ""):match("<release>([^<]+)</release>")
    or (res.stdout or ""):match("<latest>([^<]+)</latest>")
  if not version then
    return nil, ("No released version found for %s:%s"):format(group, artifact)
  end
  -- This string becomes part of a filesystem path and a URL, so it has to look
  -- like a version. A `<release>../../../etc</release>` from anything that can
  -- answer for the repository would otherwise write the downloaded body
  -- outside the cache directory, which `mkdir -p` would happily create.
  if not M.is_version(version) then
    return nil, ("Maven Central returned an implausible version for %s:%s: %q"):format(group, artifact, version)
  end
  return version
end

---Does this look like a version, rather than a path or an injection?
---@param version any
function M.is_version(version)
  if type(version) ~= "string" or version == "" or #version > 64 then
    return false
  end
  return version:match("^[%w][%w%.%-%+_]*$") ~= nil
end

---Cached version for a coordinate, so a resolved version is reused rather than
---re-fetched from Maven on every call.
local resolved = {}

---Resolve a coordinate to a concrete version.
function M.resolve(coord)
  local group, artifact, version = M.parse_coord(coord)
  if not group then
    return nil, ("%q is not a Maven coordinate"):format(tostring(coord))
  end
  if version then
    return { group = group, artifact = artifact, version = version }
  end
  if resolved[coord] then
    return resolved[coord]
  end
  -- An already-downloaded jar answers the question without a network call, so
  -- a cached driver keeps working offline.
  local dir = ("%s/jars/%s/%s"):format(M.cache_dir(), group:gsub("%.", "/"), artifact)
  local fd = vim.uv.fs_scandir(dir)
  if fd then
    local newest
    while true do
      local name, typ = vim.uv.fs_scandir_next(fd)
      if not name then break end
      if typ == "directory" and vim.uv.fs_stat(M.jar_path(group, artifact, name)) then
        -- Compare: readdir order is filesystem-dependent, so taking the last
        -- entry can pin an old driver for the whole session -- and once it is
        -- memoized, M.installed() reports success and no network lookup ever
        -- corrects it.
        if newest == nil or M.version_lt(newest, name) then
          newest = name
        end
      end
    end
    if newest then
      resolved[coord] = { group = group, artifact = artifact, version = newest }
      return resolved[coord]
    end
  end
  local latest, err = M.latest_version(group, artifact)
  if not latest then
    return nil, err
  end
  resolved[coord] = { group = group, artifact = artifact, version = latest }
  return resolved[coord]
end

---A timeout in words, so a sub-second one does not read as "0s".
---@param ms number
function M.describe_timeout(ms)
  if ms < 1000 then
    return ("%dms"):format(ms)
  end
  return ("%gs"):format(ms / 1000)
end

---Is version `a` older than version `b`?
---
---Numeric segments compare as numbers (so 9.4.1212 < 42.6.0, which a string
---comparison gets backwards), and a version with a pre-release suffix sorts
---below the same version without one.
---@param a string
---@param b string
function M.version_lt(a, b)
  local function parts(v)
    local out = {}
    for chunk in tostring(v):gmatch("[^%.%-%+_]+") do
      out[#out + 1] = tonumber(chunk) or chunk
    end
    return out
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i], pb[i]
    if x == nil then
      -- 2.0 vs 2.0.1 -> shorter is older; 2.0 vs 2.0-rc1 -> the suffix is older
      return type(y) == "number"
    end
    if y == nil then
      return type(x) ~= "number"
    end
    if x ~= y then
      if type(x) == "number" and type(y) == "number" then
        return x < y
      end
      -- a number outranks a word: 2.1 is newer than 2.0-rc
      if type(x) ~= type(y) then
        return type(x) ~= "number"
      end
      return tostring(x) < tostring(y)
    end
  end
  return false
end

---Download one jar if it is not cached. Returns path, err.
function M.fetch_jar(coord)
  local spec, err = M.resolve(coord)
  if not spec then
    return nil, err
  end
  local path = M.jar_path(spec.group, spec.artifact, spec.version)
  if vim.uv.fs_stat(path) then
    return path
  end
  if not M.is_version(spec.version) then
    return nil, ("%s:%s has an implausible version: %q"):format(spec.group, spec.artifact, tostring(spec.version))
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local url = M.maven_url(spec.group, spec.artifact, spec.version)
  local tmp = path .. ".part"
  local res = vim.system(
    -- --proto/--proto-redir: without them an https -> http redirect is
    -- followed in the clear, and this jar goes straight onto a classpath that
    -- `java` then executes.
    { "curl", "-sfL", "--proto", "=https", "--proto-redir", "=https", "--max-time", "300", "-o", tmp, url },
    { text = true }
  ):wait(310000)
  if res.code ~= 0 then
    pcall(vim.fn.delete, tmp)
    return nil, ("Download failed: %s"):format(url)
  end
  -- Rename only once the whole file is there, so an interrupted download does
  -- not leave a truncated jar that looks cached.
  if not vim.uv.fs_stat(tmp) or (vim.uv.fs_stat(tmp).size or 0) == 0 then
    pcall(vim.fn.delete, tmp)
    return nil, ("Downloaded nothing from %s"):format(url)
  end
  -- Maven Central publishes a .sha1 beside every artifact, so verifying costs
  -- one extra GET -- worth it for a file that is about to be executed.
  local verified, why = M.verify_jar(tmp, url)
  if not verified then
    pcall(vim.fn.delete, tmp)
    return nil, why
  end
  os.rename(tmp, path)
  return path
end

---Check a downloaded jar against the `.sha1` Maven Central publishes for it.
---
---Returns true when it matches, and also when the checksum cannot be fetched
---or no sha1sum is available -- refusing to work offline would be worse than
---the risk, and `vim.g.kebab_jdbc_require_checksum` makes it strict.
---@param file string
---@param url string the jar's URL
---@return boolean ok, string|nil err
function M.verify_jar(file, url)
  local strict = vim.g.kebab_jdbc_require_checksum == true
  local tool, flag
  for _, candidate in ipairs({ { "sha1sum", nil }, { "shasum", "-a1" } }) do
    if vim.fn.executable(candidate[1]) == 1 then
      tool, flag = candidate[1], candidate[2]
      break
    end
  end
  if not tool then
    if strict then
      return false, "no sha1sum available to verify " .. url
    end
    return true
  end

  local res = vim.system({
    "curl",
    "-sfL",
    "--proto",
    "=https",
    "--proto-redir",
    "=https",
    "--max-time",
    "30",
    url .. ".sha1",
  }, { text = true }):wait(40000)
  if res.code ~= 0 then
    if strict then
      return false, "could not fetch the checksum for " .. url
    end
    return true
  end
  local want = (res.stdout or ""):match("%x%x%x%x%x%x%x%x+")
  if not want then
    if strict then
      return false, "no usable checksum published for " .. url
    end
    return true
  end

  local argv = flag and { tool, flag, file } or { tool, file }
  local sum = vim.system(argv, { text = true }):wait(60000)
  local got = (sum.stdout or ""):match("^(%x+)")
  if sum.code ~= 0 or not got then
    if strict then
      return false, "could not compute a checksum for " .. file
    end
    return true
  end
  if got:lower() ~= want:lower() then
    return false, ("Checksum mismatch for %s (expected %s, got %s)"):format(url, want, got)
  end
  return true
end

---Is every jar for `driver` already cached?
function M.installed(driver)
  for _, coord in ipairs(driver.coords or {}) do
    local group, artifact, version = M.parse_coord(coord)
    if not group then
      return false
    end
    if version then
      if not vim.uv.fs_stat(M.jar_path(group, artifact, version)) then
        return false
      end
    else
      local spec = resolved[coord]
      if spec and vim.uv.fs_stat(M.jar_path(spec.group, spec.artifact, spec.version)) then
        -- cached
      else
        local dir = ("%s/jars/%s/%s"):format(M.cache_dir(), group:gsub("%.", "/"), artifact)
        local found = false
        local fd = vim.uv.fs_scandir(dir)
        while fd do
          local name, typ = vim.uv.fs_scandir_next(fd)
          if not name then break end
          if typ == "directory" and vim.uv.fs_stat(M.jar_path(group, artifact, name)) then
            found = true
          end
        end
        if not found then
          return false
        end
      end
    end
  end
  return true
end

---Download whatever `driver` is missing. Returns jar paths, err.
function M.install(driver)
  local jars = {}
  for _, coord in ipairs(driver.coords or {}) do
    local path, err = M.fetch_jar(coord)
    if not path then
      return nil, err
    end
    jars[#jars + 1] = path
  end
  return jars
end

-- ------------------------------------------------------------------ runner

---Where the compiled runner lives.
function M.classes_dir()
  return M.cache_dir() .. "/classes"
end

---The runner source, found on the runtimepath so it ships with the plugin.
function M.source()
  return vim.api.nvim_get_runtime_file("java/KebabJdbc.java", false)[1]
end

---Compile the runner if it is missing or older than its source.
---
---Source-file mode (`java Foo.java`) would avoid this, but it recompiles on
---every run: measured at 400-750ms against 200-260ms precompiled, and the
---variance is worse than the mean.
---@return string|nil classes_dir, string|nil err
function M.compile()
  local src = M.source()
  if not src then
    return nil, "java/KebabJdbc.java is not on the runtimepath"
  end
  if vim.fn.executable("javac") == 0 then
    return nil, "javac is not on PATH; a JDK is needed for JDBC connections"
  end
  local out = M.classes_dir()
  local class = out .. "/KebabJdbc.class"
  local src_stat = vim.uv.fs_stat(src)
  local class_stat = vim.uv.fs_stat(class)
  if class_stat and src_stat and class_stat.mtime.sec >= src_stat.mtime.sec then
    return out
  end
  vim.fn.mkdir(out, "p")
  local res = vim.system({ "javac", "-nowarn", "-d", out, src }, { text = true }):wait(120000)
  if res.code ~= 0 then
    return nil, "Could not compile the JDBC runner:\n" .. ((res.stderr or "") .. (res.stdout or ""))
  end
  return out
end

---Everything needed to run a query against `url`: driver jars downloaded, the
---runner compiled, and the classpath assembled.
---@param url string
---@return string|nil classpath, string|nil err
function M.ensure(url)
  local driver, err = M.driver_for(url)
  if not driver then
    return nil, err
  end
  if not M.installed(driver) then
    vim.notify(("Downloading the %s JDBC driver from Maven Central…"):format(driver.label))
  end
  local jars
  jars, err = M.install(driver)
  if not jars then
    return nil, err
  end
  local classes
  classes, err = M.compile()
  if not classes then
    return nil, err
  end
  local parts = vim.deepcopy(jars)
  parts[#parts + 1] = classes
  return table.concat(parts, ":")
end

---The argv that runs `mode` against `url`. SQL goes in on stdin.
---@param url string
---@param mode "query"|"tables"|"columns"|"schema"|"ping"
---@param extra? string[]
---@return table|nil argv, string|nil err
function M.command(url, mode, extra)
  local classpath, err = M.ensure(url)
  if not classpath then
    return nil, err
  end
  local argv = { "java", "-cp", classpath, "KebabJdbc", mode, url }
  for _, a in ipairs(extra or {}) do
    argv[#argv + 1] = a
  end
  return argv
end

---Same as M.command, but shaped for luaeval() from VimScript, which only ever
---sees the first return value. autoload/db/adapter/jdbc.vim uses this.
---@param url string
---@param mode string
---@return table { ok: boolean, argv?: string[], err?: string }
function M.vim_command(url, mode)
  local argv, err = M.command(url, mode or "query")
  if not argv then
    return { ok = false, err = err or "unknown error" }
  end
  -- dadbod spawns this argv itself, with Neovim's own environment, so the
  -- credentials every other path passes through `env = credentials_env(url)`
  -- never reached it: :DB and dadbod-completion failed to authenticate while
  -- :IdeDbPing and :IdeDbTables worked.
  --
  -- They go into Neovim's environment, not into argv: argv is visible in the
  -- process list, and a file on disk is the thing this layer refuses to do. It
  -- is not a new exposure -- the value is already in this process's
  -- environment, which is where `password_env` is read from in the first
  -- place; this only gives it the second name the JVM looks for.
  for key, value in pairs(M.credentials_env(url) or {}) do
    vim.env[key] = value
  end
  return { ok = true, argv = argv }
end

---Table names for VimScript, as a plain list (empty when something failed, with
---the reason notified -- dadbod's tables() has nowhere to put an error).
function M.vim_tables(url)
  local lines, err = M.run(url, "tables")
  if not lines then
    vim.notify("kebab.jdbc: " .. tostring(err), vim.log.levels.WARN)
    return {}
  end
  return lines
end

---Split a block of output into lines, dropping the trailing blanks that a
---final newline produces.
local function to_lines(text)
  local lines = {}
  for line in (text or ""):gmatch("([^\n]*)\n?") do
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

---Run a mode in a fresh process. Correct but slow: nearly all of the ~180ms is
---one-time per-process driver initialisation. M.run prefers the warm process
---below and falls back to this.
---@param url string
---@param mode string
---@param opts? { args?: string[], stdin?: string, timeout?: number }
---@return string[]|nil lines, string|nil err
function M.run_oneshot(url, mode, opts)
  opts = opts or {}
  local argv, err = M.command(url, mode, opts.args)
  if not argv then
    return nil, err
  end
  local res = vim.system(argv, {
    text = true,
    stdin = opts.stdin or "",
    env = M.credentials_env(url),
  }):wait(opts.timeout or 120000)
  if res.code ~= 0 then
    return nil, vim.trim((res.stderr or "") .. (res.stdout or ""))
  end
  return to_lines(res.stdout)
end

-- ------------------------------------------------------------ warm process
--
-- Measured on this machine: the first connection-and-query in a JVM costs
-- 140ms, the second 0.5ms, and twenty queries on one open connection 1.0ms in
-- total. Almost none of that is the JVM itself (18ms) -- it is driver class
-- loading, and for SQLite extracting a bundled native library, both of which
-- happen once per *process*.
--
-- So one process per connection is kept alive and reused. A cold Rust binary
-- would start in 1.2ms and still have to pay the connect each time; a warm JVM
-- answers in 0.3ms.
--
-- The protocol is length-prefixed, not sentinel-delimited, because SQL contains
-- newlines and any sentinel could appear inside a query:
--
--   request   <mode>\t<arg>\t<len>\n<payload>
--   response  <OK|ERR>\t<len>\n<payload>

---url -> { handle, pid, stdin, stdout, stderr, buffer, queue, stderr_text }
local daemons = {}

function M.daemon_enabled()
  return vim.g.kebab_jdbc_daemon ~= false
end

---How many warm processes are running. For tests and :IdeDbStatus.
function M.daemon_count()
  return vim.tbl_count(daemons)
end

---The pid of the warm process for `url`, or nil.
---
---Exposed so a test can tell "reused" from "restarted": the count alone cannot,
---because a restart shuts one down and starts one.
---@param url string
function M.daemon_pid(url)
  local d = daemons[url]
  return d and d.pid or nil
end

---Hand a complete response to the oldest waiting caller.
local function deliver(d, ok, body)
  local waiter = table.remove(d.queue, 1)
  if waiter then
    waiter(ok, body)
  end
end

---Pull as many complete frames out of the buffer as are there.
local function drain(d)
  while true do
    local header_end = d.buffer:find("\n", 1, true)
    if not header_end then
      return
    end
    local header = d.buffer:sub(1, header_end - 1)
    local status, len = header:match("^(%u+)\t(%d+)$")
    if not status then
      -- The stream is out of step; there is no way back from that, so fail
      -- everyone waiting rather than hang them.
      local err = "malformed response from the JDBC process: " .. header
      d.buffer = ""
      while #d.queue > 0 do
        deliver(d, false, err)
      end
      return
    end
    len = tonumber(len)
    if #d.buffer < header_end + len then
      return -- the body has not all arrived
    end
    local body = d.buffer:sub(header_end + 1, header_end + len)
    d.buffer = d.buffer:sub(header_end + len + 1)
    deliver(d, status == "OK", body)
  end
end

---Stop the warm process for a URL.
function M.shutdown(url)
  local d = daemons[url]
  if not d then
    return false
  end
  daemons[url] = nil
  -- Anyone still waiting gets an answer rather than a hang.
  while #d.queue > 0 do
    deliver(d, false, "the JDBC process was shut down")
  end
  pcall(function()
    if d.stdin and not d.stdin:is_closing() then
      d.stdin:write("close\t\t0\n")
      d.stdin:close()
    end
  end)
  for _, pipe in ipairs({ d.stdout, d.stderr }) do
    pcall(function()
      if pipe and not pipe:is_closing() then
        pipe:read_stop()
        pipe:close()
      end
    end)
  end
  -- Signal, but do *not* close the process handle here: closing it in the same
  -- tick drops the pid from libuv's queue before SIGCHLD arrives, so the child
  -- is never waitpid'd and stays <defunct> for the life of the session. The
  -- exit callback closes it, once the child has actually been reaped.
  pcall(function()
    if d.handle and not d.handle:is_closing() then
      d.handle:kill("sigterm")
    end
  end)
  return true
end

function M.shutdown_all()
  -- The keys, not a copy of the table: a daemon holds libuv handles, which are
  -- userdata and cannot be deepcopied.
  for _, url in ipairs(vim.tbl_keys(daemons)) do
    M.shutdown(url)
  end
end

---A fingerprint of the credentials a warm process was started with.
---
---Warm processes are keyed by URL, but credentials are baked into the process
---environment once, at spawn. Two saved connections can share a URL and differ
---only in user -- the URL templates carry host, port and database, nothing
---else -- so a "readonly" connection reused a daemon started as "admin" and
---executed as admin, silently. The one-shot path passes the environment per
---run and never had this bug, so the behaviour depended on whether the daemon
---happened to be warm.
---
---Hashed, so no secret is held as a table key or printed in a message.
---@param url string
local function credentials_fingerprint(url)
  local creds = M.credentials_env(url) or {}
  local material = ("%s\0%s"):format(creds.KEBAB_DB_USER or "", creds.KEBAB_DB_PASSWORD or "")
  local ok, digest = pcall(vim.fn.sha256, material)
  return ok and digest or material
end

---Start a warm process for `url`, or return nil plus a reason.
local function start_daemon(url)
  local argv, err = M.command(url, "serve")
  if not argv then
    return nil, err
  end

  local stdin = vim.uv.new_pipe(false)
  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)

  -- uv.spawn replaces the environment outright, so the real one has to be
  -- rebuilt or the JVM loses PATH, HOME and JAVA_HOME.
  local env = {}
  for key, value in pairs(vim.fn.environ()) do
    env[#env + 1] = key .. "=" .. value
  end
  for key, value in pairs(M.credentials_env(url) or {}) do
    env[#env + 1] = key .. "=" .. value
  end

  local d = { buffer = "", queue = {}, stderr_text = "" }
  local handle, pid = vim.uv.spawn(argv[1], {
    args = vim.list_slice(argv, 2),
    stdio = { stdin, stdout, stderr },
    env = env,
  }, function(code)
    -- The process died; nobody should be left waiting on it, and nothing it
    -- owned should be left open. A serve-mode JVM exits by itself whenever the
    -- connection fails, so this runs on every failed ping -- leaking its three
    -- pipes and the process handle each time walks a long session toward
    -- EMFILE, and GC cannot reclaim a libuv handle.
    vim.schedule(function()
      if daemons[url] == d then
        daemons[url] = nil
      end
      while #d.queue > 0 do
        deliver(d, false, ("the JDBC process exited (%s)%s"):format(
          tostring(code), d.stderr_text ~= "" and ("\n" .. d.stderr_text) or ""))
      end
      for _, h in ipairs({ d.stdout, d.stderr, d.stdin, d.handle }) do
        pcall(function()
          if h and not h:is_closing() then
            if h == d.stdout or h == d.stderr then
              pcall(function() h:read_stop() end)
            end
            h:close()
          end
        end)
      end
    end)
  end)

  if not handle then
    for _, pipe in ipairs({ stdin, stdout, stderr }) do
      pcall(function() pipe:close() end)
    end
    return nil, "could not start the JDBC process: " .. tostring(pid)
  end

  d.handle, d.pid, d.stdin, d.stdout, d.stderr = handle, pid, stdin, stdout, stderr
  d.creds = credentials_fingerprint(url)

  stdout:read_start(function(rerr, chunk)
    if rerr or not chunk then
      return
    end
    d.buffer = d.buffer .. chunk
    drain(d)
  end)
  -- stderr is kept for the error message when something goes wrong; a JVM
  -- warning on its own should not fail a query.
  stderr:read_start(function(rerr, chunk)
    if not rerr and chunk then
      d.stderr_text = (d.stderr_text .. chunk):sub(-4000)
    end
  end)

  daemons[url] = d
  return d
end

---Send one request to the warm process and wait for its answer.
---
---The third return value is what makes a one-shot retry safe: it is true only
---while nothing has been handed to the process yet. Once the frame is written,
---the server may have executed it -- so a timeout must never be retried, or a
---DELETE that committed server-side runs a second time.
---@return boolean|nil ok, string body_or_err, boolean retryable
local function request(url, mode, arg, payload, timeout)
  local d = daemons[url]
  -- Credentials are per connection, not per URL: a warm process started under
  -- one user must not answer for another.
  if d and d.creds ~= credentials_fingerprint(url) then
    M.shutdown(url)
    d = nil
  end
  if not d then
    local err
    d, err = start_daemon(url)
    if not d then
      -- nothing was sent: the warm process could not be started at all
      return nil, err, true
    end
  end

  -- One request at a time per connection. vim.wait pumps vim.schedule
  -- callbacks, so a second jdbc.run on the same URL used to start *inside* the
  -- first one's wait -- sharing the single per-URL process, and whichever
  -- timed out first called M.shutdown(url), killing the JVM mid-statement and
  -- failing the other in-flight request. Nothing has been sent at this point,
  -- so handing the caller back to the one-shot path is safe.
  if d.busy then
    return nil, "another request is still running on this connection", true
  end
  d.busy = true

  payload = payload or ""
  local done, result_ok, result_body = false, nil, nil
  d.queue[#d.queue + 1] = function(ok, body)
    done, result_ok, result_body = true, ok, body
    d.busy = false
  end

  local header = ("%s\t%s\t%d\n"):format(mode, arg or "", #payload)
  local wrote = pcall(function()
    d.stdin:write(header .. payload)
  end)
  if not wrote then
    -- The pipe was already broken, so the frame never went anywhere.
    d.busy = false
    M.shutdown(url)
    return nil, "could not write to the JDBC process", true
  end

  local ok, reason = vim.wait(timeout or 120000, function() return done end, 10)
  d.busy = false
  if not ok then
    -- A hung query leaves the stream mid-frame, so the process cannot be
    -- trusted for the next request.
    M.shutdown(url)
    local why = reason == -2 and "the JDBC request was interrupted"
      or ("the JDBC process did not answer within %s"):format(M.describe_timeout(timeout or 120000))
    -- Not retryable: the statement may already have run and committed.
    return nil, why .. " (it may already have run; check before repeating it)", false
  end
  return result_ok, result_body, false
end

---Run a mode, reusing a warm process where possible.
---
---The signature is unchanged on purpose: every caller -- db.lua,
---dbcomplete.lua, the dadbod adapter -- keeps working, and the speed-up is an
---implementation detail.
---@param url string
---@param mode string
---@param opts? { args?: string[], stdin?: string, timeout?: number }
---@return string[]|nil lines, string|nil err
function M.run(url, mode, opts)
  opts = opts or {}
  if not M.daemon_enabled() then
    return M.run_oneshot(url, mode, opts)
  end

  local ok, body, retryable = request(url, mode, (opts.args or {})[1], opts.stdin, opts.timeout)
  if ok == nil then
    if not retryable then
      -- The request reached the process. Re-running it could apply a mutating
      -- statement twice, and would spend the timeout budget a second time, so
      -- report what happened instead.
      return nil, vim.trim(body or "the JDBC process failed")
    end
    -- The warm process could not be used at all, and nothing was sent. Fall
    -- back rather than fail: a one-shot run is slow but correct.
    return M.run_oneshot(url, mode, opts)
  end
  if not ok then
    return nil, vim.trim(body or "unknown error")
  end
  return to_lines(body)
end

---Credentials are passed through the environment, never argv, so they do not
---appear in the process list. `kebab.db` fills this in from its own store.
function M.credentials_env(url)
  local env = {}
  local creds = vim.g.kebab_db_credentials
  if type(creds) == "table" and type(creds[url]) == "table" then
    env.KEBAB_DB_USER = creds[url].user
    env.KEBAB_DB_PASSWORD = creds[url].password
  end
  return next(env) and env or nil
end

---Build a JDBC URL from a driver and its parts.
---@param driver kebab.JdbcDriver
---@param parts table { host?, port?, database?, file? }
function M.build_url(driver, parts)
  parts = parts or {}
  -- Substitute through a function, not a replacement string: gsub treats `%`
  -- in a replacement as an escape, so a path like /tmp/100%/shop.sqlite would
  -- silently lose a character or pick up a capture reference, and the saved
  -- connection would point somewhere else entirely.
  local function put(url, placeholder, value)
    return (url:gsub(placeholder, function()
      return value
    end))
  end
  local url = driver.url
  url = put(url, "{host}", parts.host or "localhost")
  url = put(url, "{port}", tostring(parts.port or driver.default_port or ""))
  url = put(url, "{database}", parts.database or "")
  url = put(url, "{file}", parts.file and require("kebab.path").expand(parts.file) or "")
  return url
end

return M
