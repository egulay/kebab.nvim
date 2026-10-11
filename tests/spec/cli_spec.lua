-- The `kebab` command: name resolution, opening, and the reports.
local H = ...
local cli = require("kebab.cli")
local project = require("kebab.project")

local function with_roots(roots, fn)
  local saved = vim.g.kebab_project_roots
  vim.g.kebab_project_roots = roots
  local ok, err = pcall(fn)
  vim.g.kebab_project_roots = saved
  if not ok then error(err, 0) end
end

---A scratch root holding several projects.
local function sample_root(label)
  local root = H.tmpdir(label or "cli-root")
  for _, name in ipairs({ "alpha-api", "alpha-cli", "sample-app", "Website" }) do
    vim.fn.mkdir(root .. "/" .. name .. "/.git", "p")
  end
  H.write(root .. "/alpha-api/pom.xml", "<project/>")
  H.write(root .. "/sample-app/pubspec.yaml", "name: sample")
  return root
end

---Run fn with the cwd restored afterwards; cli.open changes it.
local function keeping_cwd(fn)
  local saved = vim.fn.getcwd()
  local ok, err = pcall(fn)
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved))
  if not ok then error(err, 0) end
end

H.describe("kebab resolve", function()
  H.it("matches a name exactly", function()
    with_roots({ sample_root() }, function()
      local m = cli.resolve("alpha-cli")
      H.eq(1, #m)
      H.eq("alpha-cli", m[1].name)
    end)
  end)

  H.it("ignores case", function()
    with_roots({ sample_root() }, function()
      H.eq("Website", cli.resolve("website")[1].name)
    end)
  end)

  H.it("prefers an exact match over a longer name containing it", function()
    local root = H.tmpdir("prefix")
    vim.fn.mkdir(root .. "/api/.git", "p")
    vim.fn.mkdir(root .. "/api-gateway/.git", "p")
    with_roots({ root }, function()
      local m = cli.resolve("api")
      H.eq(1, #m, "an exact match should not be diluted by partial ones")
      H.eq("api", m[1].name)
    end)
  end)

  H.it("falls back to every partial match", function()
    with_roots({ sample_root() }, function()
      local names = vim.tbl_map(function(p) return p.name end, cli.resolve("alpha"))
      table.sort(names)
      H.eq({ "alpha-api", "alpha-cli" }, names)
    end)
  end)

  H.it("returns nothing when there is no match", function()
    with_roots({ sample_root() }, function()
      H.eq({}, cli.resolve("nothing-like-this"))
    end)
  end)
end)

H.describe("kebab open", function()
  H.it("opens a directory given as a path", function()
    local root = sample_root()
    keeping_cwd(function()
      H.capture_notify(function()
        cli.open(root .. "/alpha-cli")
        H.drain(100)
      end)
      H.eq(vim.fn.resolve(root .. "/alpha-cli"), vim.fn.resolve(vim.fn.getcwd()))
    end)
  end)

  H.it("opens a file's directory and then the file", function()
    local root = sample_root()
    local file = root .. "/alpha-cli/main.go"
    H.write(file, "package main")
    keeping_cwd(function()
      H.capture_notify(function()
        cli.open(file)
        H.drain(100)
      end)
      H.eq(vim.fn.resolve(root .. "/alpha-cli"), vim.fn.resolve(vim.fn.getcwd()))
      H.matches("main%.go$", vim.api.nvim_buf_get_name(0))
      vim.cmd("bwipeout!")
    end)
  end)

  H.it("prefers a real path over a project of the same name", function()
    -- `kebab open ./alpha-cli` must open what the user can see, not some other
    -- project that happens to share the name.
    local root = sample_root()
    local decoy = H.tmpdir("decoy")
    vim.fn.mkdir(decoy .. "/alpha-cli/.git", "p")
    keeping_cwd(function()
      with_roots({ root }, function()
        H.capture_notify(function()
          cli.open(decoy .. "/alpha-cli")
          H.drain(100)
        end)
        H.eq(vim.fn.resolve(decoy .. "/alpha-cli"), vim.fn.resolve(vim.fn.getcwd()))
      end)
    end)
  end)

  H.it("opens the single project matching a name", function()
    local root = sample_root()
    keeping_cwd(function()
      with_roots({ root }, function()
        H.capture_notify(function()
          cli.open("sample-app")
          H.drain(100)
        end)
        H.eq(vim.fn.resolve(root .. "/sample-app"), vim.fn.resolve(vim.fn.getcwd()))
      end)
    end)
  end)

  H.it("offers a choice when the name is ambiguous", function()
    local root = sample_root()
    keeping_cwd(function()
      with_roots({ root }, function()
        local ui = H.with_ui({ "alpha-cli" }, function()
          H.capture_notify(function()
            cli.open("alpha")
            H.drain(100)
          end)
        end)
        H.eq(1, ui.consumed(), "it should have asked which one")
        H.matches("2 projects match", ui.log[1].prompt)
        H.eq(vim.fn.resolve(root .. "/alpha-cli"), vim.fn.resolve(vim.fn.getcwd()))
      end)
    end)
  end)

  H.it("warns and falls back to the picker when nothing matches", function()
    local root = sample_root()
    keeping_cwd(function()
      with_roots({ root }, function()
        local notes
        local ui = H.with_ui({ H.CANCEL }, function()
          notes = H.capture_notify(function() cli.open("no-such-project") end)
        end)
        H.ok(H.notified(notes, "No project matching"), "should say nothing matched")
        H.eq(1, ui.consumed(), "then offer the full picker")
        H.matches("Open Project", ui.log[1].prompt)
      end)
    end)
  end)

  H.it("goes straight to the picker when given nothing", function()
    keeping_cwd(function()
      with_roots({ sample_root() }, function()
        local ui = H.with_ui({ H.CANCEL }, function()
          H.capture_notify(function() cli.open(nil) end)
        end)
        H.eq(1, ui.consumed())
        H.matches("Open Project", ui.log[1].prompt)
      end)
    end)
  end)
end)

H.describe("kebab new", function()
  H.it("creates directly when given a type and a name", function()
    local dest = H.tmpdir("cli-new") .. "/made-by-cli"
    H.capture_notify(function()
      cli.new({ type = "empty", name = "made-by-cli", dest = dest, open = false })
      H.wait(15000, function() return H.exists(dest .. "/.git") end, "the project to be created")
    end)
    H.matches("# made%-by%-cli", H.read(dest .. "/README.md"))
  end)

  H.it("falls back to the wizard when the type is missing", function()
    local ui = H.with_ui({ H.CANCEL }, function()
      H.capture_notify(function() cli.new({ name = "no-type-given" }) end)
    end)
    H.eq(1, ui.consumed(), "the wizard should have asked for a type")
    H.matches("Project type", ui.log[1].prompt)
  end)

  H.it("falls back to the wizard when nothing is given", function()
    local ui = H.with_ui({ H.CANCEL }, function()
      H.capture_notify(function() cli.new({}) end)
    end)
    H.eq(1, ui.consumed())
  end)
end)

H.describe("kebab reports", function()
  H.it("lists every project with its kind and path", function()
    local root = sample_root()
    with_roots({ root }, function()
      local lines = cli.list_lines()
      H.eq(4, #lines)
      local joined = table.concat(lines, "\n")
      H.matches("alpha%-api%s+maven", joined)
      H.matches("sample%-app%s+flutter", joined)
      H.matches(vim.pesc(root), joined, "the full path should be shown")
    end)
  end)

  H.it("says so plainly when there are no projects", function()
    with_roots({ H.tmpdir("barren") }, function()
      local lines = cli.list_lines()
      H.eq(1, #lines)
      H.matches("No projects found", lines[1])
    end)
  end)

  H.it("names a root it had to skip", function()
    -- `kebab list` printing nothing for a root the user can see on disk is
    -- the terminal half of the silent skip.
    local root = H.tmpdir("cli-locked")
    vim.fn.mkdir(root .. "/good/.git", "p")
    vim.fn.mkdir(root .. "/locked/sub", "p")
    vim.fn.system({ "chmod", "000", root .. "/locked" })
    local lines
    with_roots({ root }, function()
      lines = cli.list_lines()
    end)
    vim.fn.system({ "chmod", "755", root .. "/locked" })
    local joined = table.concat(lines, "\n")
    H.matches("good", joined)
    H.matches("skipped.*locked.*EACCES", joined)
  end)

  H.it("lists the project types with their key and label", function()
    local lines = cli.type_lines()
    H.eq(#project.project_types(), #lines)
    local joined = table.concat(lines, "\n")
    for _, key in ipairs(project.type_keys()) do
      H.matches(vim.pesc(key), joined)
    end
    H.matches("needs network", joined, "network-dependent types should say so")
  end)

  H.it("flags a type whose tools are not installed", function()
    local registry = require("kebab.registry")
    registry.register({
      key = "faketools",
      label = "Fake",
      markers = {},
      project_types = { { key = "fake", label = "Fake", requires = { "definitely-not-a-real-binary" } } },
    })
    local lines = cli.type_lines()
    registry.unregister("faketools")
    H.matches("MISSING: definitely%-not%-a%-real%-binary", table.concat(lines, "\n"))
  end)
end)

H.describe("kebab doctor", function()
  local checks = cli.doctor()

  local function check(name)
    for _, c in ipairs(checks) do
      if c.name == name then return c end
    end
    error("no doctor check named " .. name, 2)
  end

  local function in_section(section)
    return vim.tbl_filter(function(c) return c.section == section end, checks)
  end

  for _, name in ipairs({
    "Neovim >= 0.11",
    "kebab layer on runtimepath",
    "lazy.nvim loaded",
    "LazyVim loaded",
    "cheatsheet findable",
    ":IdeOpenProject",
    ":IdeNewProject",
    ":IdeInitHere",
    ":IdeCheatsheet",
  }) do
    H.it(name .. " passes", function()
      H.eq(true, check(name).ok, name .. " detail: " .. check(name).detail)
    end)
  end

  H.it("groups by who owns the version", function()
    -- The split the whole layer is built on: the editor owns its own tooling,
    -- the project owns its toolchain versions.
    for _, section in ipairs({ "Required", "Language toolchains", "Optional", "Projects" }) do
      H.ok(#in_section(section) > 0, section .. " should have checks")
    end
    for _, c in ipairs(checks) do
      H.ok(type(c.section) == "string" and c.section ~= "", c.name .. " needs a section")
    end
  end)

  H.it("only lets a required check fail the report", function()
    -- A missing toolchain costs a feature; it is not a broken install.
    for _, c in ipairs(checks) do
      if c.section ~= "Required" then
        H.eq(nil, c.ok, c.name .. " is not required, so it must not carry a pass/fail")
      end
    end
  end)

  H.it("reports git and curl as required, with why", function()
    for _, exe in ipairs({ "git", "curl" }) do
      local c = check("tool: " .. exe)
      H.eq("Required", c.section)
      H.eq(true, c.ok, exe .. " should be present on this machine")
      H.ok(c.why and c.why ~= "", exe .. " should say what it is needed for")
    end
  end)

  H.it("reports a tool for every requirement a scaffold declares", function()
    local reported = {}
    for _, c in ipairs(checks) do
      local exe = c.name:match("^tool: (.+)$")
      if exe then reported[exe] = true end
    end
    for _, t in ipairs(project.project_types()) do
      for _, exe in ipairs(t.requires or {}) do
        H.ok(reported[exe], ("%s needs %s, which the doctor should report"):format(t.key, exe))
      end
    end
    H.ok(reported["go"], "go should be reported now that there is a Go scaffold")
    H.ok(reported["cargo"], "cargo too")
    H.ok(reported["ruby"], "and ruby")
  end)

  H.it("says what each toolchain unlocks", function()
    for _, c in ipairs(in_section("Language toolchains")) do
      H.ok(c.enables and c.enables ~= "",
        c.name .. " should say what it enables, so a missing one explains itself")
    end
  end)

  H.it("knows Mason installs through the toolchains", function()
    -- 31 of the 55 packages are npm/golang/gem/pypi, so a missing toolchain
    -- costs language servers as well as scaffolds. This is the part people do
    -- not expect, so the report has to say it.
    local uses = cli.toolchain_uses()
    local mentions = 0
    for _, texts in pairs(uses) do
      for _, text in ipairs(texts) do
        if text:match("Mason package") then
          mentions = mentions + 1
        end
      end
    end
    H.ok(mentions >= 3, "expected several toolchains to mention Mason packages, got " .. mentions)
  end)

  H.it("does not repeat a tool across sections", function()
    local seen = {}
    for _, c in ipairs(checks) do
      local exe = c.name:match("^tool: (.+)$")
      if exe then
        H.falsy(seen[exe], ("%s is reported twice (%s and %s)"):format(exe, tostring(seen[exe]), c.section))
        seen[exe] = c.section
      end
    end
  end)

  H.it("marks every optional tool with what is lost without it", function()
    for _, c in ipairs(in_section("Optional")) do
      H.ok(c.without and c.without ~= "", c.name .. " should say what goes missing")
    end
  end)

  H.it("names a JDK as what the SQL editor needs", function()
    local c = check("tool: javac")
    H.eq("Optional", c.section)
    H.matches("JDBC", c.why)
    H.matches("database", c.without)
  end)

  H.it("knows the file watcher shells out to inotifywait", function()
    -- vim._watch.inotify runs the binary; :IdeFollow cannot start without it.
    local c = check("tool: inotifywait")
    H.matches("IdeFollow", c.why .. " " .. c.without)
  end)
end)

H.describe("doctor on the project roots", function()
  local function check(checks, name)
    for _, c in ipairs(checks) do
      if c.name == name then return c end
    end
    error("no doctor check named " .. name, 2)
  end

  H.it("reports the roots as readable when they are", function()
    local root = H.tmpdir("doctor-roots")
    vim.fn.mkdir(root .. "/thing/.git", "p")
    local c
    with_roots({ root }, function()
      c = check(cli.doctor(), "project roots readable")
    end)
    H.eq("all", c.detail)
    H.eq(true, c.present)
  end)

  H.it("reports one that is not", function()
    local root = H.tmpdir("doctor-locked")
    vim.fn.mkdir(root .. "/locked/sub", "p")
    vim.fn.system({ "chmod", "000", root .. "/locked" })
    local c
    with_roots({ root }, function()
      c = check(cli.doctor(), "project roots readable")
    end)
    vim.fn.system({ "chmod", "755", root .. "/locked" })
    H.eq(false, c.present, "an unreadable directory should not pass")
    H.matches("EACCES", c.detail)
    H.ok(c.why ~= nil, "the report should say what it costs")
  end)
end)

H.describe("doctor install hints", function()
  H.it("detects this machine's version manager", function()
    local manager = cli.package_manager()
    H.ok(manager == nil or manager == "mise" or manager == "asdf",
      "got " .. tostring(manager))
  end)

  H.it("suggests a version manager for a language toolchain", function()
    if cli.package_manager() ~= "mise" then
      H.skip("this machine does not use mise")
    end
    H.eq("mise use --global go@latest", cli.install_hint("go"))
    H.eq("mise use --global rust@latest", cli.install_hint("cargo"))
    H.eq("mise use --global java@latest", cli.install_hint("javac"))
  end)

  H.it("suggests the system package manager for a system tool", function()
    -- A version manager has no business installing git or jq.
    if cli.system_package_manager() ~= "pacman" then
      H.skip("this machine does not use pacman")
    end
    H.eq("sudo pacman -S git", cli.install_hint("git"))
    H.eq("sudo pacman -S inotify-tools", cli.install_hint("inotifywait"))
  end)

  H.it("suggests a gem install for bundler, which is not a toolchain", function()
    -- Not an exact string: when Gem.user_dir/bin is off PATH -- the default on
    -- Arch, and the trap that cost a round trip -- the hint says so too.
    local hint = cli.install_hint("bundle")
    H.matches("gem install", hint)
    H.matches("bundler", hint)
    H.falsy(hint:match("mise"), "bundler is a gem, not a managed toolchain")
  end)

  H.it("warns when the gem executable directory is not on PATH", function()
    if vim.fn.executable("ruby") == 0 then
      H.skip("ruby is needed to ask where gems install")
    end
    local dir = vim.fn.systemlist({ "ruby", "-e", "require 'rubygems'; print Gem.user_dir" })[1]
    if type(dir) ~= "string" or dir == "" then
      H.skip("could not determine the user gem directory")
    end
    local on_path = (vim.env.PATH or ""):find(dir .. "/bin", 1, true) ~= nil
    local hint = cli.install_hint("bundle")
    if on_path then
      H.falsy(hint:match("add .* to PATH"), "nothing to warn about when it is on PATH")
    else
      H.matches("to PATH", hint, "installing it and not finding it is the confusing case")
    end
  end)

  H.it("says nothing rather than guessing for something unknown", function()
    H.eq(nil, cli.install_hint("some-tool-nobody-has"))
  end)
end)

H.describe("the doctor report", function()
  H.it("passes on this machine", function()
    local lines, ok = cli.doctor_lines()
    H.ok(ok, "nothing required should be missing:\n" .. table.concat(lines, "\n"))
    H.ok(#lines > #cli.doctor(),
      "the grouped report has headers and hints, so more lines than checks")
  end)

  H.it("starts with a section heading, not a check", function()
    local lines = cli.doctor_lines()
    H.eq("Required", lines[1])
  end)

  H.it("ends with a summary", function()
    local lines = cli.doctor_lines()
    H.matches("%d+ ok", lines[#lines - 1] .. " " .. lines[#lines])
  end)

  H.it("fails when something required is missing, and says what to run", function()
    -- The scriptable contract: `kebab doctor` must exit non-zero.
    local real = vim.fn.exepath
    vim.fn.exepath = function(exe)
      if exe == "git" then
        return ""
      end
      return real(exe)
    end
    local lines, ok = cli.doctor_lines()
    vim.fn.exepath = real

    H.falsy(ok, "a missing git must fail the report")
    local text = table.concat(lines, "\n")
    H.matches("FAIL git", text)
    H.matches("install:", text, "and it should say how to fix it")
    H.matches("1 of them required", text, "and count it as required")
  end)

  H.it("does not fail when only a toolchain is missing", function()
    local real = vim.fn.exepath
    vim.fn.exepath = function(exe)
      if exe == "go" then
        return ""
      end
      return real(exe)
    end
    local lines, ok = cli.doctor_lines()
    vim.fn.exepath = real

    H.ok(ok, "a missing toolchain costs a feature, it does not break the install")
    local text = table.concat(lines, "\n")
    H.matches("%-%-   go", text, "but it should be visible")
    H.matches("costs:", text, "with what it costs")
  end)

  H.it("shows a path shortened to ~, so the columns survive", function()
    local text = table.concat(cli.doctor_lines(), "\n")
    H.falsy(text:match("/home/" .. vim.fn.fnamemodify(vim.fn.expand("~"), ":t") .. "/Projects/kebab"),
      "a home-relative path should be abbreviated: " .. text:sub(1, 200))
  end)
end)

H.describe("the :IdeDoctor command", function()
  H.it("is registered", function()
    H.ok(vim.fn.exists(":IdeDoctor") >= 1)
  end)

  H.it("opens the report in a read-only buffer", function()
    cli.doctor_buffer()
    H.matches("kebab://doctor", vim.api.nvim_buf_get_name(0))
    H.falsy(vim.bo.modifiable, "a report is not for editing")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    H.matches("kebab%.nvim doctor", text)
    H.matches("Language toolchains", text)
    vim.cmd("bwipeout!")
  end)
end)

-- The existing tests gave false confidence on each of these: the file one used
-- a file sitting directly in the project directory, where the parent happens to
-- be the root, and the doctor one wiped its buffer before a second call could
-- collide.
H.describe("opening a file that is not at the top level", function()
  H.it("roots the project at the marker, not at the file's own directory", function()
    local root = H.tmpdir("nested")
    vim.fn.mkdir(root .. "/proj/src/main/java/com/foo", "p")
    H.write(root .. "/proj/pom.xml", "<project/>")
    H.write(root .. "/proj/src/main/java/com/foo/App.java", "class App {}")

    local saved = vim.fn.getcwd()
    cli.open(root .. "/proj/src/main/java/com/foo/App.java")
    local cwd = vim.fn.resolve(vim.fn.getcwd())
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    H.eq(
      vim.fn.resolve(root .. "/proj"),
      cwd,
      "rooting at com/foo scopes the tree and grep to one package, and hides ./mvnw"
    )
    H.matches("App%.java", vim.api.nvim_buf_get_name(0), "and it should still open the file")
    H.reset_editor()
  end)
end)

H.describe("the doctor report", function()
  H.it("does not call a project-local wrapper a missing toolchain", function()
    local dir = H.tmpdir("wrapper")
    H.write(dir .. "/pom.xml", "<project/>")
    H.write(dir .. "/mvnw", "#!/bin/sh\n")
    vim.fn.setfperm(dir .. "/mvnw", "rwxr-xr-x")
    H.write(dir .. "/gradlew", "#!/bin/sh\n")
    vim.fn.setfperm(dir .. "/gradlew", "rwxr-xr-x")

    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    local lines = cli.doctor_lines()
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    local text = table.concat(lines, "\n")
    -- ./mvnw resolves because it is in this directory, and plugins/run.lua
    -- re-resolves it at run time -- so "mvnw not installed", with no install
    -- hint, reported a problem that does not exist
    H.falsy(text:find("mvnw"), "a wrapper is not a toolchain:\n" .. text)
    H.falsy(text:find("gradlew"), "nor is gradlew")
  end)

  H.it("names every package manager whose hints it printed", function()
    local lines = cli.doctor_lines()
    local footer
    for _, l in ipairs(lines) do
      if l:find("Install suggestions use") then
        footer = l
      end
    end
    if not footer then
      H.skip("nothing is missing on this machine, so there is no footer")
    end
    -- a hint of `sudo pacman -S jq` under "suggestions use mise" sent the
    -- reader looking for a mise recipe that does not exist
    local text = table.concat(lines, "\n")
    for manager, pattern in pairs({ pacman = "sudo pacman", apt = "sudo apt", dnf = "sudo dnf" }) do
      if text:find(pattern, 1, true) then
        H.matches(manager, footer, "the footer should mention " .. manager .. ": " .. footer)
      end
    end
    if text:find("mise use", 1, true) then
      H.matches("mise", footer, "and mise: " .. footer)
    end
  end)

  H.it("can be opened twice without throwing", function()
    local ok1, err1 = pcall(cli.doctor_buffer)
    H.ok(ok1, tostring(err1))
    -- keep the first report on screen, as a user would
    vim.cmd("split")
    local ok2, err2 = pcall(cli.doctor_buffer)
    H.ok(ok2, "a second report must not throw E95: " .. tostring(err2))
    -- and whatever it lands in is a proper scratch buffer, not a bare one
    H.eq("nofile", vim.bo.buftype)
    H.falsy(vim.bo.modifiable, "a report should not be editable")
    H.falsy(vim.bo.swapfile)
    H.matches("kebab://doctor", vim.api.nvim_buf_get_name(0))
    H.reset_editor()
  end)
end)
