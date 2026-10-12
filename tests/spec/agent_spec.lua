-- The semantic queries an agent uses, and their CLI contract.
--
-- Read-only by design: nothing here writes to the working tree, so an agent
-- driving it unattended cannot damage a repository. The tests assert that too.
local H = ...
local agent = require("kebab.agent")
local lsp = require("kebab.lsp")

---A tiny Go project. Go because gopls attaches in under 100ms, where jdtls
---needs up to 150s to import a Maven project -- that difference is the reason
---`kebab serve` exists, and it would make this spec unusable.
local fixture_dir

local function requires_go()
  local usable, why = H.usable("go")
  if not usable then
    H.skip(why .. " -- go is needed for a project gopls will attach to")
  end
  if not vim.uv.fs_stat(vim.fn.stdpath("data") .. "/mason/bin/gopls")
    and vim.fn.executable("gopls") == 0 then
    H.skip("gopls is not installed")
  end
end

local function fixture()
  if fixture_dir then
    return fixture_dir
  end
  local dir = H.tmpdir("agent-go")
  local res = vim.system({ "go", "mod", "init", "example.com/agent" }, { cwd = dir, text = true })
    :wait(60000)
  H.eq(0, res.code, "go mod init failed: " .. tostring(res.stderr))
  H.write(dir .. "/main.go", table.concat({
    "package main",
    "",
    'import "fmt"',
    "",
    "func greet(name string) string {",
    '\treturn "hi " + name',
    "}",
    "",
    "func main() {",
    '\tfmt.Println(greet("world"))',
    "\tvar unused int",
    "}",
  }, "\n"))
  -- A second file with nothing wrong with it, so "exit 0" can be shown to mean
  -- "the server reported a clean file" rather than "the server said nothing".
  H.write(dir .. "/clean/clean.go", table.concat({
    "package clean",
    "",
    "// Twice doubles n.",
    "func Twice(n int) int {",
    "\treturn n * 2",
    "}",
  }, "\n"))
  fixture_dir = dir
  return dir
end

---Run a query with the fixture as the working directory.
local function in_fixture(fn)
  local dir = fixture()
  local saved = vim.fn.getcwd()
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  local ok, err = pcall(fn, dir)
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved))
  if not ok then
    error(err, 0)
  end
end

H.describe("parsing a position", function()
  H.it("reads path:line:col", function()
    H.eq({ "src/Main.java", 42, 18 }, { lsp.parse_position("src/Main.java:42:18") })
  end)

  H.it("defaults the column", function()
    H.eq({ "a.go", 7, 1 }, { lsp.parse_position("a.go:7") })
  end)

  H.it("keeps a path that contains a colon", function()
    local path, line, col = lsp.parse_position("weird:dir/a.go:3:4")
    H.eq("weird:dir/a.go", path)
    H.eq(3, line)
    H.eq(4, col)
  end)

  H.it("explains anything else", function()
    for _, bad in ipairs({ "", "nonsense", "a.go:" }) do
      local path, _, _, err = lsp.parse_position(bad)
      H.falsy(path, ("%q should not parse"):format(bad))
      H.ok(err and err ~= "")
    end
  end)
end)

H.describe("the command set", function()
  H.it("is read-only", function()
    -- The guarantee: an agent cannot damage a repository through these.
    H.eq({ "diagnostics", "definition", "references", "symbols", "hover" }, agent.COMMANDS)
    for _, name in ipairs({ "rename", "format", "code-action", "edit", "write" }) do
      H.falsy(agent.is_command(name), name .. " writes, so it must not be here")
    end
  end)

  H.it("rejects an unknown command, listing the real ones", function()
    local _, err = agent.query("nonsense", {})
    H.matches("unknown command", err)
    H.matches("diagnostics", err)
  end)

  H.it("says what each command needs", function()
    H.matches("needs a file", (select(2, agent.query("diagnostics", {}))))
    H.matches("path:line:col", (select(2, agent.query("definition", {}))))
    H.matches("path:line:col", (select(2, agent.query("references", {}))))
    H.matches("path:line:col", (select(2, agent.query("hover", {}))))
  end)

  H.it("reports a file that is not there, rather than an empty result", function()
    -- An agent must be able to tell "no errors" from "could not check".
    local _, err = agent.query("diagnostics", { "/definitely/missing.go" })
    H.matches("no such file", err)
  end)
end)

H.describe("diagnostics", function()
  H.it("finds a real error, with its position and severity", function()
    requires_go()
    in_fixture(function()
      local result, err = agent.query("diagnostics", { "main.go" })
      H.ok(result, tostring(err))
      H.ok(result.count >= 1, "gopls should report the unused variable")
      H.ok(vim.tbl_contains(result.clients, "gopls"))
      local found
      for _, d in ipairs(result.diagnostics) do
        if d.message:match("unused") then
          found = d
        end
      end
      H.ok(found, "expected the unused-variable diagnostic: " .. vim.inspect(result.diagnostics))
      H.eq(11, found.line, "line numbers are 1-based, as a command line expects")
      H.eq("error", found.severity, "a name, not the LSP's 1-4")
      H.ok(found.col >= 1, "columns are 1-based too")
    end)
  end)

  H.it("sorts by position, so the output is stable", function()
    requires_go()
    in_fixture(function()
      local result = agent.query("diagnostics", { "main.go" })
      local previous = 0
      for _, d in ipairs(result.diagnostics) do
        H.ok(d.line >= previous, "diagnostics should be in file order")
        previous = d.line
      end
    end)
  end)

  H.it("says whether the server had settled", function()
    requires_go()
    in_fixture(function()
      local result = agent.query("diagnostics", { "main.go" })
      H.eq("boolean", type(result.settled),
        "a clean file and a slow server look alike; the caller deserves to know which")
    end)
  end)
end)

H.describe("navigation", function()
  H.it("finds where a symbol is defined", function()
    requires_go()
    in_fixture(function()
      -- the greet( call on line 10
      local result, err = agent.query("definition", { "main.go:10:14" })
      H.ok(result, tostring(err))
      H.eq(1, result.count)
      H.eq(5, result.locations[1].line, "greet is declared on line 5")
      H.matches("main%.go$", result.locations[1].file)
    end)
  end)

  H.it("finds everywhere a symbol is used", function()
    requires_go()
    in_fixture(function()
      local result, err = agent.query("references", { "main.go:5:6" })
      H.ok(result, tostring(err))
      H.ok(result.count >= 2, "the declaration and the call: " .. vim.inspect(result.locations))
      local lines = vim.tbl_map(function(l) return l.line end, result.locations)
      H.ok(vim.tbl_contains(lines, 5), "the declaration")
      H.ok(vim.tbl_contains(lines, 10), "the call")
    end)
  end)

  H.it("lists a file's symbols with their kinds", function()
    requires_go()
    in_fixture(function()
      local result, err = agent.query("symbols", { "main.go" })
      H.ok(result, tostring(err))
      local by_name = {}
      for _, s in ipairs(result.symbols) do
        by_name[s.name] = s
      end
      H.ok(by_name.greet, "greet should be listed: " .. vim.inspect(result.symbols))
      H.eq("Function", by_name.greet.kind, "a name, not the LSP's number")
      H.eq(5, by_name.greet.line)
      H.ok(by_name.main, "and main")
    end)
  end)

  H.it("reports the type of a symbol", function()
    requires_go()
    in_fixture(function()
      local result, err = agent.query("hover", { "main.go:5:6" })
      H.ok(result, tostring(err))
      H.matches("func greet", result.text, "hover should carry the signature")
    end)
  end)
end)

H.describe("rendering", function()
  H.it("prints a diagnostic as file:line:col, so it is greppable", function()
    local lines = agent.render_text("diagnostics", {
      file = "/p/a.go",
      clients = { "gopls" },
      settled = true,
      count = 1,
      diagnostics = { {
        file = "/p/a.go", line = 11, col = 6, severity = "error",
        source = "compiler", message = "declared and not used",
      } },
    })
    H.eq(1, #lines)
    H.matches(":11:6: error: declared and not used %[compiler%]", lines[1])
  end)

  H.it("says so plainly when a file is clean", function()
    local lines = agent.render_text("diagnostics", {
      file = "/p/a.go", clients = { "gopls" }, settled = true, count = 0, diagnostics = {},
    })
    H.matches("no diagnostics", lines[1])
  end)

  H.it("warns when it might simply have been too early", function()
    local lines = agent.render_text("diagnostics", {
      file = "/p/a.go", clients = { "gopls" }, settled = false, count = 0, diagnostics = {},
    })
    H.matches("had not published", table.concat(lines, "\n"),
      "silence and cleanliness must not look the same")
  end)

  H.it("prints locations one per line", function()
    local lines = agent.render_text("definition", {
      count = 2,
      locations = { { file = "/p/a.go", line = 5, col = 6 }, { file = "/p/b.go", line = 1, col = 1 } },
    })
    H.eq(2, #lines)
    H.matches(":5:6$", lines[1])
  end)

  H.it("indents nested symbols", function()
    local lines = agent.render_text("symbols", {
      file = "/p/a.go",
      symbols = {
        { name = "Thing", kind = "Struct", depth = 0, line = 1, col = 1 },
        { name = "field", kind = "Field", depth = 1, line = 2, col = 2 },
      },
    })
    H.matches("Thing %(Struct%)", lines[1])
    H.matches("  field %(Field%)", lines[2])
  end)
end)

H.describe("the CLI contract", function()
  H.it("exits 0 when the query worked, whatever it found", function()
    requires_go()
    in_fixture(function()
      local _, code = agent.report("diagnostics", { "main.go" }, {})
      H.eq(0, code, "finding errors is a successful query")
    end)
  end)

  H.it("exits 1 when the query itself failed", function()
    local output, code = agent.report("diagnostics", { "/missing.go" }, {})
    H.eq(1, code)
    H.matches("error:", output)
  end)

  H.it("exits 1 on an error only when --exit-code is given", function()
    requires_go()
    in_fixture(function()
      local _, plain = agent.report("diagnostics", { "main.go" }, {})
      -- A generous settle window on purpose: with a short one this asserted
      -- the *flake* rather than the behaviour -- a cold gopls publishes
      -- nothing in 1.5s, the result came back empty, and the gate exited 0.
      local _, gated = agent.report("diagnostics", { "main.go" }, { exit_code = true, settle = 30000 })
      H.eq(0, plain)
      H.eq(1, gated, "the pre-commit-check shape")
    end)
  end)

  -- "clean" and "the server never answered" must not look the same to a gate.
  -- Driven off a stubbed result rather than a real server: racing a cold gopls
  -- is what made the test above assert the flake instead of the behaviour.
  H.it("exits 2 when it could not determine, rather than 0", function()
    local lsp = require("kebab.lsp")
    local real = lsp.diagnostics
    local function stub(settled, diags)
      lsp.diagnostics = function()
        return {
          file = "/p/main.go",
          clients = { "gopls" },
          settled = settled,
          count = #diags,
          diagnostics = diags,
        }
      end
    end

    local ok, err = pcall(function()
      stub(false, {})
      local output, code = agent.report("diagnostics", { "main.go" }, { exit_code = true })
      H.eq(2, code, "an unsettled, empty result is inconclusive -- not clean")
      H.matches("had not published anything yet", output, "and it has to say so: " .. output)

      stub(true, {})
      local _, clean = agent.report("diagnostics", { "main.go" }, { exit_code = true })
      H.eq(0, clean, "a settled, empty result is a genuine pass")

      stub(false, { { file = "/p/main.go", line = 1, col = 1, severity = "error", message = "boom" } })
      local _, found = agent.report("diagnostics", { "main.go" }, { exit_code = true })
      H.eq(1, found, "an error outranks being unsettled")

      -- settled = true, because a server that published a warning has
      -- published: lsp.diagnostics sets `settled or #out > 0` for exactly this
      stub(true, { { file = "/p/main.go", line = 1, col = 1, severity = "warning", message = "meh" } })
      local _, warned = agent.report("diagnostics", { "main.go" }, { exit_code = true })
      H.eq(0, warned, "a warning is not an error, so it is not a failure")

      -- and without --exit-code none of this changes the code
      stub(false, {})
      local _, ungated = agent.report("diagnostics", { "main.go" }, {})
      H.eq(0, ungated, "the plain report still only says whether the query worked")
    end)
    lsp.diagnostics = real
    H.ok(ok, tostring(err))
  end)

  H.it("still exits 0 for a file that is genuinely clean", function()
    requires_go()
    in_fixture(function()
      local _, code = agent.report("diagnostics", { "clean/clean.go" }, { exit_code = true, settle = 30000 })
      H.eq(0, code, "a clean file the server reported on is a pass")
    end)
  end)

  H.it("emits valid JSON with --json", function()
    requires_go()
    in_fixture(function()
      local output = agent.report("diagnostics", { "main.go" }, { json = true })
      local ok, decoded = pcall(vim.json.decode, output)
      H.ok(ok, "output should be valid JSON: " .. output:sub(1, 200))
      H.eq(true, decoded.ok)
      H.eq("diagnostics", decoded.command)
      H.eq("number", type(decoded.count))
      H.eq("table", type(decoded.diagnostics))
    end)
  end)

  H.it("reports a failure as JSON too, when asked for JSON", function()
    local output, code = agent.report("diagnostics", { "/missing.go" }, { json = true })
    H.eq(1, code)
    local decoded = vim.json.decode(output)
    H.eq(false, decoded.ok)
    H.matches("no such file", decoded.error)
  end)
end)

H.describe("the remote protocol", function()
  H.it("returns the exit code on the first line, then the output", function()
    -- One round trip and no parser on the caller's side; the output may itself
    -- be JSON, which nesting would only have to be unwrapped again.
    local reply = agent.remote(vim.json.encode({
      command = "diagnostics", args = { "/missing.go" }, opts = {},
    }))
    local first = reply:match("^([^\n]*)")
    H.eq("1", first, "the code comes first")
    H.matches("no such file", reply)
  end)

  H.it("rejects a malformed request with code 2", function()
    local reply = agent.remote("not json at all")
    H.matches("^2\n", reply)
    H.matches("malformed", reply)
  end)

  H.it("never throws, whatever it is handed", function()
    for _, payload in ipairs({ "", "null", "[]", '{"command":null}', '{"command":"diagnostics"}' }) do
      local ok, reply = pcall(agent.remote, payload)
      H.ok(ok, ("remote(%q) threw: %s"):format(payload, tostring(reply)))
      H.matches("^%d+\n", reply, "and still answers with a code")
    end
  end)
end)

-- Columns were emitted as the raw LSP `character + 1`, i.e. in the server's
-- offset encoding. gopls, jdtls, basedpyright, vtsls and svelte all negotiate
-- utf-16 here, so on a line with non-ASCII before the symbol the number was
-- neither a byte column nor valid input to kebab's own commands -- and it
-- disagreed with the columns `diagnostics` reports for the same file.
H.describe("columns on a line with non-ASCII", function()
  local lsp = require("kebab.lsp")
  local dir, line

  local function fixture()
    if dir then
      return dir
    end
    local usable, why = H.usable("go")
    if not usable then
      H.skip(why)
    end
    dir = H.tmpdir("enc")
    local res = vim.system({ "go", "mod", "init", "example.com/enc" }, { cwd = dir, text = true }):wait(60000)
    H.eq(0, res.code, tostring(res.stderr))
    line = '\tfmt.Println(helper("wörld ünïcode"), helper("x"))'
    H.write(
      dir .. "/main.go",
      table.concat({
        "package main",
        "",
        'import "fmt"',
        "",
        "func helper(s string) string {",
        "\treturn s",
        "}",
        "",
        "func main() {",
        line,
        "}",
      }, "\n")
    )
    return dir
  end

  H.it("reports a byte column, matching what diagnostics reports", function()
    -- H.in_dir, not cd + pcall + cd: a pcall around a body that can H.skip
    -- swallows the skip and reports it as a failure whose message is
    -- "table: 0x...", which is what CI showed on a runner with no gopls.
    H.in_dir(fixture(), function()
      -- the second `helper(` sits after three two-byte characters, so its byte
      -- column and its utf-16 column differ by three
      local byte_col = line:find("helper", line:find("helper") + 1)
      local utf16_col = vim.str_utfindex(line, "utf-16", byte_col - 1) + 1
      H.ok(byte_col ~= utf16_col, "the fixture has to actually distinguish them")

      local result, rerr = lsp.references("main.go", 5, 6, { attach_timeout = 120000, request_timeout = 30000 })
      if not result then
        H.skip("no language server answered: " .. tostring(rerr))
      end
      local cols = {}
      for _, loc in ipairs(result.locations) do
        if loc.line == 10 then
          cols[#cols + 1] = loc.col
        end
      end
      H.ok(vim.tbl_contains(cols, byte_col), ("expected the byte column %d, got %s"):format(byte_col, vim.inspect(cols)))
      H.falsy(vim.tbl_contains(cols, utf16_col), ("the utf-16 column %d is the bug"):format(utf16_col))
    end)
  end)

  H.it("round-trips its own output", function()
    H.in_dir(fixture(), function()
      local byte_col = line:find("helper", line:find("helper") + 1)
      -- feeding a reported position back in has to land on the same symbol
      local result, rerr = lsp.definition("main.go", 10, byte_col, { attach_timeout = 120000, request_timeout = 30000 })
      if not result then
        H.skip("no language server answered: " .. tostring(rerr))
      end
      H.eq(1, result.count, vim.inspect(result.locations))
      H.eq(5, result.locations[1].line, "it should resolve to the helper definition")
    end)
  end)
end)

H.describe("a language server that refuses a request", function()
  local lsp = require("kebab.lsp")

  -- A client whose RPC channel has closed is still handed back by get_clients,
  -- and request() then returns false without ever calling the handler.
  -- Ignoring that left the pending counter stuck, so every query burned its
  -- full 20s timeout and then blamed the server for being slow.
  H.it("is reported at once, not after the whole timeout", function()
    requires_go()
    in_fixture(function()
      local healthy = lsp.definition("main.go", 10, 14, { attach_timeout = 120000, request_timeout = 20000 })
      if not healthy then
        H.skip("no language server answered")
      end
      local clients = vim.lsp.get_clients({ bufnr = vim.fn.bufnr("main.go") })
      if #clients == 0 then
        H.skip("no client attached to the fixture")
      end
      local saved = {}
      for i, c in ipairs(clients) do
        saved[i] = c.request
        c.request = function()
          return false
        end
      end
      local started = vim.uv.now()
      local result, err = lsp.definition("main.go", 10, 14, { attach_timeout = 120000, request_timeout = 20000 })
      local took = vim.uv.now() - started
      for i, c in ipairs(clients) do
        c.request = saved[i]
      end
      H.falsy(result)
      H.matches("rejected the request", err, "got: " .. tostring(err))
      H.ok(took < 5000, ("it should fail fast, took %dms"):format(took))
    end)
  end)
end)

H.describe("querying many files from one instance", function()
  local lsp = require("kebab.lsp")

  local function loaded_count()
    local n = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        n = n + 1
      end
    end
    return n
  end

  -- `kebab serve` is long-lived: every query used to add a loaded buffer and a
  -- didOpen'd document for good, so a few thousand files meant a few thousand
  -- buffers.
  H.it("does not accumulate a buffer per query", function()
    requires_go()
    in_fixture(function(dir)
      for i = 1, 6 do
        H.write(dir .. ("/leak%d.go"):format(i), ("package main\n\nfunc leak%d() int { return %d }\n"):format(i, i))
      end
      local before = loaded_count()
      for i = 1, 6 do
        lsp.diagnostics(("leak%d.go"):format(i), { settle = 500, attach_timeout = 120000 })
      end
      local after = loaded_count()
      H.ok(after - before <= 2, ("buffers grew by %d over 6 queries"):format(after - before))
    end)
  end)

  H.it("leaves a buffer the user had open alone", function()
    requires_go()
    in_fixture(function(dir)
      H.write(dir .. "/mine.go", "package main\n\nfunc mine() int { return 1 }\n")
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/mine.go"))
      local mine = vim.api.nvim_get_current_buf()
      vim.cmd("enew")
      lsp.diagnostics("mine.go", { settle = 500, attach_timeout = 120000 })
      H.ok(vim.api.nvim_buf_is_loaded(mine), "a buffer this module did not open must survive")
      H.reset_editor()
    end)
  end)

  H.it("refuses a directory instead of blocking on it", function()
    local started = vim.uv.now()
    local result, err = lsp.diagnostics(H.tmpdir("a-directory"), { attach_timeout = 120000 })
    H.falsy(result)
    H.matches("not a file", err)
    H.ok(vim.uv.now() - started < 3000, "nothing will ever attach to a directory")
  end)
end)
