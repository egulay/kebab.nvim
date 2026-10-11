-- Gating a language task on the project's marker files.
--
-- overseer's `condition` understands filetype, dir and tags -- and nothing
-- else. A `condition = { callback = fn }` was accepted and then ignored, so
-- every marker-gated task was offered in every project: `./mvnw test` in a Go
-- repo, `cargo run` in a Spring one. This is tested without overseer on
-- purpose: the bug was invisible to anything that only checked that templates
-- had been registered.
local H = ...
local R = require("kebab.run")

local function project(label, marker)
  local dir = H.tmpdir("run-" .. label)
  if marker then
    vim.fn.mkdir(vim.fn.fnamemodify(dir .. "/" .. marker, ":h"), "p")
    H.write(dir .. "/" .. marker, "")
  end
  return dir
end

H.describe("kebab.run marker gating", function()
  H.it("normalises a marker to a list", function()
    H.eq({ "go.mod" }, R.markers_of({ marker = "go.mod" }))
    H.eq({ "a", "b" }, R.markers_of({ marker = { "a", "b" } }))
    H.eq(nil, R.markers_of({}))
  end)

  H.it("offers a task only where its marker is", function()
    local go = project("go", "go.mod")
    local maven = project("maven", "pom.xml")
    local task = { name = "go: test", marker = "go.mod" }
    H.ok(R.applies(task, go))
    H.falsy(R.applies(task, maven), "a Go task has no business in a Maven project")
  end)

  H.it("offers a task with no marker anywhere", function()
    H.ok(R.applies({ name = "anywhere" }, project("bare")))
  end)

  H.it("accepts any one of several markers", function()
    local gradle = project("gradle", "build.gradle.kts")
    local task = { name = "gradle: build", marker = { "build.gradle", "build.gradle.kts" } }
    H.ok(R.applies(task, gradle))
    H.falsy(R.applies(task, project("empty")))
  end)

  H.it("filters the real declared task list by project", function()
    local tasks = {}
    for _, t in ipairs(require("kebab.registry").tasks()) do
      if not t.filetypes and R.markers_of(t) then
        tasks[#tasks + 1] = t
      end
    end
    H.ok(#tasks > 10, "there should be plenty of marker-gated tasks, got " .. #tasks)

    local go = R.relevant(tasks, project("go2", "go.mod"))
    local maven = R.relevant(tasks, project("maven2", "pom.xml"))
    H.ok(#go > 0, "a Go project should get some")
    H.ok(#go < #tasks, "but not all of them -- that was the bug")
    H.ok(#maven > 0)

    local function names(list)
      local out = {}
      for _, t in ipairs(list) do
        out[#out + 1] = t.name
      end
      return table.concat(out, " ")
    end
    H.matches("go:", names(go))
    H.falsy(names(go):find("maven:"), "a Go project must not be offered Maven tasks: " .. names(go))
    H.falsy(names(go):find("cargo:"), "nor cargo ones: " .. names(go))
    H.matches("maven:", names(maven))
    H.falsy(names(maven):find("go:"), "and vice versa: " .. names(maven))
  end)

  H.it("hands overseer a generator, not an ignored callback", function()
    local tasks = {
      { name = "go: test", marker = "go.mod", cmd = { "go" }, args = { "test" } },
      { name = "maven: test", marker = "pom.xml", cmd = { "./mvnw" }, args = { "test" } },
    }
    local provider = R.marker_provider(tasks)
    H.eq("function", type(provider.generator), "a provider decides at search time")
    H.eq(nil, provider.condition, "no condition.callback, which overseer ignores")

    local got
    provider.generator({ dir = project("go3", "go.mod") }, function(list)
      got = list
    end)
    H.eq(1, #got, "only the Go task")
    H.eq("go: test", got[1].name)
    H.eq("function", type(got[1].builder))
    local built = got[1].builder()
    H.eq({ "go" }, built.cmd)
    H.eq({ "test" }, built.args)
  end)

  H.it("expands %:p at run time, not at registration", function()
    local tasks = { { name = "run file", marker = "go.mod", cmd = { "go" }, args = { "run", "%:p" } } }
    local got
    R.marker_provider(tasks).generator({ dir = project("go4", "go.mod") }, function(list)
      got = list
    end)
    H.eq(1, #got)
    local built = got[1].builder()
    H.falsy(vim.tbl_contains(built.args, "%:p"), "it should have been expanded: " .. vim.inspect(built.args))
  end)
end)
