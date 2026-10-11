-- bin/kebab, the shell entry point.
--
-- The reporting subcommands are run for real. The interactive ones cannot be,
-- so they are run with KEBAB_DRY_RUN=1 and the Lua they would have executed is
-- checked -- including that it compiles, which is what proves a project name
-- containing a quote cannot break out of the string and run as code.
local H = ...

local root = _G.KEBAB_TEST.root
local kebab = root .. "/bin/kebab"

---Run bin/kebab and return { code, stdout, stderr }.
local function run(args, env)
  local cmd = { kebab }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, {
    text = true,
    env = vim.tbl_extend("force", { KEBAB_PROJECT_ROOTS = "" }, env or {}),
  }):wait(120000)
  return { code = res.code, out = res.stdout or "", err = res.stderr or "" }
end

---The Lua chunk a `lua ...` command line would execute.
local function lua_chunk(line)
  local chunk = line:match("^lua%s+(.*)$")
  H.ok(chunk, "expected a `lua ...` command line, got: " .. tostring(line))
  return chunk
end

---Assert a generated chunk is syntactically valid Lua.
local function compiles(chunk)
  local fn, err = load(chunk, "generated")
  H.ok(fn, "generated Lua should compile: " .. tostring(err) .. "\n  " .. chunk)
end

H.describe("bin/kebab", function()
  H.it("is executable", function()
    H.ok(H.exists(kebab), "bin/kebab should exist")
    H.eq(1, vim.fn.executable(kebab), "bin/kebab should be executable")
  end)

  H.it("reports its version", function()
    local r = run({ "version" })
    H.eq(0, r.code)
    H.matches("^kebab %d+%.%d+%.%d+", vim.trim(r.out))
  end)

  H.it("prints usage for help, -h and --help", function()
    for _, flag in ipairs({ "help", "-h", "--help" }) do
      local r = run({ flag })
      H.eq(0, r.code, flag .. " should exit 0")
      H.matches("kebab open <name>", r.out, flag .. " should document `open`")
      H.matches("kebab new <name>", r.out, flag .. " should document `new`")
      H.falsy(r.out:match("set %-euo"), flag .. " must not leak the script body")
    end
  end)

  H.it("rejects an unknown option", function()
    local r = run({ "--nope" })
    H.ok(r.code ~= 0, "should fail")
    H.matches("unknown option", r.err)
  end)

  H.it("accepts any --name value, since the prompts are the type's to declare", function()
    -- Deliberately not rejected here: the shell script knows nothing about any
    -- language. An answer no prompt uses is caught in Lua instead, where the
    -- prompts are known -- see project_spec.
    local r = run({ "new", "x", "--bogus", "value" }, { KEBAB_DRY_RUN = "1" })
    H.eq(0, r.code, r.err)
    H.matches('bogus = "value"', r.out)
  end)

  H.it("rejects a flag that is missing its value", function()
    for _, flag in ipairs({ "--type", "--dir", "--group", "--deps", "--template", "--module", "--anything" }) do
      local r = run({ "new", "x", flag })
      H.ok(r.code ~= 0, flag .. " with no value should fail")
      H.matches("needs a value", r.err)
    end
  end)

  H.it("rejects an option name that is not one", function()
    local r = run({ "new", "x", "--bad@name", "v" })
    H.ok(r.code ~= 0)
    H.matches("not a valid option name", r.err)
  end)

  H.it("rejects a stray positional argument", function()
    local r = run({ "new", "x", "extra" })
    H.ok(r.code ~= 0)
    H.matches("unknown argument", r.err)
  end)
end)

H.describe("bin/kebab reports", function()
  H.it("lists the projects under KEBAB_PROJECT_ROOTS", function()
    local scratch = H.tmpdir("shell-list")
    vim.fn.mkdir(scratch .. "/alpha/.git", "p")
    H.write(scratch .. "/beta/pom.xml", "<project/>")

    local r = run({ "list" }, { KEBAB_PROJECT_ROOTS = scratch })
    H.eq(0, r.code, "list should exit 0: " .. r.err)
    H.matches("alpha", r.out)
    H.matches("beta%s+maven", r.out)
  end)

  H.it("says so when a root holds no projects", function()
    local r = run({ "list" }, { KEBAB_PROJECT_ROOTS = H.tmpdir("shell-empty") })
    H.eq(0, r.code)
    H.matches("No projects found", r.out)
  end)

  H.it("lists the project types", function()
    local r = run({ "types" })
    H.eq(0, r.code, r.err)
    for _, key in ipairs({ "spring", "flutter", "python", "node", "maven", "vite", "empty", "go", "rust" }) do
      H.matches("\n?" .. key, r.out, key .. " should be listed")
    end
  end)

  H.it("documents each type's prompts on request", function()
    -- Generated from the type declarations, so the help cannot drift from what
    -- the scaffolds actually ask.
    local r = run({ "types", "--prompts" })
    H.eq(0, r.code, r.err)
    H.matches("%-%-group", r.out, "the Spring scaffold asks for a group id")
    H.matches("%-%-module", r.out, "the Go scaffold asks for a module path")
    H.matches("%-%-kind", r.out, "the Rust scaffold asks bin or lib")
    H.matches("one of: bin, lib", r.out, "a select prompt should list its choices")
    H.matches("default: com%.example", r.out, "an input prompt should show its default")
  end)

  H.it("passes its own doctor", function()
    local r = run({ "doctor" })
    H.eq(0, r.code, "doctor should exit 0:\n" .. r.out .. r.err)
    H.matches("ok%s+Neovim", r.out)
    H.falsy(r.out:match("FAIL"), "nothing should be failing:\n" .. r.out)
  end)
end)

H.describe("bin/kebab new --no-open", function()
  H.it("creates a project without opening an editor", function()
    local dest = H.tmpdir("shell-new") .. "/shell-made"
    local r = run({ "new", "shell-made", "--type", "empty", "--dir", dest, "--no-open" })
    H.eq(0, r.code, "should exit 0:\n" .. r.out .. r.err)
    H.matches("created ", r.out)
    H.ok(H.exists(dest .. "/README.md"), "README.md should exist")
    H.ok(H.exists(dest .. "/.git"), "should be a git repository")
    H.matches("# shell%-made", H.read(dest .. "/README.md"))
  end)

  H.it("exits non-zero and explains when the directory is occupied", function()
    local dest = H.tmpdir("shell-occupied")
    H.write(dest .. "/mine.txt", "keep")
    local r = run({ "new", "x", "--type", "empty", "--dir", dest, "--no-open" })
    H.ok(r.code ~= 0, "should fail")
    H.matches("exists and is not empty", r.out .. r.err)
    H.eq("keep", H.read(dest .. "/mine.txt"), "the existing file must survive")
  end)

  H.it("exits non-zero on an unknown type", function()
    local r = run({ "new", "x", "--type", "nonsense", "--no-open" })
    H.ok(r.code ~= 0, "should fail")
    H.matches("Unknown project type", r.out .. r.err)
  end)
end)

H.describe("bin/kebab argument handling", function()
  local function dry(args)
    local r = run(args, { KEBAB_DRY_RUN = "1" })
    H.eq(0, r.code, "dry run should succeed: " .. r.err)
    return vim.trim(r.out)
  end

  H.it("with no arguments opens the current directory", function()
    local line = dry({})
    compiles(lua_chunk(line))
    H.matches("open_dir", line)
    H.matches("getcwd", line)
  end)

  H.it("treats a bare argument as a project name or path", function()
    local line = dry({ "alpha-api" })
    compiles(lua_chunk(line))
    H.matches('open%("alpha%-api"%)', line)
    H.matches("kebab%.cli", line, "a bare argument should go through cli.open")
  end)

  H.it("passes `open` its argument", function()
    local line = dry({ "open", "sample-app" })
    compiles(lua_chunk(line))
    H.matches("sample%-app", line)
  end)

  H.it("passes `open` an empty string when given nothing", function()
    local line = dry({ "open" })
    compiles(lua_chunk(line))
    H.matches('%(""%)', line, "an empty query means the picker")
  end)

  H.it("escapes a quote in a project name instead of breaking the chunk", function()
    -- If this were interpolated raw, the chunk would not compile -- and worse,
    -- a crafted name could close the string and append its own Lua.
    local line = dry({ "open", 'weird"name' })
    local chunk = lua_chunk(line)
    compiles(chunk)
    H.matches('\\"', line, "the quote should be escaped")
  end)

  H.it("escapes a backslash in a project name", function()
    local line = dry({ "open", "back\\slash" })
    compiles(lua_chunk(line))
  end)

  H.it("passes any prompt through as --name value", function()
    -- The answers are not hardcoded in the shell script: a language that adds
    -- a question becomes settable without touching bin/kebab. These are the
    -- prompts Go, Rust and the Node scaffold declare.
    for _, case in ipairs({
      { { "new", "t", "--type", "go", "--module", "github.com/you/t" }, 'module = "github.com/you/t"' },
      { { "new", "t", "--type", "rust", "--kind", "lib" }, 'kind = "lib"' },
      { { "new", "t", "--type", "node", "--language", "javascript" }, 'language = "javascript"' },
    }) do
      local line = dry(case[1])
      compiles(lua_chunk(line))
      H.matches(vim.pesc(case[2]), line)
    end
  end)

  H.it("turns a dashed option into an underscored answer name", function()
    -- Lua table keys cannot contain a dash, so --my-answer sets my_answer.
    local line = dry({ "new", "t", "--type", "empty", "--my-answer", "v" })
    compiles(lua_chunk(line))
    H.matches('my_answer = "v"', line)
  end)

  H.it("builds a full non-interactive `new` spec", function()
    local line = dry({ "new", "myproj", "--type", "spring", "--group", "io.gulay", "--deps", "web,jpa" })
    local chunk = lua_chunk(line)
    compiles(chunk)
    H.matches("%.new%(", line, "without --no-open it should open the editor")
    H.matches('name = "myproj"', line)
    H.matches('type = "spring"', line)
    H.matches('group = "io%.gulay"', line)
    H.matches('deps = "web,jpa"', line)
  end)

  H.it("omits the answers table when no answers were given", function()
    local line = dry({ "new", "plain", "--type", "empty" })
    compiles(lua_chunk(line))
    H.falsy(line:match("answers"), "an empty answers table should not be emitted: " .. line)
  end)

  H.it("passes --dir through as the destination", function()
    local line = dry({ "new", "p", "--type", "empty", "--dir", "/tmp/somewhere" })
    compiles(lua_chunk(line))
    H.matches('dest = "/tmp/somewhere"', line)
  end)

  H.it("routes --no-open to the headless creator", function()
    -- --no-open must not reach run_editor, or it would try to take over a
    -- terminal that a script does not have. Checked as a dry run: this command
    -- really creates a directory, so running it for the routing alone would
    -- leave a project behind and fail the second time round.
    local line = dry({ "new", "p", "--type", "empty", "--dir", H.tmpdir("routing") .. "/p", "--no-open" })
    compiles(lua_chunk(line))
    H.matches("create_and_quit", line, "should use the headless creator")
    H.falsy(line:match("%.new%("), "should not use the interactive path: " .. line)
  end)

  H.it("passes --template through for vite", function()
    local line = dry({ "new", "p", "--type", "vite", "--template", "svelte-ts" })
    compiles(lua_chunk(line))
    H.matches('template = "svelte%-ts"', line)
  end)

  H.it("builds a spec the cli module actually accepts", function()
    -- Compiling is not enough: the table has to have the shape cli.new wants.
    local line = dry({ "new", "shape-check", "--type", "empty", "--dir", "/tmp/x" })
    local chunk = lua_chunk(line)
    local spec_src = chunk:match("new%((.*)%)$")
    H.ok(spec_src, "should be a call to cli.new: " .. chunk)
    local fn = load("return " .. spec_src)
    H.ok(fn, "the spec table should be loadable")
    local spec = fn()
    H.eq("shape-check", spec.name)
    H.eq("empty", spec.type)
    H.eq("/tmp/x", spec.dest)
  end)
end)

H.describe("bin/kebab semantic queries", function()
  H.it("documents them in the help", function()
    local r = run({ "help" })
    H.eq(0, r.code)
    for _, cmd in ipairs({ "diagnostics", "definition", "references", "symbols", "hover" }) do
      H.matches("kebab " .. cmd, r.out, cmd .. " should be documented")
    end
    H.matches("kebab serve", r.out)
    H.matches("%-%-server", r.out)
    H.matches("%-%-json", r.out)
  end)

  H.it("says the queries are read-only", function()
    -- The guarantee an agent relies on, so it belongs in the help.
    H.matches("[Rr]ead%-only", run({ "help" }).out)
  end)

  H.it("rejects a query with no file", function()
    for _, cmd in ipairs({ "diagnostics", "definition", "symbols" }) do
      local r = run({ cmd })
      H.ok(r.code ~= 0, cmd .. " with no argument should fail")
      H.matches("needs a file", r.err)
    end
  end)

  H.it("rejects an unknown flag on a query", function()
    local r = run({ "diagnostics", "a.go", "--nonsense" })
    H.ok(r.code ~= 0)
    H.matches("unknown option", r.err)
  end)

  H.it("rejects --timeout with no value", function()
    local r = run({ "diagnostics", "a.go", "--timeout" })
    H.ok(r.code ~= 0)
    H.matches("needs a value", r.err)
  end)

  H.it("refuses a socket path too long to bind", function()
    -- A unix socket is limited to about 108 bytes, and a path under a long
    -- scratch directory fails silently -- which cost an afternoon to notice.
    local long = "/tmp/" .. string.rep("x", 120) .. "/kebab.sock"
    local r = run({ "serve", "--socket", long })
    H.ok(r.code ~= 0)
    H.matches("too long", r.err)
  end)

  H.it("rejects an unknown option to serve", function()
    local r = run({ "serve", "--nonsense" })
    H.ok(r.code ~= 0)
    H.matches("unknown option for 'serve'", r.err)
  end)

  H.it("refuses --server with no socket", function()
    local r = run({ "--server" })
    H.ok(r.code ~= 0)
    H.matches("needs a socket path", r.err)
  end)

  H.it("reports a socket nothing is listening on", function()
    local r = run({ "--server", "/tmp/kebab-definitely-not-here.sock", "diagnostics", "a.go" })
    H.ok(r.code ~= 0)
    H.matches("no instance listening", r.err)
  end)

  H.it("answers a real query, with a greppable position", function()
    if vim.fn.executable("go") == 0 then
      H.skip("go is needed for a project a language server will attach to")
    end
    local dir = H.tmpdir("shell-agent")
    local init = vim.system({ "go", "mod", "init", "example.com/s" }, { cwd = dir, text = true })
      :wait(60000)
    H.eq(0, init.code, tostring(init.stderr))
    H.write(dir .. "/main.go", table.concat({
      "package main", "", "func main() {", "\tvar unused int", "}",
    }, "\n"))

    local cmd = { kebab, "diagnostics", "main.go" }
    local res = vim.system(cmd, { cwd = dir, text = true }):wait(120000)
    H.eq(0, res.code, "the query itself should succeed: " .. (res.stderr or ""))
    H.matches("main%.go:4:%d+: error:", res.stdout,
      "output should be file:line:col so an editor can jump to it")

    -- and the gated exit code
    local gated = vim.system({ kebab, "diagnostics", "main.go", "--exit-code" },
      { cwd = dir, text = true }):wait(120000)
    H.eq(1, gated.code, "--exit-code should fail on an error")

    -- and JSON
    local json = vim.system({ kebab, "diagnostics", "main.go", "--json" },
      { cwd = dir, text = true }):wait(120000)
    H.eq(0, json.code)
    local ok, decoded = pcall(vim.json.decode, vim.trim(json.stdout))
    H.ok(ok, "should be valid JSON: " .. tostring(json.stdout):sub(1, 200))
    H.eq(true, decoded.ok)
    H.ok(decoded.count >= 1)
  end)
end)
