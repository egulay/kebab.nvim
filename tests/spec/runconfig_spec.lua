-- Per-project run configurations: .kebab/run.json, committed with the project.
local H = ...
local RC = require("kebab.runconfig")

local function maven_project(label)
  local dir = H.tmpdir(label or "rc")
  H.write(dir .. "/pom.xml", "<project/>")
  return dir
end

local function write_json(dir, text)
  H.write(dir .. "/.kebab/run.json", text)
end

H.describe("locating the file", function()
  H.it("puts it at the project root", function()
    local dir = maven_project("rc-root")
    H.eq(dir .. "/.kebab/run.json", RC.file(dir))
  end)

  H.it("finds the root from a nested directory", function()
    local dir = maven_project("rc-nested")
    vim.fn.mkdir(dir .. "/src/main/java", "p")
    H.eq(dir, RC.root_of(dir .. "/src/main/java"))
    H.eq(dir .. "/.kebab/run.json", RC.file(dir .. "/src/main/java"))
  end)

  H.it("falls back to the directory itself outside a project", function()
    local dir = H.tmpdir("rc-noproject")
    H.eq(dir, RC.root_of(dir))
  end)
end)

H.describe("loading configurations", function()
  H.it("is empty when the file does not exist", function()
    local configs, err = RC.load(maven_project("rc-absent"))
    H.eq({}, configs)
    H.eq(nil, err)
  end)

  H.it("is empty for an empty file", function()
    local dir = maven_project("rc-empty")
    write_json(dir, "")
    local configs, err = RC.load(dir)
    H.eq({}, configs)
    H.eq(nil, err)
  end)

  H.it("reads a configuration with args, env and cwd", function()
    local dir = maven_project("rc-full")
    write_json(dir, [[
{
  "configurations": [
    {
      "name": "api (local)",
      "cmd": ["./mvnw"],
      "args": ["spring-boot:run", "-Dspring-boot.run.profiles=local"],
      "env": { "LOG_LEVEL": "debug" },
      "cwd": "."
    }
  ]
}
]])
    local configs, err = RC.load(dir)
    H.eq(nil, err)
    H.eq(1, #configs)
    H.eq("api (local)", configs[1].name)
    H.eq({ "./mvnw" }, configs[1].cmd)
    H.eq({ "spring-boot:run", "-Dspring-boot.run.profiles=local" }, configs[1].args)
    H.eq({ LOG_LEVEL = "debug" }, configs[1].env)
  end)

  H.it("accepts a bare list, which is the obvious thing to hand-write", function()
    local dir = maven_project("rc-bare")
    write_json(dir, '[{ "name": "x", "cmd": "echo" }]')
    local configs, err = RC.load(dir)
    H.eq(nil, err)
    H.eq(1, #configs)
    H.eq("x", configs[1].name)
  end)

  H.it("accepts cmd as a plain string", function()
    local dir = maven_project("rc-strcmd")
    write_json(dir, '{ "configurations": [{ "name": "x", "cmd": "echo" }] }')
    local configs, err = RC.load(dir)
    H.eq(nil, err)
    H.eq("echo", configs[1].cmd)
  end)

  H.it("reports invalid JSON instead of ignoring the file", function()
    -- A committed file with a typo in it should say so; dropping it silently
    -- would mean a colleague's configuration vanishing without explanation.
    local dir = maven_project("rc-badjson")
    write_json(dir, '{ "configurations": [ }')
    local configs, err = RC.load(dir)
    H.eq({}, configs)
    H.matches("not valid JSON", err)
  end)

  H.it("reports a missing configurations list", function()
    local dir = maven_project("rc-nolist")
    write_json(dir, '{ "something": 1 }')
    local _, err = RC.load(dir)
    H.matches('should have a "configurations" list', err)
  end)

  H.it("reports a configuration with no name", function()
    local dir = maven_project("rc-noname")
    write_json(dir, '{ "configurations": [{ "cmd": "echo" }] }')
    local _, err = RC.load(dir)
    H.matches("needs a name", err)
  end)

  H.it("reports a configuration with no cmd", function()
    local dir = maven_project("rc-nocmd")
    write_json(dir, '{ "configurations": [{ "name": "x" }] }')
    local _, err = RC.load(dir)
    H.matches("needs a cmd", err)
  end)

  H.it("reports the offending configuration by name", function()
    local dir = maven_project("rc-named-error")
    write_json(dir, '{ "configurations": [{ "name": "ok", "cmd": "echo" }, { "name": "broken", "args": [] }] }')
    local _, err = RC.load(dir)
    H.matches('"broken"', err, "the error should name which one is wrong")
  end)
end)

H.describe("validating a configuration", function()
  H.it("accepts the shapes it documents", function()
    H.ok(RC.validate({ name = "a", cmd = "echo" }))
    H.ok(RC.validate({ name = "a", cmd = { "echo", "hi" } }))
    H.ok(RC.validate({ name = "a", cmd = "echo", args = { "x" } }))
    H.ok(RC.validate({ name = "a", cmd = "echo", env = { A = "b" } }))
    H.ok(RC.validate({ name = "a", cmd = "echo", cwd = "sub" }))
  end)

  H.it("rejects the shapes it cannot run", function()
    local cases = {
      { nil, "is not an object" },
      { {}, "needs a name" },
      { { name = "" }, "needs a name" },
      { { name = "a" }, "needs a cmd" },
      { { name = "a", cmd = {} }, "empty cmd" },
      { { name = "a", cmd = { 1 } }, "non%-string in cmd" },
      { { name = "a", cmd = "e", args = "x" }, "args should be a list" },
      { { name = "a", cmd = "e", args = { 1 } }, "non%-string in args" },
      { { name = "a", cmd = "e", env = "x" }, "env should be an object" },
      { { name = "a", cmd = "e", env = { A = 1 } }, "strings to strings" },
      { { name = "a", cmd = "e", cwd = 1 }, "cwd should be a string" },
    }
    for _, case in ipairs(cases) do
      local ok, err = RC.validate(case[1])
      H.falsy(ok, "should have rejected " .. vim.inspect(case[1]))
      H.matches(case[2], err)
    end
  end)
end)

H.describe("saving configurations", function()
  H.it("round-trips", function()
    local dir = maven_project("rc-roundtrip")
    local written = {
      { name = "one", cmd = { "echo" }, args = { "a" }, env = { X = "y" } },
      { name = "two", cmd = "ls" },
    }
    H.ok(RC.save(dir, written))
    local read = RC.load(dir)
    H.eq(2, #read)
    H.eq("one", read[1].name)
    H.eq({ X = "y" }, read[1].env)
    H.eq("ls", read[2].cmd)
  end)

  H.it("writes something a person can read and edit", function()
    local dir = maven_project("rc-pretty")
    RC.save(dir, { { name = "one", cmd = { "echo" } } })
    local lines = vim.fn.readfile(RC.file(dir))
    H.ok(#lines > 1, "a committed file should not be one long line: " .. vim.inspect(lines))
  end)

  H.it("creates the .kebab directory", function()
    local dir = maven_project("rc-mkdir")
    H.ok(RC.save(dir, { { name = "x", cmd = "echo" } }))
    H.ok(H.exists(dir .. "/.kebab"))
  end)

  H.it("refuses to write something it could not load back", function()
    local dir = maven_project("rc-refuse")
    local ok, err = RC.save(dir, { { name = "x" } })
    H.falsy(ok)
    H.matches("needs a cmd", err)
    H.falsy(H.exists(RC.file(dir)), "nothing should have been written")
  end)
end)

H.describe("turning a configuration into a task", function()
  H.it("builds the command, args and env", function()
    local t = RC.to_template(
      { name = "api", cmd = { "./mvnw" }, args = { "test" }, env = { A = "b" } }, "/proj")
    H.eq("api", t.name)
    local built = t.builder()
    H.eq({ "./mvnw" }, built.cmd)
    H.eq({ "test" }, built.args)
    H.eq({ A = "b" }, built.env)
    H.eq("/proj", built.cwd)
  end)

  H.it("accepts a string cmd", function()
    local built = RC.to_template({ name = "a", cmd = "echo" }, "/proj").builder()
    H.eq({ "echo" }, built.cmd)
  end)

  H.it("resolves a relative cwd against the project root", function()
    local built = RC.to_template({ name = "a", cmd = "echo", cwd = "backend" }, "/proj").builder()
    H.eq("/proj/backend", built.cwd)
  end)

  H.it("keeps an absolute cwd", function()
    local built = RC.to_template({ name = "a", cmd = "echo", cwd = "/elsewhere" }, "/proj").builder()
    H.eq("/elsewhere", built.cwd)
  end)

  H.it("treats '.' and a missing cwd as the project root", function()
    H.eq("/proj", RC.to_template({ name = "a", cmd = "echo", cwd = "." }, "/proj").builder().cwd)
    H.eq("/proj", RC.to_template({ name = "a", cmd = "echo" }, "/proj").builder().cwd)
  end)

  H.it("ranks project configurations above the generic language tasks", function()
    local generic = 10 -- what languages/*.lua use
    H.ok(RC.to_template({ name = "a", cmd = "echo" }, "/p").priority < generic,
      "yours should come first in the task list")
  end)

  H.it("does not share mutable state between runs", function()
    local config = { name = "a", cmd = { "echo" }, args = { "x" } }
    local t = RC.to_template(config, "/p")
    local first = t.builder()
    table.insert(first.args, "mutated")
    local second = t.builder()
    H.eq({ "x" }, second.args, "a second run must not see the first run's edits")
  end)
end)

H.describe("the overseer provider", function()
  H.it("offers this project's configurations", function()
    local dir = maven_project("rc-provider")
    RC.save(dir, { { name = "mine", cmd = { "echo" }, args = { "hi" } } })
    local got
    RC.provider().generator({ dir = dir }, function(templates) got = templates end)
    H.ok(got, "the generator should have answered")
    H.eq(1, #got)
    H.eq("mine", got[1].name)
  end)

  H.it("offers nothing when there is no file", function()
    local got
    RC.provider().generator({ dir = maven_project("rc-provider-empty") }, function(t) got = t end)
    H.eq({}, got)
  end)

  H.it("offers nothing, and warns, when the file is broken", function()
    local dir = maven_project("rc-provider-broken")
    write_json(dir, "{ not json")
    local got
    local notes = H.capture_notify(function()
      RC.provider().generator({ dir = dir }, function(t) got = t end)
    end)
    H.eq({}, got, "a broken file must not break the task list")
    H.ok(H.notified(notes, "not valid JSON"), "but it should say so")
  end)

  H.it("is registered with overseer", function()
    require("lazy").load({ plugins = { "overseer.nvim" } })
    local overseer = require("overseer")
    local names = {}
    for _, t in ipairs(require("overseer.template").list_all and {} or {}) do
      names[#names + 1] = t.name
    end
    -- list_all is internal; assert the provider is constructible and named
    H.eq("kebab project run configurations", RC.provider().name)
    H.ok(type(overseer.register_template) == "function")
  end)
end)

H.describe("creating the file", function()
  H.it("suggests something runnable for the project in hand", function()
    H.eq({ "./mvnw" }, RC.example_for("maven").cmd)
    H.eq({ "go" }, RC.example_for("go").cmd)
    H.eq({ "cargo" }, RC.example_for("rust").cmd)
    H.eq({ "npm" }, RC.example_for("node").cmd)
    H.eq({ "flutter" }, RC.example_for("flutter").cmd)
  end)

  H.it("has a fallback for an unknown project kind", function()
    local example = RC.example_for(nil)
    H.ok(RC.validate(example), "even the fallback has to be valid")
    H.ok(RC.validate(RC.example_for("cobol")))
  end)

  H.it("every example is valid", function()
    for _, kind in ipairs({ "maven", "gradle", "go", "rust", "node", "python", "flutter" }) do
      local ok, err = RC.validate(RC.example_for(kind))
      H.ok(ok, kind .. ": " .. tostring(err))
    end
  end)

  H.it("writes an example when the file is missing, then opens it", function()
    local dir = maven_project("rc-edit")
    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    H.capture_notify(function() RC.edit() end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    H.ok(H.exists(RC.file(dir)))
    local configs, err = RC.load(dir)
    H.eq(nil, err, "the example it writes must load back")
    H.eq(1, #configs)
    H.matches("run%.json$", vim.api.nvim_buf_get_name(0))
    vim.cmd("bwipeout!")
  end)

  H.it("leaves an existing file alone", function()
    local dir = maven_project("rc-edit-existing")
    RC.save(dir, { { name = "mine", cmd = "echo" } })
    local before = H.read(RC.file(dir))
    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    H.capture_notify(function() RC.edit() end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    H.eq(before, H.read(RC.file(dir)))
    vim.cmd("bwipeout!")
  end)
end)

H.describe("adding a configuration interactively", function()
  H.it("appends to the file", function()
    local dir = maven_project("rc-add")
    RC.save(dir, { { name = "existing", cmd = "echo" } })
    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    H.with_ui({ "second", "mvn test -q" }, function()
      H.capture_notify(function() RC.add() end)
    end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    local configs = RC.load(dir)
    H.eq(2, #configs)
    H.eq("second", configs[2].name)
    H.eq({ "mvn" }, configs[2].cmd)
    H.eq({ "test", "-q" }, configs[2].args)
  end)

  H.it("does nothing when cancelled", function()
    local dir = maven_project("rc-add-cancel")
    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    H.with_ui({ H.CANCEL }, function()
      H.capture_notify(function() RC.add() end)
    end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    H.falsy(H.exists(RC.file(dir)))
  end)
end)

H.describe("running a configuration", function()
  H.it("says so when there are none", function()
    local dir = maven_project("rc-run-none")
    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    local notes = H.capture_notify(function() RC.run() end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    H.ok(H.notified(notes, "No run configurations"))
  end)

  H.it("reports a name that matches nothing", function()
    local dir = maven_project("rc-run-nomatch")
    RC.save(dir, { { name = "api", cmd = "echo" } })
    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    local notes = H.capture_notify(function() RC.run("nonsense") end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    H.ok(H.notified(notes, "No configuration matching"))
  end)

  H.it("reports a broken file rather than running nothing", function()
    local dir = maven_project("rc-run-broken")
    write_json(dir, "{{{")
    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    local notes = H.capture_notify(function() RC.run() end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    H.ok(H.notified(notes, "not valid JSON"))
  end)
end)

H.describe("the run configuration commands", function()
  H.it("are registered", function()
    for _, cmd in ipairs({ "IdeRunConfig", "IdeRunConfigEdit", "IdeRunConfigNew" }) do
      H.ok(vim.fn.exists(":" .. cmd) >= 1, ":" .. cmd .. " should be defined")
    end
  end)
end)

H.describe("run.json when jq is not installed", function()
  local R = require("kebab.runconfig")

  -- jq is optional (it only pretty-prints), but vim.fn.system raises E475 for
  -- a missing executable rather than setting v:shell_error -- so the fallback
  -- was unreachable and save() threw, losing what the user had just typed.
  H.it("still writes the file", function()
    local root = H.tmpdir("rc-nojq")
    local saved = vim.env.PATH
    vim.env.PATH = "/nonexistent"
    local ok, err = pcall(R.save, root, { { name = "api", cmd = { "./mvnw" }, args = { "spring-boot:run" } } })
    vim.env.PATH = saved
    H.ok(ok, "save should not throw: " .. tostring(err))
    local list, lerr = R.load(root)
    H.eq(1, #list, tostring(lerr))
    H.eq("api", list[1].name)
  end)

  H.it("reports a configurations object instead of reading it as empty", function()
    local root = H.tmpdir("rc-object")
    vim.fn.mkdir(root .. "/.kebab", "p")
    H.write(root .. "/.kebab/run.json", '{"configurations":{"name":"api","cmd":["echo"]}}')
    local list, err = R.load(root)
    H.eq(0, #list)
    H.matches("should be a list", err, "a single-configuration object is a natural slip")
  end)

  H.it("rejects a desc overseer would choke on", function()
    -- overseer drops the whole template definition for a non-string desc, with
    -- only a log line, so the configuration was runnable by name and invisible
    -- in the picker. JSON null decodes to vim.NIL, which is truthy.
    H.falsy(R.validate({ name = "a", cmd = { "x" }, desc = vim.NIL }))
    H.falsy(R.validate({ name = "a", cmd = { "x" }, desc = 5 }))
    H.ok(R.validate({ name = "a", cmd = { "x" }, desc = "fine" }))
    H.ok(R.validate({ name = "a", cmd = { "x" } }))
  end)
end)
