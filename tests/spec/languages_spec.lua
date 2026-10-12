-- Each language definition, checked on its own terms.
local H = ...
local registry = require("kebab.registry")

H.describe("every language declaration", function()
  for _, lang in ipairs(registry.languages()) do
    H.it(lang.key .. " is well formed", function()
      H.ok(type(lang.label) == "string" and lang.label ~= "", "needs a label")
      H.ok(type(lang.markers) == "table", "needs a markers list, even an empty one")
      for _, field in ipairs({ "extras", "tools", "tasks", "project_types" }) do
        if lang[field] ~= nil then
          H.ok(type(lang[field]) == "table", field .. " should be a list")
        end
      end
    end)

    H.it(lang.key .. " declares runnable tasks", function()
      for _, task in ipairs(lang.tasks or {}) do
        H.ok(type(task.name) == "string" and task.name ~= "", "a task needs a name")
        H.ok(type(task.desc) == "string" and task.desc ~= "", task.name .. " needs a desc")
        H.ok(type(task.cmd) == "table" or type(task.cmd) == "function",
          task.name .. " needs a cmd (a list, or a function returning one)")
        -- Without a condition a task shows up in every project, which is how a
        -- task list becomes useless.
        H.ok(task.marker ~= nil or task.filetypes ~= nil,
          task.name .. " needs a marker or a filetype to be offered under")
        if type(task.cmd) == "table" then
          H.ok(type(task.cmd[1]) == "string", task.name .. " cmd should start with an executable")
        end
      end
    end)

    H.it(lang.key .. " names LazyVim extras that exist", function()
      -- A typo here is silent: lazy.nvim imports nothing and says nothing.
      for _, extra in ipairs(lang.extras or {}) do
        -- Both module shapes count: lang.typescript is a directory with an
        -- init.lua, lang.go is a single file.
        local base = "lua/" .. extra:gsub("%.", "/")
        local found = #vim.api.nvim_get_runtime_file(base .. ".lua", false) > 0
          or #vim.api.nvim_get_runtime_file(base .. "/init.lua", false) > 0
        H.ok(found, extra .. " is not on the runtimepath (typo?)")
      end
    end)
  end
end)

H.describe("Go", function()
  local go = registry.language("go")

  H.it("is detected by go.mod", function()
    local dir = H.tmpdir("go-detect")
    H.write(dir .. "/go.mod", "module example.com/x\n\ngo 1.23")
    H.eq("go", (registry.kind_of(dir)))
  end)

  H.it("adds dependencies with go get, without tidying them away again", function()
    local deps = registry.deps_for("go")
    H.eq({ "go", "get", "github.com/stretchr/testify" },
      deps.command("github.com/stretchr/testify"))
    H.eq(nil, deps.after, "go mod tidy would delete a requirement nothing imports yet")
    -- tidy is still available on purpose, as a task you run when you mean it
    local names = vim.tbl_map(function(t) return t.name end, registry.language("go").tasks)
    H.ok(vim.tbl_contains(names, "go: mod tidy"))
  end)

  H.it("offers the tasks a Go developer expects", function()
    local names = vim.tbl_map(function(t) return t.name end, go.tasks)
    for _, want in ipairs({ "go: run", "go: test ./...", "go: build", "go: vet", "go: mod tidy" }) do
      H.ok(vim.tbl_contains(names, want), want .. " should be a task")
    end
  end)

  H.it("installs gopls and delve", function()
    for _, tool in ipairs({ "gopls", "delve" }) do
      H.ok(vim.tbl_contains(go.tools, tool), tool .. " should be installed")
    end
  end)

  H.it("scaffolds a module", function()
    if vim.fn.executable("go") == 0 then
      H.skip("go is not on PATH")
    end
    local project = require("kebab.project")
    local dest = H.tmpdir("go-new") .. "/mytool"
    local result
    H.capture_notify(function()
      project.create({
        type = "go", name = "mytool", dest = dest, open = false,
        answers = { module = "example.com/mytool" },
      }, function(ok, err) result = { ok = ok, err = err } end)
      H.wait(120000, function() return result ~= nil end, "go project creation")
    end)
    H.ok(result.ok, tostring(result.err))
    H.matches("module example%.com/mytool", H.read(dest .. "/go.mod"))
    H.matches("func main%(%)", H.read(dest .. "/main.go"))
    H.ok(H.exists(dest .. "/.git"))
  end)

  H.it("refuses to scaffold when the toolchain is missing, with a clear reason", function()
    -- Exercised by overriding what the Go scaffold requires rather than by
    -- checking whether go happens to be installed: a test that skips itself on
    -- a machine with a working toolchain is a test that never runs where it
    -- matters.
    local project = require("kebab.project")
    registry.register({
      key = "go",
      project_types = {
        {
          key = "go",
          label = "Go module",
          requires = { "definitely-not-a-real-go" },
          build = function(_, done) done(true) end,
        },
      },
    })
    local got
    H.capture_notify(function()
      project.create({ type = "go", name = "x", dest = H.tmpdir("go-missing") .. "/x", open = false },
        function(ok, err) got = { ok, err } end)
    end)
    registry.reset() -- put the real definition back
    H.eq(false, got[1])
    H.matches("needs definitely%-not%-a%-real%-go on PATH", got[2])
    H.matches("Go module", got[2], "the message should name the scaffold")
  end)
end)

H.describe("Rust", function()
  local rust = registry.language("rust")

  H.it("is detected by Cargo.toml", function()
    local dir = H.tmpdir("rust-detect")
    H.write(dir .. "/Cargo.toml", "[package]\nname = \"x\"")
    H.eq("rust", (registry.kind_of(dir)))
  end)

  H.it("adds dependencies with cargo add", function()
    local deps = registry.deps_for("rust")
    H.eq({ "cargo", "add", "serde" }, deps.command("serde"))
    H.eq({ "cargo", "add", "--dev", "rstest" }, deps.command("rstest", { dev = true }))
  end)

  H.it("offers the tasks a Rust developer expects", function()
    local names = vim.tbl_map(function(t) return t.name end, rust.tasks)
    for _, want in ipairs({ "cargo: run", "cargo: test", "cargo: build", "cargo: clippy", "cargo: fmt" }) do
      H.ok(vim.tbl_contains(names, want), want .. " should be a task")
    end
  end)

  H.it("installs rust-analyzer and a debugger", function()
    for _, tool in ipairs({ "rust-analyzer", "codelldb" }) do
      H.ok(vim.tbl_contains(rust.tools, tool), tool .. " should be installed")
    end
  end)

  H.it("asks whether the crate is a binary or a library", function()
    local t = require("kebab.project").type_by_key("rust")
    local choices
    for _, p in ipairs(t.prompts or {}) do
      if p.name == "kind" then choices = p.choices end
    end
    H.eq({ "bin", "lib" }, choices)
  end)

  H.it("scaffolds a crate", function()
    if vim.fn.executable("cargo") == 0 then
      H.skip("cargo is not on PATH")
    end
    local project = require("kebab.project")
    local dest = H.tmpdir("rust-new") .. "/mycrate"
    local result
    H.capture_notify(function()
      project.create({
        type = "rust", name = "mycrate", dest = dest, open = false,
        answers = { kind = "bin" },
      }, function(ok, err) result = { ok = ok, err = err } end)
      H.wait(120000, function() return result ~= nil end, "rust project creation")
    end)
    H.ok(result.ok, tostring(result.err))
    H.matches('name = "mycrate"', H.read(dest .. "/Cargo.toml"))
    H.ok(H.exists(dest .. "/src/main.rs"))
  end)
end)

H.describe("Kotlin", function()
  local kotlin = registry.language("kotlin")

  H.it("claims no markers of its own", function()
    -- A Kotlin project is built with Gradle, which java.lua already claims --
    -- including the dependency editing, which is the same dependencies { }
    -- block whatever language is inside.
    H.eq({}, kotlin.markers)
    local dir = H.tmpdir("kt-detect")
    H.write(dir .. "/build.gradle.kts", "plugins { }")
    H.eq("gradle", (registry.kind_of(dir)), "it is detected as a Gradle project")
  end)

  H.it("offers the gradle tasks a Kotlin developer expects", function()
    local names = vim.tbl_map(function(t) return t.name end, kotlin.tasks)
    for _, want in ipairs({ "gradle: run", "gradle: test", "gradle: build", "gradle: ktlintCheck" }) do
      H.ok(vim.tbl_contains(names, want), want .. " should be a task")
    end
  end)

  H.it("prefers the wrapper when the project ships one", function()
    local task
    for _, t in ipairs(kotlin.tasks) do
      if t.name == "gradle: test" then task = t end
    end
    H.eq("function", type(task.cmd), "the wrapper is only knowable at run time")
  end)

  H.it("installs a language server and a linter", function()
    for _, tool in ipairs({ "kotlin-language-server", "ktlint" }) do
      H.ok(vim.tbl_contains(kotlin.tools, tool), tool .. " should be installed")
    end
  end)

  H.it("scaffolds a Gradle project that needs only git", function()
    local project = require("kebab.project")
    local dest = H.tmpdir("kt-new") .. "/mykt"
    local result
    H.capture_notify(function()
      project.create({
        type = "kotlin", name = "mykt", dest = dest, open = false,
        answers = { package = "io.gulay.mykt" },
      }, function(ok, err) result = { ok = ok, err = err } end)
      H.wait(60000, function() return result ~= nil end, "kotlin project creation")
    end)
    H.ok(result.ok, tostring(result.err))
    H.matches('rootProject%.name = "mykt"', H.read(dest .. "/settings.gradle.kts"))
    H.matches('kotlin%("jvm"%)', H.read(dest .. "/build.gradle.kts"))
    H.matches("^package io%.gulay%.mykt", H.read(dest .. "/src/main/kotlin/io/gulay/mykt/Main.kt"))
    H.ok(H.exists(dest .. "/src/test/kotlin/io/gulay/mykt/MainTest.kt"), "and a test to run")
    H.ok(H.exists(dest .. "/.git"))
  end)

  H.it("adds a dependency by editing the Gradle build", function()
    local deps = require("kebab.deps")
    local dir = H.tmpdir("kt-dep")
    H.write(dir .. "/build.gradle.kts", table.concat({
      "plugins {", '    kotlin("jvm") version "2.0.21"', "}", "",
      "dependencies {", '    testImplementation(kotlin("test"))', "}",
    }, "\n"))
    local result
    H.capture_notify(function()
      deps.add("com.squareup.okhttp3:okhttp:4.12.0",
        { cwd = dir, done = function(ok, err) result = { ok, err } end })
    end)
    H.ok(result[1], tostring(result[2]))
    H.matches('implementation%("com%.squareup%.okhttp3:okhttp:4%.12%.0"%)',
      H.read(dir .. "/build.gradle.kts"))
  end)

  H.it("has templates that derive the package from the directory", function()
    local T = require("kebab.templates")
    local dir = H.tmpdir("kt-tmpl") .. "/src/main/kotlin/io/gulay/svc"
    vim.fn.mkdir(dir, "p")
    local template
    for _, t in ipairs(registry.templates()) do
      if t.name == "Kotlin data class" then template = t end
    end
    H.ok(template, "there should be a Kotlin data class template")
    local ok, path = T.create(template, dir, "Customer", { open = false })
    H.ok(ok, tostring(path))
    H.matches("^package io%.gulay%.svc", H.read(path))
    H.matches("data class Customer%(", H.read(path))
  end)
end)

H.describe("Ruby", function()
  local ruby = registry.language("ruby")

  H.it("is detected by a Gemfile", function()
    local dir = H.tmpdir("rb-detect")
    H.write(dir .. "/Gemfile", 'source "https://rubygems.org"')
    H.eq("ruby", (registry.kind_of(dir)))
  end)

  H.it("is also detected by .ruby-version", function()
    local dir = H.tmpdir("rb-version")
    H.write(dir .. "/.ruby-version", "3.3.0")
    H.eq("ruby", (registry.kind_of(dir)))
  end)

  H.it("adds gems with bundle add", function()
    local deps = registry.deps_for("ruby")
    H.eq({ "bundle", "add", "sinatra" }, deps.command("sinatra"))
    H.eq({ "bundle", "add", "--group", "development,test", "rspec" },
      deps.command("rspec", { dev = true }))
  end)

  H.it("offers the tasks a Ruby developer expects", function()
    local names = vim.tbl_map(function(t) return t.name end, ruby.tasks)
    for _, want in ipairs({ "bundle: install", "rspec", "rake", "rubocop" }) do
      H.ok(vim.tbl_contains(names, want), want .. " should be a task")
    end
  end)

  H.it("installs a language server and rubocop", function()
    for _, tool in ipairs({ "ruby-lsp", "rubocop" }) do
      H.ok(vim.tbl_contains(ruby.tools, tool), tool .. " should be installed")
    end
  end)

  H.it("scaffolds a bundler project with specs", function()
    if vim.fn.executable("ruby") == 0 then
      H.skip("ruby is not on PATH")
    end
    local project = require("kebab.project")
    local dest = H.tmpdir("rb-new") .. "/my_gem"
    local result
    H.capture_notify(function()
      project.create({ type = "ruby", name = "my_gem", dest = dest, open = false },
        function(ok, err) result = { ok = ok, err = err } end)
      H.wait(60000, function() return result ~= nil end, "ruby project creation")
    end)
    H.ok(result.ok, tostring(result.err))
    H.matches("rubygems%.org", H.read(dest .. "/Gemfile"))
    H.matches("module MyGem", H.read(dest .. "/lib/my_gem.rb"))
    H.matches("RSpec%.describe MyGem", H.read(dest .. "/spec/my_gem_spec.rb"))
    H.ok(H.exists(dest .. "/.rspec"))
    H.ok(H.exists(dest .. "/.git"))
  end)

  H.it("turns a snake_case file name into a CamelCase class", function()
    local T = require("kebab.templates")
    local template
    for _, t in ipairs(registry.templates()) do
      if t.name == "Ruby class" then template = t end
    end
    H.ok(template)
    local dir = H.tmpdir("rb-tmpl")
    local ok, path = T.create(template, dir, "order_processor", { open = false })
    H.ok(ok, tostring(path))
    H.matches("order_processor%.rb$", path, "the file stays snake_case")
    H.matches("class OrderProcessor", H.read(path), "the class is CamelCase")
  end)

  H.it("names an RSpec file _spec and describes the subject", function()
    local T = require("kebab.templates")
    local template
    for _, t in ipairs(registry.templates()) do
      if t.name == "RSpec spec" then template = t end
    end
    H.eq("widget_spec", template.default_name("widget"))
    H.eq("widget_spec", template.default_name("widget_spec"))
    local dir = H.tmpdir("rb-spec")
    local _, path = T.create(template, dir, "order_processor_spec", { open = false })
    H.matches("RSpec%.describe OrderProcessor do", H.read(path))
  end)
end)

H.describe("JavaScript as well as TypeScript", function()
  H.it("scaffolds a plain JavaScript node project", function()
    if vim.fn.executable("npm") == 0 then
      H.skip("npm is not on PATH, and `npm init` is what makes the project")
    end
    local project = require("kebab.project")
    local dest = H.tmpdir("js-new") .. "/jsthing"
    local result
    H.capture_notify(function()
      project.create({
        type = "node", name = "jsthing", dest = dest, open = false,
        answers = { language = "javascript" },
      }, function(ok, err) result = { ok = ok, err = err } end)
      H.wait(120000, function() return result ~= nil end, "node/js project creation")
    end)
    H.ok(result.ok, tostring(result.err))
    H.ok(H.exists(dest .. "/src/index.js"), "should write src/index.js")
    H.falsy(H.exists(dest .. "/src/index.ts"), "should not write TypeScript")
    H.falsy(H.exists(dest .. "/tsconfig.json"), "a JavaScript project needs no tsconfig")
    H.ok(H.exists(dest .. "/package.json"), "npm init should have run")
    H.ok(H.exists(dest .. "/.git"))
  end)

  H.it("still scaffolds TypeScript, with a tsconfig", function()
    if vim.fn.executable("npm") == 0 then
      H.skip("npm is not on PATH, and `npm init` is what makes the project")
    end
    local project = require("kebab.project")
    local dest = H.tmpdir("ts-new") .. "/tsthing"
    local result
    H.capture_notify(function()
      project.create({
        type = "node", name = "tsthing", dest = dest, open = false,
        answers = { language = "typescript" },
      }, function(ok, err) result = { ok = ok, err = err } end)
      H.wait(240000, function() return result ~= nil end, "node/ts project creation")
    end)
    H.ok(result.ok, tostring(result.err))
    H.ok(H.exists(dest .. "/src/index.ts"), "should write src/index.ts")
    H.matches('"strict": true', H.read(dest .. "/tsconfig.json"))
    H.ok(H.exists(dest .. "/package.json"))
  end)

  H.it("serves .js and .jsx as well as .ts", function()
    local js = registry.language("javascript")
    for _, ft in ipairs({ "javascript", "javascriptreact", "typescript", "typescriptreact" }) do
      H.ok(vim.tbl_contains(js.filetypes, ft), ft .. " should be covered")
    end
  end)

  H.it("installs eslint, which plain JavaScript relies on for linting", function()
    local js = registry.language("javascript")
    H.ok(vim.tbl_contains(js.tools, "eslint-lsp"), "eslint-lsp should be installed")
    H.ok(vim.tbl_contains(js.extras, "lazyvim.plugins.extras.linting.eslint"))
  end)

  H.it("offers JavaScript Vite templates, not only TypeScript ones", function()
    local vite = require("kebab.project").type_by_key("vite")
    local templates
    for _, p in ipairs(vite.prompts or {}) do
      if p.name == "template" then templates = p.choices end
    end
    local js_only = vim.tbl_filter(function(t) return not t:match("%-ts$") end, templates)
    H.ok(#js_only >= 4, "expected several JavaScript templates, got " .. vim.inspect(js_only))
    for _, want in ipairs({ "react", "svelte", "vue", "vanilla" }) do
      H.ok(vim.tbl_contains(templates, want), want .. " (JavaScript) should be offered")
    end
  end)
end)

-- Each of these produced a file that the real toolchain rejects, which is a
-- class of bug the suite could not see while it only checked that a template
-- rendered *something*.
H.describe("generated files the toolchain has to accept", function()
  local reg = require("kebab.registry")
  local S = require("kebab.scaffold")

  local function project_file(file, kind)
    for _, pf in ipairs(reg.collect("project_files")) do
      if pf.file == file and vim.tbl_contains(pf.kinds or {}, kind) then
        return pf
      end
    end
  end

  H.it("puts a .gitignore negation after the pattern it negates", function()
    -- git applies the LAST matching pattern, so `!wrapper.jar` before `*.jar`
    -- leaves the wrapper ignored and ./mvnw fails on a fresh clone.
    for _, case in ipairs({
      { kind = "maven", keep = "!.mvn/wrapper/maven-wrapper.jar" },
      { kind = "gradle", keep = "!gradle/wrapper/gradle-wrapper.jar" },
    }) do
      local pf = project_file(".gitignore", case.kind)
      H.ok(pf, case.kind .. " should generate a .gitignore")
      local lines = type(pf.lines) == "function" and pf.lines({ kind = case.kind }) or pf.lines
      local jar_at, keep_at
      for i, l in ipairs(lines) do
        if l == "*.jar" then
          jar_at = i
        end
        if l == case.keep then
          keep_at = i
        end
      end
      if keep_at then
        H.ok(jar_at, "*.jar should be there too for " .. case.kind)
        H.ok(keep_at > jar_at, ("%s: %s (line %d) must come after *.jar (line %d)"):format(
          case.kind, case.keep, keep_at, jar_at
        ))
      end
    end
  end)

  H.it("names the Rust container binary after the crate, not the directory", function()
    local pf = project_file("Dockerfile", "rust")
    H.ok(pf, "rust should generate a Dockerfile")
    local lines = pf.render({ project = "my-crate", kind = "rust" })
    local copy
    for _, l in ipairs(lines) do
      if l:find("target/release") then
        copy = l
      end
    end
    H.ok(copy, "there should be a COPY of the release binary")
    -- the scaffold runs `cargo new --name <snake>`, so the artifact is snake
    H.matches("release/my_crate%s", copy, "cargo builds target/release/my_crate: " .. copy)
  end)

  H.it("writes a Go package clause that is an identifier", function()
    local dir = H.tmpdir("go-pkg")
    vim.fn.mkdir(dir .. "/my-tool/store", "p")
    H.write(dir .. "/my-tool/go.mod", "module example.com/my-tool\n\ngo 1.21")
    H.eq("main", S.go_package(dir .. "/my-tool"), "a module root is package main")
    H.eq("store", S.go_package(dir .. "/my-tool/store"))
    vim.fn.mkdir(dir .. "/2fast", "p")
    H.eq("pkg_2fast", S.go_package(dir .. "/2fast"), "an identifier cannot start with a digit")
    vim.fn.mkdir(dir .. "/my-tool-x", "p")
    H.eq("my_tool_x", S.go_package(dir .. "/my-tool-x"), "a hyphen is a syntax error in Go")
  end)

  H.it("gives the Java scratch a file a public class can live in", function()
    local saved = vim.g.kebab_scratch_dir
    vim.g.kebab_scratch_dir = H.tmpdir("java-scratch")
    local ok, path = require("kebab.scratch").open("java", { open = false })
    vim.g.kebab_scratch_dir = saved
    H.ok(ok, tostring(path))
    local stem = vim.fn.fnamemodify(path, ":t:r")
    H.matches("^Scratch%d+$", stem, "the file stem has to be a Java identifier: " .. stem)
    local text = H.read(path)
    H.matches("public class " .. stem .. "%s", text, "javac wants the class named after the file:\n" .. text)
  end)

  H.it("adds a Python dependency the way the project is actually laid out", function()
    local deps = reg.deps_for("python")
    H.ok(deps, "python should declare a deps handler")
    local reqs = H.tmpdir("py-reqs")
    H.write(reqs .. "/requirements.txt", "pandas")
    local proj = H.tmpdir("py-proj")
    H.write(proj .. "/pyproject.toml", "[project]")
    -- `uv add` exits 2 without a pyproject.toml, which is the normal shape for
    -- a requirements.txt project
    local cmd = deps.command("pandas", { dir = reqs })
    H.falsy(cmd[1] == "uv", "a requirements.txt-only project cannot use uv: " .. table.concat(cmd, " "))
    H.matches("pip", table.concat(cmd, " "))
    if vim.fn.executable("uv") == 1 then
      H.eq({ "uv", "add", "pandas" }, deps.command("pandas", { dir = proj }))
    end
  end)
end)

H.describe("the SvelteKit route template", function()
  local T = require("kebab.templates")

  local function template(name)
    for _, t in ipairs(T.available({})) do
      if t.name == name then
        return t
      end
    end
  end

  -- SvelteKit routes a file only when its name starts with "+", so the answer
  -- names a directory; `about.svelte` is dead content.
  H.it("turns a route name into <route>/+page.svelte", function()
    local tpl = template("SvelteKit +page.svelte")
    H.ok(tpl, "the template should be registered")
    local dir = H.tmpdir("svelte-routes")
    local ok, path = T.create(tpl, dir, "about", { open = false })
    H.ok(ok, tostring(path))
    H.eq(dir .. "/about/+page.svelte", path)
  end)

  H.it("accepts the blank answer its own prompt invites", function()
    local tpl = template("SvelteKit +page.svelte")
    local dir = H.tmpdir("svelte-here")
    local ok, path = T.create(tpl, dir, "", { open = false })
    H.ok(ok, tostring(path))
    H.eq(dir .. "/+page.svelte", path)
  end)

  H.it("does not double the suffix when the answer already has it", function()
    local tpl = template("SvelteKit +page.svelte")
    local dir = H.tmpdir("svelte-full")
    local ok, path = T.create(tpl, dir, "blog/+page.svelte", { open = false })
    H.ok(ok, tostring(path))
    H.eq(dir .. "/blog/+page.svelte", path)
  end)

  H.it("still requires a name for every other template", function()
    local tpl = template("Go file")
    H.ok(tpl)
    local ok, err = T.create(tpl, H.tmpdir("go-blank"), "", { open = false })
    H.falsy(ok)
    H.matches("name is required", err)
  end)
end)
