-- Project discovery, creation and the wizard.
--
-- Creation used to be reachable only through vim.ui prompts, so none of it
-- could be tested. M.create() takes its answers as data instead, and the wizard
-- is driven here through the harness's scripted vim.ui.
local H = ...
local project = require("kebab.project")
local registry = require("kebab.registry")

---Point discovery at scratch roots for the duration of fn.
local function with_roots(roots, fn)
  local saved = vim.g.kebab_project_roots
  vim.g.kebab_project_roots = roots
  local ok, err = pcall(fn)
  vim.g.kebab_project_roots = saved
  if not ok then error(err, 0) end
end

---Register a throwaway project type so create()'s own logic -- defaults,
---destination handling, failure reporting -- can be tested without a network
---round trip or a toolchain.
---
---Goes in through registry.register, which is the extension point a user is
---told to use, so the documented path is the one under test.
local function with_fake_type(def, fn)
  local fake = vim.tbl_extend("force", {
    key = "fake",
    label = "Fake (test only)",
    requires = {},
  }, def)
  registry.register({
    key = "faketest",
    label = "Fake language (test only)",
    markers = {},
    project_types = { fake },
  })
  local ok, err = pcall(fn, fake)
  registry.unregister("faketest")
  if not ok then error(err, 0) end
end

H.describe("project discovery", function()
  H.it("finds directories carrying a project marker", function()
    local root = H.tmpdir("roots")
    vim.fn.mkdir(root .. "/with-git/.git", "p")
    H.write(root .. "/with-pom/pom.xml", "<project/>")
    H.write(root .. "/with-pubspec/pubspec.yaml", "name: x")
    H.write(root .. "/with-package/package.json", "{}")
    H.write(root .. "/with-pyproject/pyproject.toml", "[project]")
    vim.fn.mkdir(root .. "/not-a-project", "p")

    with_roots({ root }, function()
      local found = project.discover()
      local names = vim.tbl_map(function(p) return p.name end, found)
      table.sort(names)
      H.eq({ "with-git", "with-package", "with-pom", "with-pubspec", "with-pyproject" }, names)
    end)
  end)

  H.it("labels each project with its kind", function()
    local root = H.tmpdir("kinds")
    H.write(root .. "/f/pubspec.yaml", "name: x")
    H.write(root .. "/m/pom.xml", "<project/>")
    H.write(root .. "/n/package.json", "{}")
    H.write(root .. "/p/requirements.txt", "")
    H.write(root .. "/g/build.gradle.kts", "")
    vim.fn.mkdir(root .. "/d/.git", "p")

    with_roots({ root }, function()
      local kinds = {}
      for _, p in ipairs(project.discover()) do
        kinds[p.name] = p.kind
      end
      H.eq({ f = "flutter", m = "maven", n = "node", p = "python", g = "gradle", d = "dir" }, kinds)
    end)
  end)

  H.it("survives a broken symlink in a project root", function()
    -- fs_scandir reports a link's own type, and fs_stat on a dangling link
    -- returns nil. Indexing that nil used to take the whole project list down.
    local root = H.tmpdir("brokenlink")
    vim.fn.mkdir(root .. "/real/.git", "p")
    vim.fn.system({ "ln", "-s", root .. "/does-not-exist", root .. "/dangling" })
    H.eq(0, vim.v.shell_error, "symlink should have been created")

    with_roots({ root }, function()
      local found = project.discover()
      H.eq(1, #found, "the real project should still be found")
      H.eq("real", found[1].name)
    end)
  end)

  H.it("reports a root the user named that does not exist", function()
    -- Not merely ignored: the whole point of the second return is that
    -- "that root is gone" and "that root holds no projects" used to look the
    -- same from the outside.
    with_roots({ "/definitely/not/here/at/all" }, function()
      local found, problems = project.discover()
      H.eq({}, found)
      H.eq(1, #problems, "a named root that is missing should be reported")
      H.eq("/definitely/not/here/at/all", problems[1].path)
      H.ok(problems[1].reason:find("ENOENT") ~= nil, "reason should say why: " .. problems[1].reason)
    end)
  end)

  H.it("says nothing about a missing default root", function()
    -- The defaults name roots most machines do not have; warning about those
    -- would train the user to ignore the warning.
    local saved_g, saved_env = vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS
    vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS = nil, nil
    local _, problems = project.discover()
    local missing = {}
    for _, pr in ipairs(problems) do
      if pr.reason:find("ENOENT") then
        missing[#missing + 1] = pr.path
      end
    end
    vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS = saved_g, saved_env
    H.eq({}, missing, "a default root that is absent is not a problem")
  end)

  H.it("reports a root that exists but cannot be read", function()
    local root = H.tmpdir("unreadable")
    vim.fn.mkdir(root .. "/locked", "p")
    H.write(root .. "/locked/.keep", "")
    vim.fn.mkdir(root .. "/open/.git", "p")
    vim.fn.system({ "chmod", "000", root .. "/locked" })
    H.eq(0, vim.v.shell_error, "chmod should have worked")

    local found, problems
    with_roots({ root }, function()
      found, problems = project.discover()
    end)
    vim.fn.system({ "chmod", "755", root .. "/locked" })

    H.eq({ "open" }, vim.tbl_map(function(pr) return pr.name end, found))
    H.eq(1, #problems, "the unreadable directory should be reported")
    H.eq(root .. "/locked", problems[1].path)
    H.ok(problems[1].reason:find("EACCES") ~= nil, "reason should say why: " .. problems[1].reason)
    -- the path is printed by problem_lines, so it is not repeated in the reason
    H.ok(problems[1].reason:find(root, 1, true) == nil, "reason should not repeat the path")
  end)

  H.it("lists each project once even if two roots overlap", function()
    local root = H.tmpdir("dedupe")
    vim.fn.mkdir(root .. "/thing/.git", "p")
    with_roots({ root, root }, function()
      H.eq(1, #project.discover())
    end)
  end)

  H.it("finds a project one grouping directory below a root", function()
    -- ~/Projects/work/<project> is the layout discovery kept missing: only
    -- immediate children were scanned, so the grouping directory -- which
    -- carries no marker of its own -- was a dead end.
    local root = H.tmpdir("grouped")
    vim.fn.mkdir(root .. "/flat-project/.git", "p")
    vim.fn.mkdir(root .. "/group/nested-project/.git", "p")
    vim.fn.mkdir(root .. "/group/deeper/too-deep-project/.git", "p")

    with_roots({ root }, function()
      local found = project.discover()
      local rels = vim.tbl_map(function(p) return p.rel end, found)
      table.sort(rels)
      H.eq({ "flat-project", "group/nested-project" }, rels,
        "two levels, and no further: too-deep-project is depth 3")
    end)
  end)

  H.it("names a nested project by its path below the root", function()
    local root = H.tmpdir("relnames")
    vim.fn.mkdir(root .. "/group/alpha-api/.git", "p")
    with_roots({ root }, function()
      local found = project.discover()
      H.eq(1, #found)
      H.eq("alpha-api", found[1].name, "name stays the basename, so `kebab open alpha-api` matches")
      H.eq("group/alpha-api", found[1].rel, "rel says which one, for the picker")
    end)
  end)

  H.it("respects vim.g.kebab_project_depth", function()
    local root = H.tmpdir("depth1")
    vim.fn.mkdir(root .. "/flat/.git", "p")
    vim.fn.mkdir(root .. "/group/nested/.git", "p")
    local saved = vim.g.kebab_project_depth
    vim.g.kebab_project_depth = 1
    local names
    with_roots({ root }, function()
      names = vim.tbl_map(function(p) return p.name end, project.discover())
    end)
    vim.g.kebab_project_depth = saved
    H.eq({ "flat" }, names, "depth 1 is immediate children only")
  end)

  H.it("does not descend into a project, or into build output", function()
    -- A checkout with a vendored dependency tree is one project, not a
    -- hundred: this is what keeps a depth of 2 affordable.
    local root = H.tmpdir("nodescend")
    vim.fn.mkdir(root .. "/app/.git", "p")
    vim.fn.mkdir(root .. "/app/node_modules/dep/.git", "p")
    vim.fn.mkdir(root .. "/node_modules/loose/.git", "p")
    vim.fn.mkdir(root .. "/target/gen/.git", "p")

    with_roots({ root }, function()
      H.eq({ "app" }, vim.tbl_map(function(p) return p.name end, project.discover()))
    end)
  end)

  H.it("finds a hidden project but does not walk through one", function()
    local root = H.tmpdir("hidden")
    vim.fn.mkdir(root .. "/.dotfiles/.git", "p")
    vim.fn.mkdir(root .. "/.cache/sub/.git", "p")
    with_roots({ root }, function()
      H.eq({ ".dotfiles" }, vim.tbl_map(function(p) return p.name end, project.discover()))
    end)
  end)

  H.it("stops at the scan limit and says so", function()
    local root = H.tmpdir("budget")
    vim.fn.mkdir(root .. "/a/one/.git", "p")
    vim.fn.mkdir(root .. "/b/two/.git", "p")
    local saved = vim.g.kebab_project_scan_limit
    vim.g.kebab_project_scan_limit = 1
    local found, problems
    with_roots({ root }, function()
      found, problems = project.discover()
    end)
    vim.g.kebab_project_scan_limit = saved
    H.eq({}, found, "only the root itself was read, and it holds no project")
    H.eq(1, #problems)
    H.ok(problems[1].reason:find("scan stopped") ~= nil, "reason: " .. problems[1].reason)
  end)

  H.it("sorts case-insensitively by name", function()
    local root = H.tmpdir("sorted")
    for _, n in ipairs({ "Zebra", "apple", "Mango" }) do
      vim.fn.mkdir(root .. "/" .. n .. "/.git", "p")
    end
    with_roots({ root }, function()
      H.eq({ "apple", "Mango", "Zebra" }, vim.tbl_map(function(p) return p.name end, project.discover()))
    end)
  end)
end)

H.describe("the Open Project picker", function()
  H.it("offers a nested project by its path below the root", function()
    local root = H.tmpdir("pickrel")
    vim.fn.mkdir(root .. "/group/alpha-api/.git", "p")
    local labels
    with_roots({ root }, function()
      H.capture_notify(function()
        H.with_ui({ function(items)
          labels = vim.tbl_map(function(i) return i.rel end, items)
          return nil -- cancel: opening would cd and leave a tree window behind
        end }, function()
          project.open_project()
        end)
      end)
    end)
    H.eq({ "group/alpha-api" }, labels)
  end)

  H.it("warns about a root it could not read, and still offers the rest", function()
    local root = H.tmpdir("pickwarn")
    vim.fn.mkdir(root .. "/good/.git", "p")
    local notes, count
    with_roots({ root, "/definitely/not/here/at/all" }, function()
      notes = H.capture_notify(function()
        H.with_ui({ function(items)
          count = #items
          return nil
        end }, function()
          project.open_project()
        end)
      end)
    end)
    H.eq(1, count, "the readable root's project is still offered")
    local joined = table.concat(vim.tbl_map(function(n) return n.msg end, notes), "\n")
    H.matches("/definitely/not/here/at/all", joined)
    H.ok(notes[1].level == vim.log.levels.WARN, "a skipped root is a warning")
  end)
end)

H.describe("project roots", function()
  H.it("takes vim.g.kebab_project_roots", function()
    with_roots({ "/a", "/b" }, function()
      H.eq({ "/a", "/b" }, project.roots())
      H.eq("g", project.roots_source())
    end)
  end)

  H.it("reads KEBAB_PROJECT_ROOTS", function()
    local saved_g, saved_env = vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS
    vim.g.kebab_project_roots = nil
    vim.env.KEBAB_PROJECT_ROOTS = "/x:/y:/z"
    local got, source = project.roots(), project.roots_source()
    vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS = saved_g, saved_env
    H.eq({ "/x", "/y", "/z" }, got)
    H.eq("env", source)
  end)

  H.it("lets the environment beat the config, because it is per invocation", function()
    -- `KEBAB_PROJECT_ROOTS=/tmp/x kebab list` has to mean /tmp/x. It used to
    -- mean "whatever the config says", so the documented override silently
    -- did nothing for anyone who had set the global -- which is anyone with
    -- more than one project directory.
    local saved_g, saved_env = vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS
    vim.g.kebab_project_roots = { "/from/config" }
    vim.env.KEBAB_PROJECT_ROOTS = "/from/the/command/line"
    local got, source = project.roots(), project.roots_source()
    vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS = saved_g, saved_env
    H.eq({ "/from/the/command/line" }, got)
    H.eq("env", source)
  end)

  H.it("ignores an empty KEBAB_PROJECT_ROOTS", function()
    -- The suite sets it to "" for the shell specs; empty must not mean
    -- "no roots at all", or discovery finds nothing and says nothing.
    local saved_g, saved_env = vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS
    vim.g.kebab_project_roots = { "/from/config" }
    vim.env.KEBAB_PROJECT_ROOTS = ""
    local got = project.roots()
    vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS = saved_g, saved_env
    H.eq({ "/from/config" }, got)
  end)

  H.it("has sensible defaults otherwise", function()
    local saved_g, saved_env = vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS
    vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS = nil, nil
    local got = project.roots()
    vim.g.kebab_project_roots, vim.env.KEBAB_PROJECT_ROOTS = saved_g, saved_env
    H.ok(vim.tbl_contains(got, "~/Projects"), "~/Projects should be a default root")
  end)
end)

H.describe("project types", function()
  H.it("exposes the expected set", function()
    -- Order follows the language load order in registry.lua.
    H.eq({ "flutter", "spring", "maven", "kotlin", "ruby", "rust", "go", "python", "node", "vite", "empty" },
      project.type_keys())
  end)

  H.it("covers Go, Rust, Kotlin and Ruby", function()
    H.eq("Go module", project.type_by_key("go").label)
    H.eq("Rust (cargo)", project.type_by_key("rust").label)
    H.eq("Kotlin (Gradle)", project.type_by_key("kotlin").label)
    H.eq("Ruby (bundler + rspec)", project.type_by_key("ruby").label)
  end)

  H.it("offers JavaScript as well as TypeScript", function()
    local node = project.type_by_key("node")
    local languages
    for _, p in ipairs(node.prompts or {}) do
      if p.name == "language" then languages = p.choices end
    end
    H.eq({ "typescript", "javascript" }, languages,
      "the node scaffold should ask, not assume TypeScript")

    local vite = project.type_by_key("vite")
    local templates
    for _, p in ipairs(vite.prompts or {}) do
      if p.name == "template" then templates = p.choices end
    end
    for _, want in ipairs({ "react-ts", "react", "svelte-ts", "svelte", "vue-ts", "vue" }) do
      H.ok(vim.tbl_contains(templates, want), want .. " should be an offered Vite template")
    end
  end)

  H.it("looks a type up by key", function()
    H.eq("Spring Boot (Maven, Java 21)", project.type_by_key("spring").label)
    H.falsy(project.type_by_key("nope"))
  end)

  H.it("gives every type a label, a build function and a requirement list", function()
    for _, t in ipairs(project.project_types()) do
      H.ok(type(t.label) == "string" and t.label ~= "", t.key .. " needs a label")
      H.ok(type(t.build) == "function", t.key .. " needs a build function")
      H.ok(type(t.requires) == "table", t.key .. " needs a requires list")
      H.ok(type(t.language) == "string", t.key .. " should be tagged with its language")
    end
  end)

  H.it("reports requirements that are not on PATH", function()
    H.eq({}, project.missing_requirements({ requires = {} }))
    H.eq({ "definitely-not-a-real-binary" },
      project.missing_requirements({ requires = { "definitely-not-a-real-binary" } }))
  end)
end)

H.describe("project create", function()
  H.it("rejects an unknown type", function()
    local got
    local notes = H.capture_notify(function()
      project.create({ type = "nonsense", name = "x", open = false }, function(ok, err) got = { ok, err } end)
    end)
    H.eq(false, got[1])
    H.matches("Unknown project type", got[2])
    H.ok(H.notified(notes, "Unknown project type"))
  end)

  H.it("rejects a missing name", function()
    local got
    H.capture_notify(function()
      project.create({ type = "empty", open = false }, function(ok, err) got = { ok, err } end)
    end)
    H.eq(false, got[1])
    H.matches("name is required", got[2])
  end)

  H.it("refuses to scaffold into a directory that already has files", function()
    local dir = H.tmpdir("occupied")
    H.write(dir .. "/existing.txt", "mine")
    local got
    H.capture_notify(function()
      project.create({ type = "empty", name = "x", dest = dir, open = false },
        function(ok, err) got = { ok, err } end)
    end)
    H.eq(false, got[1])
    H.matches("exists and is not empty", got[2])
    H.eq("mine", H.read(dir .. "/existing.txt"), "the existing file must be untouched")
  end)

  H.it("reports a missing requirement instead of failing obscurely", function()
    with_fake_type({ requires = { "definitely-not-a-real-binary" } }, function()
      local got
      H.capture_notify(function()
        project.create({ type = "fake", name = "x", dest = H.tmpdir("req") .. "/p", open = false },
          function(ok, err) got = { ok, err } end)
      end)
      H.eq(false, got[1])
      H.matches("needs definitely%-not%-a%-real%-binary on PATH", got[2])
    end)
  end)

  H.it("fills unanswered prompts from the type's defaults", function()
    local seen
    with_fake_type({
      prompts = {
        { name = "group", prompt = "Group: ", default = "com.example" },
        { name = "deps", prompt = "Deps: ", default = "web" },
      },
      build = function(ctx, done) seen = ctx; done(true) end,
    }, function()
      local dest = H.tmpdir("defaults") .. "/proj"
      local done = false
      H.capture_notify(function()
        project.create({ type = "fake", name = "proj", dest = dest, open = false,
          answers = { group = "io.gulay" } }, function() done = true end)
      end)
      H.ok(done, "create should have completed")
      H.eq("io.gulay", seen.answers.group, "a supplied answer is kept")
      H.eq("web", seen.answers.deps, "an omitted answer comes from the default")
      H.eq(dest, seen.dest)
      H.eq("proj", seen.name)
    end)
  end)

  H.it("warns about an answer the type does not ask for", function()
    -- `kebab new --<name> <value>` passes anything through, which is what keeps
    -- the shell script free of per-language knowledge. A typo must not be
    -- swallowed in silence.
    local seen
    with_fake_type({
      prompts = { { name = "group", prompt = "Group: ", default = "com.example" } },
      build = function(ctx, done) seen = ctx; done(true) end,
    }, function()
      local notes = H.capture_notify(function()
        project.create({
          type = "fake", name = "p", dest = H.tmpdir("unused-answer") .. "/p", open = false,
          answers = { group = "io.gulay", deps = "web" },
        }, function() end)
      end)
      local warned = H.notified(notes, "does not ask for deps")
      H.ok(warned, "it should say the answer went unused")
      H.matches("it asks for: group", warned.msg, "and say what it does ask for")
      H.ok(seen, "and still build, since the answer is merely unused")
      H.eq("io.gulay", seen.answers.group)
    end)
  end)

  H.it("says so when a type asks nothing at all", function()
    with_fake_type({ build = function(_, done) done(true) end }, function()
      local notes = H.capture_notify(function()
        project.create({
          type = "fake", name = "p", dest = H.tmpdir("asks-nothing") .. "/p", open = false,
          answers = { whatever = "x" },
        }, function() end)
      end)
      H.ok(H.notified(notes, "it asks nothing"))
    end)
  end)

  H.it("does not warn when every answer is used", function()
    with_fake_type({
      prompts = { { name = "group", prompt = "Group: ", default = "com.example" } },
      build = function(_, done) done(true) end,
    }, function()
      local notes = H.capture_notify(function()
        project.create({
          type = "fake", name = "p", dest = H.tmpdir("all-used") .. "/p", open = false,
          answers = { group = "io.gulay" },
        }, function() end)
      end)
      H.no_warnings(notes)
    end)
  end)

  H.it("passes the build failure reason back to the caller", function()
    with_fake_type({
      build = function(_, done) done(false, "the build said no") end,
    }, function()
      local got
      H.capture_notify(function()
        project.create({ type = "fake", name = "x", dest = H.tmpdir("buildfail") .. "/p", open = false },
          function(ok, err) got = { ok, err } end)
      end)
      H.eq(false, got[1])
      H.eq("the build said no", got[2])
    end)
  end)

  H.it("reports a build step whose executable is missing, instead of throwing", function()
    -- requires/missing_requirements catches a type's declared tools up front;
    -- this is the guard for anything a build step runs beyond those.
    local S = require("kebab.scaffold")
    local real = vim.fn.executable
    with_fake_type({
      build = function(ctx, done)
        S.run_steps({ { label = "the missing tool", cmd = { "definitely-not-a-binary", "x" } } },
          ctx.dest, done)
      end,
    }, function()
      local result
      local ok, err = pcall(function()
        H.capture_notify(function()
          project.create({ type = "fake", name = "p", dest = H.tmpdir("step-nobin") .. "/p", open = false },
            function(o, e) result = { o, e } end)
          H.wait(10000, function() return result ~= nil end, "the build to report")
        end)
      end)
      vim.fn.executable = real
      H.ok(ok, "it must not throw: " .. tostring(err))
      H.eq(false, result[1])
      H.matches("definitely%-not%-a%-binary is not installed", result[2])
    end)
  end)

  H.it("creates an empty project: README plus a git repository", function()
    local dest = H.tmpdir("empty-type") .. "/my-thing"
    local result
    H.capture_notify(function()
      project.create({ type = "empty", name = "my-thing", dest = dest, open = false },
        function(ok, err) result = { ok = ok, err = err } end)
      H.wait(15000, function() return result ~= nil end, "create to finish")
    end)
    H.ok(result.ok, "creation should succeed: " .. tostring(result.err))
    H.ok(H.exists(dest .. "/README.md"), "README.md should exist")
    H.matches("# my%-thing", H.read(dest .. "/README.md"))
    H.ok(H.exists(dest .. "/.git"), "should be a git repository")
  end)

  H.it("creates a python project: venv, pyproject and an entry point", function()
    if vim.fn.executable("python3") == 0 then
      H.skip("python3 is not on PATH")
    end
    -- Debian and Ubuntu ship python3 without ensurepip (it is in
    -- python3-venv), so `python3 -m venv` fails with "ensurepip is not
    -- available". The scaffold is right; the machine is incomplete.
    vim.fn.system({ "python3", "-c", "import ensurepip" })
    if vim.v.shell_error ~= 0 then
      H.skip("python3 has no ensurepip (install python3-venv)")
    end
    local dest = H.tmpdir("python-type") .. "/pyproj"
    local result
    H.capture_notify(function()
      project.create({ type = "python", name = "pyproj", dest = dest, open = false },
        function(ok, err) result = { ok = ok, err = err } end)
      H.wait(120000, function() return result ~= nil end, "python project creation")
    end)
    H.ok(result.ok, "creation should succeed: " .. tostring(result.err))
    H.ok(H.exists(dest .. "/src/main.py"), "src/main.py should exist")
    H.matches('print%("hello"%)', H.read(dest .. "/src/main.py"))
    H.matches('name = "pyproj"', H.read(dest .. "/pyproject.toml"))
    H.matches("%.venv/", H.read(dest .. "/.gitignore"))
    H.ok(H.exists(dest .. "/.git"), "should be a git repository")
    H.ok(H.exists(dest .. "/.venv"), ".venv should have been created")
  end)
end)

H.describe("where a new project is offered", function()
  H.it("is the first configured root, not a hardcoded directory", function()
    local saved = vim.g.kebab_project_roots
    local env = vim.env.KEBAB_PROJECT_ROOTS
    vim.env.KEBAB_PROJECT_ROOTS = nil
    vim.g.kebab_project_roots = { "/tmp/kebab-root-a", "/tmp/kebab-root-b" }
    H.eq("/tmp/kebab-root-a", project.default_parent())
    vim.g.kebab_project_roots = nil
    H.matches("/Projects$", project.default_parent(), "with nothing configured, ~/Projects")
    vim.g.kebab_project_roots = saved
    vim.env.KEBAB_PROJECT_ROOTS = env
  end)

  H.it("expands a root written with a tilde", function()
    local saved = vim.g.kebab_project_roots
    local env = vim.env.KEBAB_PROJECT_ROOTS
    vim.env.KEBAB_PROJECT_ROOTS = nil
    vim.g.kebab_project_roots = { "~/some-where" }
    H.eq(vim.env.HOME .. "/some-where", project.default_parent())
    vim.g.kebab_project_roots = saved
    vim.env.KEBAB_PROJECT_ROOTS = env
  end)

  H.it("is what the wizard puts in the Location box", function()
    local saved = vim.g.kebab_project_roots
    local env = vim.env.KEBAB_PROJECT_ROOTS
    vim.env.KEBAB_PROJECT_ROOTS = nil
    local parent = H.tmpdir("offered")
    vim.g.kebab_project_roots = { parent }
    local ui = H.with_ui({ "Empty (git + README)", "thing", H.CANCEL }, function()
      project.new_project()
    end)
    vim.g.kebab_project_roots = saved
    vim.env.KEBAB_PROJECT_ROOTS = env
    local shown = nil
    for _, ask in ipairs(ui.log) do
      if ask.prompt and ask.prompt:find("Location") then
        shown = ask.default
      end
    end
    H.eq(parent .. "/thing", shown, "the Location box is prefilled from the root")
  end)
end)

H.describe("the new-project wizard", function()
  H.it("walks type, name and location, then builds", function()
    local parent = H.tmpdir("wizard")
    local dest = parent .. "/wizard-made"
    H.with_ui({ "Empty (git + README)", "wizard-made", dest }, function()
      H.capture_notify(function()
        project.new_project()
        -- README.md is written synchronously but `git init` is not, so waiting
        -- on the README would return before the project is actually finished.
        H.wait(15000, function() return H.exists(dest .. "/.git") end, "the wizard to create the project")
      end)
    end)
    H.matches("# wizard%-made", H.read(dest .. "/README.md"))
    H.ok(H.exists(dest .. "/.git"))
  end)

  H.it("asks a type's own questions after the location", function()
    local asked = {}
    local seen
    with_fake_type({
      prompts = {
        { name = "group", prompt = "Group id: ", default = "com.example" },
      },
      build = function(ctx, done) seen = ctx; done(true) end,
    }, function()
      local dest = H.tmpdir("wizard-prompts") .. "/p"
      local ui = H.with_ui({ "Fake (test only)", "p", dest, "io.gulay" }, function()
        H.capture_notify(function()
          project.new_project()
          H.wait(10000, function() return seen ~= nil end, "the fake build to run")
        end)
      end)
      asked = ui.log
      H.eq("io.gulay", seen.answers.group, "the type's prompt should reach the build")
      H.eq(4, #asked, "type, name, location, then the type's own question")
      H.matches("Project type", asked[1].prompt)
      H.matches("Project name", asked[2].prompt)
      H.matches("Location", asked[3].prompt)
      H.matches("Group id", asked[4].prompt)
    end)
  end)

  H.it("stops cleanly when the type picker is cancelled", function()
    H.with_ui({ H.CANCEL }, function()
      local notes = H.capture_notify(function() project.new_project() end)
      H.no_warnings(notes)
    end)
  end)

  H.it("stops cleanly when the name is left blank", function()
    H.with_ui({ "Empty (git + README)", "" }, function()
      local notes = H.capture_notify(function() project.new_project() end)
      H.no_warnings(notes)
    end)
  end)
end)

H.describe("scaffolding into the current directory", function()
  H.it("fills an empty directory without asking for confirmation", function()
    local dir = H.tmpdir("inithere-empty")
    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    H.with_ui({ "Empty (git + README)" }, function()
      H.capture_notify(function()
        project.init_here()
        H.wait(15000, function() return H.exists(dir .. "/.git") end, "init_here to scaffold")
      end)
    end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    H.ok(H.exists(dir .. "/.git"), "should be a git repository")
    H.ok(H.exists(dir .. "/README.md"), "README.md should exist")
  end)

  H.it("asks first when the directory is not empty, and honours No", function()
    local dir = H.tmpdir("inithere-busy")
    H.write(dir .. "/keep.txt", "mine")
    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    local ui = H.with_ui({ "No" }, function()
      H.capture_notify(function() project.init_here() end)
    end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    H.eq(1, ui.consumed(), "it should have asked exactly once")
    H.matches("not empty", ui.log[1].prompt)
    H.falsy(H.exists(dir .. "/README.md"), "nothing should have been scaffolded")
    H.eq("mine", H.read(dir .. "/keep.txt"))
  end)
end)

-- Every one of these left the caller with no answer at all, which is a hang
-- rather than a failure for `kebab new --no-open`.
H.describe("project.create always answers", function()
  local P = require("kebab.project")

  local function create(spec)
    local answered, ok, err = false, nil, nil
    spec.open = false
    spec.type = spec.type or "empty"
    P.create(spec, function(o, e)
      answered, ok, err = true, o, e
    end)
    H.wait(60000, function()
      return answered
    end, "create should always call done")
    return ok, err
  end

  H.it("refuses a destination that is not a directory", function()
    local dir = H.tmpdir("create-file")
    H.write(dir .. "/afile", "x")
    -- readdir() on a file returns an empty list, so this looked empty and the
    -- scaffold threw later instead
    local ok, err = create({ name = "a", dest = dir .. "/afile" })
    H.falsy(ok)
    H.matches("Not a directory", err)
  end)

  H.it("refuses a non-empty directory unless the caller allows it", function()
    local dir = H.tmpdir("create-nonempty")
    H.write(dir .. "/existing.txt", "x")
    local ok, err = create({ name = "a", dest = dir })
    H.falsy(ok)
    H.matches("not empty", err)

    -- :IdeInitHere asks the user and then passes this, so its "Scaffold into
    -- it anyway?" confirmation leads somewhere
    local ok2, err2 = create({ name = "a", dest = dir, allow_non_empty = true })
    H.ok(ok2, tostring(err2))
  end)

  H.it("answers when a build throws instead of hanging", function()
    local reg = require("kebab.registry")
    reg.register({
      key = "throwlang",
      label = "Throws",
      project_types = {
        {
          key = "throws",
          label = "Throws",
          build = function()
            error("kaboom")
          end,
        },
      },
    })
    local ok, err = create({ name = "a", type = "throws", dest = H.tmpdir("create-throw") .. "/new" })
    reg.reset()
    H.falsy(ok)
    H.matches("kaboom", err, "the reason has to reach the caller: " .. tostring(err))
  end)
end)
