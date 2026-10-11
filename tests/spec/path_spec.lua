-- kebab.path: expanding a path that came from outside the editor.
--
-- `vim.fn.expand()` is Vim's expansion, and Vim's expansion runs the shell for
-- anything in backticks -- so every path this layer took from an argument, a
-- prompt or a config variable was a command-execution sink.
local H = ...
local P = require("kebab.path")

H.describe("kebab.path.expand", function()
  H.it("does not run a shell command in backticks", function()
    local marker = H.tmpdir("path-pwn") .. "/pwn"
    local payload = ("`touch %s`"):format(marker)

    -- the sink as it was: proof the payload is live, not theoretical
    vim.fn.expand(payload)
    H.ok(H.exists(marker), "vim.fn.expand should have run it -- otherwise this test proves nothing")
    vim.fn.delete(marker)

    local out = P.expand(payload)
    H.falsy(H.exists(marker), "kebab.path.expand must not run it")
    H.eq(payload, out, "and it should hand the path back untouched")
  end)

  H.it("still expands the things a path needs", function()
    H.eq(vim.fn.expand("~") .. "/Projects", P.expand("~/Projects"))
    H.eq(vim.env.HOME .. "/x", P.expand("$HOME/x"))
    H.eq("/tmp/a/b", P.expand("/tmp/a/b"))
    H.eq("/tmp/a/b", P.expand("/tmp//a/b/"), "and normalises, so two paths compare equal")
  end)

  H.it("leaves anything that is not a string alone", function()
    H.eq(nil, P.expand(nil))
    H.eq("", P.expand(""))
    H.eq(42, P.expand(42))
  end)

  H.it("can spot a path that would be shell-expanded", function()
    H.ok(P.is_shell_expansion("`cmd`"))
    H.ok(P.is_shell_expansion("/tmp/`cmd`/x"))
    H.falsy(P.is_shell_expansion("/tmp/x"))
    H.falsy(P.is_shell_expansion(nil))
  end)
end)

H.describe("the paths that reach the editor from outside", function()
  -- Each of these took a path from an argument, a prompt or a config variable
  -- and handed it to vim.fn.expand.
  H.it("never shells out for a project root, a store or a jdbc file", function()
    local dir = H.tmpdir("path-sinks")
    local function payload(name)
      return ("`touch %s/%s`"):format(dir, name)
    end

    local saved = {
      db = vim.g.kebab_db_store,
      jdbc = vim.g.kebab_jdbc_dir,
      scratch = vim.g.kebab_scratch_dir,
    }
    vim.g.kebab_db_store = payload("db")
    vim.g.kebab_jdbc_dir = payload("jdbc")
    vim.g.kebab_scratch_dir = payload("scratch")
    require("kebab.db").store_path()
    require("kebab.jdbc").cache_dir()
    require("kebab.scratch").dir()
    vim.g.kebab_db_store, vim.g.kebab_jdbc_dir, vim.g.kebab_scratch_dir = saved.db, saved.jdbc, saved.scratch

    require("kebab.jdbc").build_url({ url = "jdbc:sqlite:{file}" }, { file = payload("url") })
    require("kebab.lsp").resolve_path(payload("lsp"))

    for _, name in ipairs({ "db", "jdbc", "scratch", "url", "lsp" }) do
      H.falsy(H.exists(dir .. "/" .. name), name .. " path was shell-expanded")
    end
  end)
end)
