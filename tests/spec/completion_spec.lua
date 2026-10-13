-- Shell completion for `kebab`.
--
-- Asked for directly: "on the kebab cli stuff there is no auto fill (like with
-- tab similar to standard terminal feature)".
--
-- The constraint that shapes the whole thing: completion has to answer in
-- milliseconds, and every real `kebab` command starts an editor. So
-- `kebab __complete` reads a cache that `kebab.complete` writes on the way out
-- of the commands that pay for an editor anyway -- and the assertion that it
-- never needs one is to run it with KEBAB_NVIM pointed at nothing.
local H = ...

local root = _G.KEBAB_TEST.root
local kebab = root .. "/bin/kebab"
local complete = require("kebab.complete")

---Run `kebab __complete`, with no usable editor on purpose.
---@param words string[] the command line as typed
---@param env? table
---@return string[] candidates
local function candidates(words, env)
  local cmd = { kebab, "__complete", tostring(#words - 1) }
  vim.list_extend(cmd, words)
  local res = vim.system(cmd, {
    text = true,
    env = vim.tbl_extend("force", { KEBAB_NVIM = "/nonexistent/nvim" }, env or {}),
  }):wait(30000)
  H.eq(0, res.code, "__complete should succeed without an editor: " .. (res.stderr or ""))
  local out = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    out[#out + 1] = line
  end
  return out
end

---Write a cache of our own, so a test never depends on the author's.
---@param dir string a fake XDG_CACHE_HOME
local function cache_into(dir)
  local path = dir .. "/nvim/kebab/completion"
  local wrote, err = require("kebab.fs").write_lines(path, complete.lines())
  H.ok(wrote, tostring(err))
  return path
end

H.describe("the completion cache", function()
  H.it("lists the commands bin/kebab dispatches, and every query", function()
    local sections = {}
    for _, line in ipairs(complete.lines()) do
      local section, value = line:match("^([^\t]+)\t(.*)$")
      sections[section] = sections[section] or {}
      sections[section][#sections[section] + 1] = value
    end
    for _, name in ipairs({ "open", "new", "types", "db", "list", "doctor", "serve" }) do
      H.ok(vim.tbl_contains(sections.command, name), name .. " should be completable")
    end
    -- The queries come from kebab.agent's own list, not a copy of it: adding a
    -- query must not need an edit here.
    for _, name in ipairs(require("kebab.agent").COMMANDS) do
      H.ok(vim.tbl_contains(sections.command, name), name .. " is a command")
      H.ok(vim.tbl_contains(sections.query, name), name .. " is a query")
    end
  end)

  H.it("lists exactly the project types the registry declares", function()
    -- An earlier attempt grepped `key = "..."` out of the language files and
    -- collected 36 names for 11 types, because scratch kinds and file
    -- templates use the same field. This is why the cache exists.
    local want = {}
    for _, type_def in ipairs(require("kebab.registry").project_types()) do
      want[#want + 1] = type_def.key
    end
    local got = {}
    for _, line in ipairs(complete.lines()) do
      local value = line:match("^type\t(.*)$")
      if value then
        got[#got + 1] = value
      end
    end
    table.sort(want)
    table.sort(got)
    H.eq(want, got)
  end)

  H.it("lists the prompts a type declares, as options", function()
    local got = {}
    for _, line in ipairs(complete.lines()) do
      local value = line:match("^answer\t(.*)$")
      if value then
        got[value] = true
      end
    end
    -- the Maven and Spring types both ask for a group id
    H.ok(got["group"], "--group should be completable: " .. vim.inspect(vim.tbl_keys(got)))
    H.ok(got["module"], "--module (Go) should be completable")
  end)

  H.it("writes itself where the shell looks", function()
    H.matches("/kebab/completion$", complete.path())
    local dir = H.tmpdir("complete-write")
    local wrote = require("kebab.fs").write_lines(dir .. "/completion", complete.lines())
    H.ok(wrote)
  end)
end)

H.describe("kebab __complete", function()
  H.it("answers with no editor on the machine at all", function()
    -- The point of the whole design: `kebab list` costs an editor start, and a
    -- completion that slow is one nobody keeps installed.
    local dir = H.tmpdir("complete-cache")
    cache_into(dir)
    local got = candidates({ "kebab", "" }, { XDG_CACHE_HOME = dir })
    H.ok(vim.tbl_contains(got, "doctor"), "expected the commands, got " .. vim.inspect(got))
    H.ok(vim.tbl_contains(got, "diagnostics"))
  end)

  H.it("offers the command names even with no cache", function()
    local empty = H.tmpdir("complete-nocache")
    local got = candidates({ "kebab", "" }, { XDG_CACHE_HOME = empty })
    H.ok(vim.tbl_contains(got, "open"), "a fresh install still completes subcommands")
    H.falsy(vim.tbl_contains(got, "diagnostics"),
      "without the cache it must not invent the query names")
  end)

  H.it("completes --type from the cache", function()
    local dir = H.tmpdir("complete-type")
    cache_into(dir)
    local got = candidates({ "kebab", "new", "thing", "--type", "" }, { XDG_CACHE_HOME = dir })
    H.ok(vim.tbl_contains(got, "spring"), vim.inspect(got))
    H.ok(vim.tbl_contains(got, "empty"))
  end)

  H.it("completes a project name from the configured roots", function()
    local parent = H.tmpdir("complete-roots")
    vim.fn.mkdir(parent .. "/alpha-api", "p")
    vim.fn.mkdir(parent .. "/alpha-cli", "p")
    local got = candidates({ "kebab", "open", "" }, { KEBAB_PROJECT_ROOTS = parent })
    H.ok(vim.tbl_contains(got, "alpha-api"), vim.inspect(got))
    H.ok(vim.tbl_contains(got, "alpha-cli"))
  end)

  H.it("completes a saved connection name, without reading a password", function()
    local dir = H.tmpdir("complete-db")
    local store = dir .. "/connections.json"
    H.write(store, vim.json.encode({
      connections = {
        { name = "shop_local", url = "jdbc:sqlite:/tmp/shop.sqlite" },
        { name = "warehouse", url = "jdbc:postgresql://localhost:5432/wh",
          user = "reader", password_env = "WH_PASSWORD" },
      },
    }))
    local got = candidates({ "kebab", "db", "" }, { KEBAB_DB_STORE = store })
    H.ok(vim.tbl_contains(got, "shop_local"), vim.inspect(got))
    H.ok(vim.tbl_contains(got, "warehouse"))
    H.falsy(vim.tbl_contains(got, "WH_PASSWORD"),
      "the completion reads names, not credentials")
  end)

  H.it("asks the shell for files where only the shell can help", function()
    local dir = H.tmpdir("complete-files")
    cache_into(dir)
    H.ok(vim.tbl_contains(candidates({ "kebab", "diagnostics", "" }, { XDG_CACHE_HOME = dir }),
      "__files"), "a file argument is the shell's job")
    H.ok(vim.tbl_contains(candidates({ "kebab", "new", "x", "--dir", "" }, { XDG_CACHE_HOME = dir }),
      "__dirs"), "--dir takes a directory")
    H.ok(vim.tbl_contains(candidates({ "kebab", "new", "" }, { XDG_CACHE_HOME = dir }),
      "__nothing"), "a new project's name is the user's to invent")
  end)

  H.it("is fast enough to be worth having", function()
    local dir = H.tmpdir("complete-speed")
    cache_into(dir)
    local started = vim.uv.hrtime()
    candidates({ "kebab", "" }, { XDG_CACHE_HOME = dir })
    local ms = (vim.uv.hrtime() - started) / 1e6
    -- Measured at ~3ms; a second is a generous bound that still fails if this
    -- ever starts an editor, which takes 200ms at the very best.
    H.ok(ms < 1000, ("a completion took %.0fms"):format(ms))
  end)
end)

H.describe("the shell scripts", function()
  H.it("ship for bash and zsh", function()
    H.ok(H.exists(root .. "/completions/kebab.bash"))
    H.ok(H.exists(root .. "/completions/_kebab"))
  end)

  H.it("the bash one is valid bash", function()
    local res = vim.system({ "bash", "-n", root .. "/completions/kebab.bash" }, { text = true })
      :wait(30000)
    H.eq(0, res.code, res.stderr or "")
  end)

  H.it("the zsh one is valid zsh, where there is a zsh to ask", function()
    if vim.fn.executable("zsh") == 0 then
      -- Honest rather than silent: it is unchecked on this machine.
      H.skip("zsh is not installed, so its syntax is unverified here")
    end
    local res = vim.system({ "zsh", "-n", root .. "/completions/_kebab" }, { text = true })
      :wait(30000)
    H.eq(0, res.code, res.stderr or "")
  end)

  H.it("keeps a name with a space in one piece", function()
    -- `compgen -W` splits its word list on IFS, so a project directory called
    -- "sample app" arrived as two candidates and completing it inserted
    -- `sample` -- a name that does not exist. The script filters and escapes
    -- itself now; this drives bash to prove it.
    local parent = H.tmpdir("complete-space")
    vim.fn.mkdir(parent .. "/sample app", "p")
    vim.fn.mkdir(parent .. "/plain-name", "p")
    local script = ([[
      set -e
      export PATH=%s:$PATH
      export KEBAB_PROJECT_ROOTS=%s
      source %s
      COMP_WORDS=(kebab open sam); COMP_CWORD=2; COMPREPLY=()
      _kebab
      printf '%%s
' "${COMPREPLY[@]}"
    ]]):format(
      vim.fn.shellescape(root .. "/bin"),
      vim.fn.shellescape(parent),
      vim.fn.shellescape(root .. "/completions/kebab.bash"))
    local res = vim.system({ "bash", "-c", script }, { text = true }):wait(60000)
    H.eq(0, res.code, res.stderr or "")
    local out = vim.trim(res.stdout or "")
    H.eq(1, #vim.split(out, "\n", { trimempty = true }),
      "one candidate, not two halves of a name: " .. out)
    H.matches("sample\\ app", out, "the space has to survive as one word")
  end)

  H.it("bash really completes, driven through bash's own machinery", function()
    -- `complete -F` and COMPREPLY, not the helper: what is asserted here is
    -- that pressing Tab would work, including the prefix filtering bash does.
    local script = ([[
      set -e
      export PATH=%s:$PATH
      source %s
      COMP_WORDS=(kebab doc); COMP_CWORD=1; COMPREPLY=()
      _kebab
      printf '%%s\n' "${COMPREPLY[@]}"
    ]]):format(vim.fn.shellescape(root .. "/bin"),
      vim.fn.shellescape(root .. "/completions/kebab.bash"))
    local res = vim.system({ "bash", "-c", script }, { text = true }):wait(60000)
    H.eq(0, res.code, res.stderr or "")
    H.matches("doctor", res.stdout or "", "`kebab doc<Tab>` should offer doctor")
  end)
end)
