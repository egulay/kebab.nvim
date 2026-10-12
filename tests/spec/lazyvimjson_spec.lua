-- The extras LazyVim arbitrates, recorded where it can see them.
--
-- The bug: on a *fresh* config the file tree never appeared. LazyVim allows
-- one explorer, decides which while its own spec is built -- before this
-- layer's spec exists -- and then refuses the losing side's imports with no
-- warning. `plugins/extras.lua` imports `editor.neo-tree`; that import is
-- nested inside `import = "kebab.plugins"`, so it is invisible to the
-- decision, snacks explorer wins, and everything built on neo-tree has
-- nothing to attach to. Invisible on the author's machine, whose lazyvim.json
-- already listed the extra -- found by installing into a container.
local H = ...

local J = require("kebab.lazyvimjson")

local function read(path)
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

H.describe("recording an extra in lazyvim.json", function()
  H.it("creates the file when there is none", function()
    local path = H.tmpdir("lvjson-new") .. "/lazyvim.json"
    local changed, err, added = J.ensure({ path = path })
    H.ok(changed, "it should have written something")
    H.eq(nil, err)
    H.eq({ "lazyvim.plugins.extras.editor.neo-tree" }, added)
    local data = read(path)
    H.eq({ "lazyvim.plugins.extras.editor.neo-tree" }, data.extras)
    -- Leaving install_version out makes LazyVim read the file as a pre-8
    -- install and switch the *picker* default too, which nobody asked for.
    H.ok(type(data.install_version) == "number", "install_version should be written")
    H.ok(type(data.version) == "number", "version should be written")
  end)

  H.it("changes nothing the second time", function()
    local path = H.tmpdir("lvjson-twice") .. "/lazyvim.json"
    J.ensure({ path = path })
    local before = table.concat(vim.fn.readfile(path), "\n")
    local changed, err, added = J.ensure({ path = path })
    H.eq(false, changed, "already recorded")
    H.eq(nil, err)
    H.eq({}, added)
    H.eq(before, table.concat(vim.fn.readfile(path), "\n"), "the file should be untouched")
  end)

  H.it("keeps the extras and the keys already in the file", function()
    local path = H.tmpdir("lvjson-merge") .. "/lazyvim.json"
    vim.fn.writefile({ vim.json.encode({
      extras = { "lazyvim.plugins.extras.lang.go", "lazyvim.plugins.extras.coding.yanky" },
      version = 9,
      install_version = 9,
      news = { ["NEWS.md"] = "10960" },
    }) }, path)
    local changed = J.ensure({ path = path })
    H.ok(changed)
    local data = read(path)
    H.eq(3, #data.extras, "the user's own extras should still be there")
    H.ok(vim.tbl_contains(data.extras, "lazyvim.plugins.extras.lang.go"))
    H.ok(vim.tbl_contains(data.extras, "lazyvim.plugins.extras.editor.neo-tree"))
    H.eq(9, data.version, "an existing version is not rewritten")
    H.eq("10960", data.news["NEWS.md"], "and neither is anything else")
  end)

  H.it("reports a file it cannot parse instead of overwriting it", function()
    local path = H.tmpdir("lvjson-bad") .. "/lazyvim.json"
    vim.fn.writefile({ "{ this is not json" }, path)
    local changed, err = J.ensure({ path = path })
    H.eq(false, changed)
    H.matches("not valid JSON", tostring(err))
    H.matches("this is not json", table.concat(vim.fn.readfile(path), "\n"),
      "a file it does not understand must be left as it is")
  end)

  H.it("replaces an extras value that is not a list", function()
    -- vim.json decodes `{}` to a table either way; a malformed extras value
    -- should not stop the layer from recording what it needs.
    local path = H.tmpdir("lvjson-obj") .. "/lazyvim.json"
    vim.fn.writefile({ '{"extras": {"nonsense": true}, "version": 8}' }, path)
    H.ok(J.ensure({ path = path }))
    H.eq({ "lazyvim.plugins.extras.editor.neo-tree" }, read(path).extras)
  end)

  H.it("a dry run writes nothing", function()
    local path = H.tmpdir("lvjson-dry") .. "/lazyvim.json"
    local changed = J.ensure({ path = path, dry = true })
    H.ok(changed, "it should still say it would change something")
    H.eq(0, vim.fn.filereadable(path), "but write nothing")
  end)
end)

H.describe("the explorer this layer needs", function()
  H.it("is in play in this session", function()
    -- If this fails on a real machine the tree is not there at all: run
    -- setup.sh again, which records it in lazyvim.json.
    local ok, detail = J.explorer_ready()
    H.ok(ok, "neo-tree should be the explorer: " .. detail)
  end)

  H.it("is what the extras list declares", function()
    local declared = {}
    for _, spec in ipairs(dofile(_G.KEBAB_TEST.root .. "/lua/kebab/plugins/extras.lua")) do
      if spec.import then
        declared[#declared + 1] = spec.import
      end
    end
    for _, extra in ipairs(J.REQUIRED_EXTRAS) do
      H.ok(vim.tbl_contains(declared, extra), extra .. " should be imported by the layer too")
    end
  end)

  H.it("is reported by doctor, because its absence is silent otherwise", function()
    local found
    for _, check in ipairs(require("kebab.cli").doctor()) do
      if check.name:find("explorer") then
        found = check
      end
    end
    H.ok(found ~= nil, "doctor should have a check for the explorer")
    H.eq("Required", found.section, "a missing tree is not a missing nicety")
  end)
end)

H.describe("an extra that needs a newer Neovim", function()
  H.it("is only imported when that version is running", function()
    -- refactoring.nvim raises "requires Neovim 0.12 or higher" as it loads,
    -- and on 0.11 that abandoned the rest of the startup. Importing it
    -- unconditionally made the version floor in the README a broken install.
    local declared = {}
    for _, spec in ipairs(dofile(_G.KEBAB_TEST.root .. "/lua/kebab/plugins/extras.lua")) do
      if spec.import then
        declared[#declared + 1] = spec.import
      end
    end
    local has = vim.tbl_contains(declared, "lazyvim.plugins.extras.editor.refactoring")
    H.eq(vim.fn.has("nvim-0.12") == 1, has,
      "refactoring belongs in the list only on 0.12 and up")
  end)
end)
