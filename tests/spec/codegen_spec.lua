-- Named code generation: constructor, getters, toString, override.
local H = ...
local cg = require("kebab.codegen")
local registry = require("kebab.registry")

H.describe("codegen declarations", function()
  H.it("offers the Java generators a graphical IDE has", function()
    local names = vim.tbl_map(function(g) return g.name end, cg.for_filetype("java"))
    for _, want in ipairs({
      "Constructor...",
      "Getters and Setters...",
      "toString()...",
      "equals() and hashCode()...",
      "Override/Implement Methods...",
      "Delegate Methods...",
      "Organize Imports",
    }) do
      H.ok(vim.tbl_contains(names, want), want .. " should be offered")
    end
  end)

  -- The kinds were read back off a live jdtls, because guessing them from the
  -- camelCase field names inside the jdt.ls jars produced six dead entries.
  -- This is the verified set; see the comment in languages/java.lua for how to
  -- re-derive it.
  H.it("uses the dot-separated kinds the server actually implements", function()
    local by_name = {}
    for _, g in ipairs(cg.for_filetype("java")) do
      by_name[g.name] = g.kind
    end
    H.eq("source.generate.constructors", by_name["Constructor..."])
    H.eq("source.generate.accessors", by_name["Getters and Setters..."])
    H.eq("source.generate.toString", by_name["toString()..."])
    H.eq("source.generate.hashCodeEquals", by_name["equals() and hashCode()..."])
    H.eq("source.generate.delegateMethods", by_name["Delegate Methods..."])
    H.eq("source.overrideMethods", by_name["Override/Implement Methods..."])
    H.eq("source.organizeImports", by_name["Organize Imports"])
  end)

  H.it("uses no camelCase generate kinds, which are not real", function()
    for _, g in ipairs(registry.collect("codegen")) do
      H.falsy(g.kind:match("^source%.generate%u"),
        ("%s uses %q; the server's kinds are dot-separated"):format(g.name, g.kind))
    end
  end)

  H.it("gives every generator a name, a kind and filetypes", function()
    for _, g in ipairs(registry.collect("codegen")) do
      H.ok(type(g.name) == "string" and g.name ~= "", "a generator needs a name")
      H.ok(type(g.kind) == "string" and g.kind:match("^source%."),
        g.name .. " should name a source action kind")
      H.ok(type(g.filetypes) == "table" and #g.filetypes > 0,
        g.name .. " should say which filetypes it applies to")
    end
  end)

  H.it("offers nothing for a language that declares none", function()
    H.eq({}, cg.for_filetype("python"))
    H.eq({}, cg.for_filetype(""))
  end)
end)

H.describe("finding a generator by name", function()
  local function in_java(fn)
    vim.cmd("enew!")
    vim.bo.filetype = "java"
    local ok, err = pcall(fn)
    if not ok then error(err, 0) end
  end

  H.it("matches a full name", function()
    in_java(function()
      H.eq("source.organizeImports", cg.by_name("Organize Imports").kind)
    end)
  end)

  H.it("ignores case", function()
    in_java(function()
      H.eq("source.organizeImports", cg.by_name("organize imports").kind)
    end)
  end)

  H.it("falls back to a substring", function()
    in_java(function()
      H.eq("source.generate.toString", cg.by_name("tostring").kind)
      H.eq("source.generate.constructors", cg.by_name("constructor").kind)
    end)
  end)

  H.it("returns nothing for an unknown name", function()
    in_java(function()
      H.eq(nil, cg.by_name("no such generator"))
    end)
  end)

  H.it("finds nothing in a buffer with no generators", function()
    vim.cmd("enew!")
    vim.bo.filetype = "python"
    H.eq(nil, cg.by_name("constructor"))
  end)
end)

H.describe("running a generator", function()
  H.it("says so plainly when no language server is attached", function()
    -- The failure a user is most likely to hit, and the one that must not be
    -- silent: the actions only exist while jdtls is running.
    vim.cmd("enew!")
    vim.bo.filetype = "java"
    local notes = H.capture_notify(function()
      cg.run({ name = "Constructor...", kind = "source.generate.constructors" })
    end)
    H.ok(H.notified(notes, "needs a language server"), "should explain why nothing happened")
  end)

  H.it("refuses a generator with no kind", function()
    local notes = H.capture_notify(function() cg.run({ name = "broken" }) end)
    H.ok(H.notified(notes, "nothing to run"))
    local notes2 = H.capture_notify(function() cg.run(nil) end)
    H.ok(H.notified(notes2, "nothing to run"))
  end)

  H.it("reports no attached server when asking what is available", function()
    vim.cmd("enew!")
    vim.bo.filetype = "java"
    local got
    cg.available("source.generate.toString", 0, function(actions, err)
      got = { actions = actions, err = err }
    end)
    H.ok(got, "the callback should fire even with no server")
    H.eq({}, got.actions)
    H.matches("No language server", got.err)
  end)
end)

H.describe("the generate picker", function()
  H.it("warns instead of opening an empty picker", function()
    vim.cmd("enew!")
    vim.bo.filetype = "python"
    local notes = H.capture_notify(function() cg.pick() end)
    H.ok(H.notified(notes, "Nothing to generate"))
  end)

  H.it("offers every Java generator", function()
    vim.cmd("enew!")
    vim.bo.filetype = "java"
    local offered
    local orig = vim.ui.select
    vim.ui.select = function(items, opts)
      offered = vim.tbl_map(function(i) return opts.format_item(i) end, items)
    end
    cg.pick()
    vim.ui.select = orig
    H.ok(offered and #offered >= 7, "expected the full list, got " .. vim.inspect(offered))
    H.ok(vim.tbl_contains(offered, "toString()..."))
  end)

  H.it("runs the chosen generator", function()
    vim.cmd("enew!")
    vim.bo.filetype = "java"
    -- No server is attached, so "ran it" shows up as the no-server message
    -- naming the generator that was picked.
    local notes
    H.with_ui({ "toString()..." }, function()
      notes = H.capture_notify(function() cg.pick() end)
    end)
    H.ok(H.notified(notes, "toString"), "the picked generator should have been run")
  end)
end)

H.describe("the :IdeGenerate command", function()
  H.it("is registered", function()
    H.ok(vim.fn.exists(":IdeGenerate") >= 1)
  end)

  H.it("reports an unknown generator with the list of real ones", function()
    vim.cmd("enew!")
    vim.bo.filetype = "java"
    local notes = H.capture_notify(function()
      vim.cmd("IdeGenerate nonsense")
    end)
    local n = H.notified(notes, "No generator matching")
    H.ok(n, "should say it did not match")
    H.matches("toString", n.msg, "and list what is available")
  end)

  H.it("runs a generator named as an argument", function()
    vim.cmd("enew!")
    vim.bo.filetype = "java"
    local notes = H.capture_notify(function()
      vim.cmd("IdeGenerate tostring")
    end)
    H.ok(H.notified(notes, "needs a language server"),
      "it should have reached the generator")
  end)
end)
