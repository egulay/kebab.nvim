-- The language registry, and the de-hardcoding it exists for.
--
-- Every fact about a stack used to live in whichever file needed it: project
-- types in project.lua, Mason tools in plugins/mason.lua, LazyVim extras in
-- plugins/extras.lua, run configurations in plugins/run.lua, the dependency
-- command in deps.lua. Adding Go meant editing five files and remembering all
-- five. These tests check that a language is one declarative file, and -- just
-- as importantly -- that the five consumers have not quietly grown their own
-- copies again.
local H = ...
local registry = require("kebab.registry")

local root = _G.KEBAB_TEST.root

local function source(path)
  return table.concat(vim.fn.readfile(root .. "/" .. path), "\n")
end

---Source with comment lines stripped, so a comment may name a language while
---the code may not.
local function code(path)
  local out = {}
  for _, line in ipairs(vim.fn.readfile(root .. "/" .. path)) do
    if not line:match("^%s*%-%-") then
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

H.describe("the registry", function()
  H.it("loads every built-in language", function()
    local keys = registry.keys()
    for _, want in ipairs({ "java", "python", "dart", "javascript", "go", "rust", "web", "data", "generic" }) do
      H.ok(vim.tbl_contains(keys, want), want .. " should be registered")
    end
  end)

  H.it("gives every language a key and a label", function()
    for _, lang in ipairs(registry.languages()) do
      H.ok(type(lang.key) == "string" and lang.key ~= "", "a language needs a key")
      H.ok(type(lang.label) == "string" and lang.label ~= "", lang.key .. " needs a label")
    end
  end)

  H.it("has no duplicate keys", function()
    local seen = {}
    for _, lang in ipairs(registry.languages()) do
      H.falsy(seen[lang.key], "duplicate language key: " .. lang.key)
      seen[lang.key] = true
    end
  end)

  H.it("normalises markers, whether declared as a string or a table", function()
    for _, m in ipairs(registry.markers()) do
      H.ok(type(m.file) == "string" and m.file ~= "", "a marker needs a file")
      H.ok(type(m.kind) == "string" and m.kind ~= "", m.file .. " needs a kind")
      H.ok(type(m.language) == "string", m.file .. " should name its language")
    end
  end)

  H.it("puts the bare git marker last, so a real build system wins", function()
    local markers = registry.markers()
    local git_index
    for i, m in ipairs(markers) do
      if m.file == ".git" then
        git_index = i
      end
    end
    H.ok(git_index, ".git should be a marker")
    H.eq(#markers, git_index, ".git must be the last marker checked")
  end)

  H.it("tags each project type with the language that offers it", function()
    for _, t in ipairs(registry.project_types()) do
      H.ok(type(t.key) == "string" and t.key ~= "", "a project type needs a key")
      H.ok(type(t.label) == "string" and t.label ~= "", t.key .. " needs a label")
      H.ok(type(t.build) == "function", t.key .. " needs a build function")
      H.ok(type(t.requires) == "table", t.key .. " needs a requires list")
      H.ok(type(t.language) == "string", t.key .. " should be tagged with its language")
    end
  end)

  H.it("deduplicates aggregated lists", function()
    for _, field in ipairs({ "extras", "tools" }) do
      local seen = {}
      for _, item in ipairs(registry[field]()) do
        H.falsy(seen[item], "duplicate " .. field .. " entry: " .. tostring(item))
        seen[item] = true
      end
    end
  end)

  H.it("identifies a project by its marker", function()
    local dir = H.tmpdir("reg-detect")
    H.write(dir .. "/Cargo.toml", "[package]")
    H.eq(true, registry.is_project(dir))
    H.eq("rust", (registry.kind_of(dir)))
  end)

  H.it("is not a project without a marker", function()
    H.eq(false, registry.is_project(H.tmpdir("reg-bare")))
    H.eq(nil, (registry.kind_of(H.tmpdir("reg-bare2"))))
  end)

  H.it("walks up to find the project root", function()
    local dir = H.tmpdir("reg-walk")
    H.write(dir .. "/go.mod", "module x")
    vim.fn.mkdir(dir .. "/internal/deep", "p")
    local kind, marker = registry.find_project(dir .. "/internal/deep")
    H.eq("go", kind)
    H.eq(dir .. "/go.mod", marker)
  end)
end)

H.describe("extending the registry", function()
  H.it("registers a brand new language", function()
    registry.register({
      key = "cobol",
      label = "COBOL",
      markers = { { file = "cobol.toml", kind = "cobol" } },
      tools = { "cobol-lsp" },
      project_types = { { key = "cobol", label = "COBOL job", requires = {}, build = function(_, d) d(true) end } },
    })
    H.ok(vim.tbl_contains(registry.keys(), "cobol"))
    H.ok(vim.tbl_contains(registry.tools(), "cobol-lsp"))
    local keys = vim.tbl_map(function(t) return t.key end, registry.project_types())
    H.ok(vim.tbl_contains(keys, "cobol"))

    local dir = H.tmpdir("cobol")
    H.write(dir .. "/cobol.toml", "x")
    H.eq("cobol", (registry.kind_of(dir)))

    registry.unregister("cobol")
    H.falsy(vim.tbl_contains(registry.keys(), "cobol"))
  end)

  H.it("merges over a built-in language instead of replacing it", function()
    -- The point of merging: change one field without restating the rest.
    local before = registry.language("go")
    H.ok(before, "go should exist")
    local original_label = before.label
    local original_tasks = #before.tasks

    registry.register({ key = "go", label = "Go (my build)" })
    local after = registry.language("go")
    H.eq("Go (my build)", after.label, "the overridden field should change")
    H.eq(original_tasks, #after.tasks, "everything else should survive the merge")
    H.ok(#after.project_types > 0, "its project types should survive")

    registry.register({ key = "go", label = original_label })
    H.eq(original_label, registry.language("go").label)
  end)

  H.it("reads vim.g.kebab_languages", function()
    local saved = vim.g.kebab_languages
    vim.g.kebab_languages = {
      { key = "zig", label = "Zig", markers = { { file = "build.zig", kind = "zig" } }, tools = { "zls" } },
    }
    registry.reset()
    H.ok(vim.tbl_contains(registry.keys(), "zig"), "a language from vim.g should load")
    H.ok(vim.tbl_contains(registry.tools(), "zls"))

    vim.g.kebab_languages = saved
    registry.reset()
    H.falsy(vim.tbl_contains(registry.keys(), "zig"))
  end)

  H.it("accepts vim.g.kebab_languages as a function", function()
    local saved = vim.g.kebab_languages
    vim.g.kebab_languages = function()
      return { { key = "nim", label = "Nim", markers = {} } }
    end
    registry.reset()
    H.ok(vim.tbl_contains(registry.keys(), "nim"))
    vim.g.kebab_languages = saved
    registry.reset()
  end)

  H.it("keeps build functions intact through vim.g", function()
    -- vim.g stores Lua values as luarefs, so a project type's build function
    -- survives. If that ever stopped being true, scaffolds added by a user's
    -- config would silently become uncallable.
    local saved = vim.g.kebab_languages
    vim.g.kebab_languages = {
      {
        key = "fnlang",
        label = "Fn",
        markers = {},
        project_types = { { key = "fnscaffold", label = "Fn", requires = {}, build = function() return 7 end } },
      },
    }
    registry.reset()
    local t
    for _, pt in ipairs(registry.project_types()) do
      if pt.key == "fnscaffold" then t = pt end
    end
    H.ok(t, "the type should be registered")
    H.eq("function", type(t.build))
    H.eq(7, t.build())
    vim.g.kebab_languages = saved
    registry.reset()
  end)

  H.it("drops a language listed in vim.g.kebab_disabled_languages", function()
    local saved = vim.g.kebab_disabled_languages
    vim.g.kebab_disabled_languages = { "rust" }
    registry.reset()
    H.falsy(vim.tbl_contains(registry.keys(), "rust"), "rust should be gone")
    local keys = vim.tbl_map(function(t) return t.key end, registry.project_types())
    H.falsy(vim.tbl_contains(keys, "rust"), "and so should its scaffold")
    H.falsy(vim.tbl_contains(registry.tools(), "rust-analyzer"), "and its tooling")

    vim.g.kebab_disabled_languages = saved
    registry.reset()
    H.ok(vim.tbl_contains(registry.keys(), "rust"), "and come back when re-enabled")
  end)
end)

-- The structural half: the consumers must keep asking the registry rather than
-- growing their own lists again. Each assertion below names a string that used
-- to be hardcoded in that file.
H.describe("nothing is hardcoded any more", function()
  H.it("plugins/mason.lua lists no tools of its own", function()
    local src = code("lua/kebab/plugins/mason.lua")
    H.matches("registry", src, "it should ask the registry")
    for _, tool in ipairs({ "jdtls", "basedpyright", "vtsls", "gopls", "rust%-analyzer", "prettier" }) do
      H.falsy(src:match(tool), tool .. " should come from a language definition, not this file")
    end
  end)

  H.it("plugins/extras.lua lists no language extras of its own", function()
    local src = code("lua/kebab/plugins/extras.lua")
    H.matches("registry", src, "it should ask the registry")
    for _, extra in ipairs({ "lang%.java", "lang%.python", "lang%.dart", "lang%.go", "lang%.rust", "lang%.svelte" }) do
      H.falsy(src:match(extra), extra .. " should come from a language definition")
    end
  end)

  H.it("plugins/run.lua declares no tasks of its own", function()
    local src = code("lua/kebab/plugins/run.lua")
    H.matches("registry", src, "it should ask the registry")
    for _, token in ipairs({ "mvnw", "spring%-boot:run", "pubspec", "pytest", "cargo", "go test" }) do
      H.falsy(src:match(token), token .. " should come from a language definition")
    end
  end)

  H.it("project.lua knows no markers or project types of its own", function()
    local src = code("lua/kebab/project.lua")
    H.matches("registry", src, "it should ask the registry")
    for _, token in ipairs({ "pom%.xml", "pubspec%.yaml", "Cargo%.toml", "go%.mod", "start%.spring%.io", "npm" }) do
      H.falsy(src:match(token), token .. " should come from a language definition")
    end
  end)

  H.it("deps.lua knows no ecosystems of its own", function()
    local src = code("lua/kebab/deps.lua")
    H.matches("registry", src, "it should ask the registry")
    for _, token in ipairs({ "npm install", "flutter pub", "cargo add", "go get", "uv add", "pyproject" }) do
      H.falsy(src:match(token), token .. " should come from a language definition")
    end
  end)

  H.it("every language definition is a file of its own", function()
    local files = vim.fn.readdir(root .. "/lua/kebab/languages")
    H.ok(#files >= 9, "expected a file per language, found " .. #files)
    for _, f in ipairs(files) do
      H.matches("%.lua$", f, "only language definitions belong here")
      local lang = dofile(root .. "/lua/kebab/languages/" .. f)
      H.eq(f:gsub("%.lua$", ""), lang.key, f .. " should declare a key matching its filename")
    end
  end)
end)

-- `generic` claims the `.git` marker and the empty scaffold, so it is the
-- fallback and must be tested last. A language added by a user was appended
-- *after* it, which made the new language unreachable.
H.describe("where a user-added language is ranked", function()
  local reg = require("kebab.registry")

  local function with_project(fn)
    local dir = H.tmpdir("ranked")
    vim.fn.mkdir(dir .. "/.git", "p")
    H.write(dir .. "/mything.toml", "")
    fn(dir)
  end

  local LANG = {
    key = "mylang",
    label = "My Lang",
    kind = "mything",
    markers = { { file = "mything.toml", kind = "mything" } },
  }

  H.it("ranks a vim.g language before generic", function()
    with_project(function(dir)
      local saved = vim.g.kebab_languages
      vim.g.kebab_languages = { LANG }
      reg.reset()
      local keys = reg.keys()
      H.eq("generic", keys[#keys], "generic has to stay last: " .. table.concat(keys, ","))
      H.eq("mything", reg.kind_of(dir), "generic's .git marker would otherwise win")
      vim.g.kebab_languages = saved
      reg.reset()
    end)
  end)

  H.it("ranks a registered language before generic", function()
    with_project(function(dir)
      reg.reset()
      reg.register(vim.deepcopy(LANG))
      local keys = reg.keys()
      H.eq("generic", keys[#keys], "generic has to stay last: " .. table.concat(keys, ","))
      H.eq("mything", reg.kind_of(dir))
      reg.reset()
    end)
  end)

  H.it("survives a project type with no key", function()
    local saved = vim.g.kebab_languages
    vim.g.kebab_languages = { { key = "broken", label = "B", project_types = { { label = "no key" } } } }
    reg.reset()
    local ok, err = pcall(reg.project_types)
    vim.g.kebab_languages = saved
    reg.reset()
    H.ok(ok, "one keyless type must not take down every caller: " .. tostring(err))
  end)

  H.it("reports a kebab_languages function that errors", function()
    local saved = vim.g.kebab_languages
    vim.g.kebab_languages = function()
      error("boom")
    end
    local notes = H.capture_notify(function()
      reg.reset()
      reg.languages()
    end)
    vim.g.kebab_languages = saved
    reg.reset()
    H.ok(H.notified(notes, "kebab_languages failed"), "silently dropping the whole config is worse: " .. vim.inspect(notes))
  end)
end)
