-- Project-level file generators: .gitignore for the language in hand, a
-- Dockerfile, a CI workflow, .editorconfig.
local H = ...
local PF = require("kebab.projectfiles")
local registry = require("kebab.registry")

---A scratch project of a given kind.
local function project(kind)
  local dir = H.tmpdir("pf-" .. kind)
  local marker = ({
    maven = { "pom.xml", "<project/>" },
    go = { "go.mod", "module example.com/x" },
    rust = { "Cargo.toml", '[package]\nname = "x"' },
    node = { "package.json", "{}" },
    python = { "pyproject.toml", "[project]" },
    flutter = { "pubspec.yaml", "name: x" },
  })[kind]
  H.write(dir .. "/" .. marker[1], marker[2])
  return dir
end

local function by_file(dir, file)
  for _, g in ipairs(PF.available(dir)) do
    if g.file == file then
      return g
    end
  end
  return nil
end

H.describe("what is offered where", function()
  H.it("offers a Maven project a Maven gitignore and Dockerfile", function()
    local dir = project("maven")
    local files = vim.tbl_map(function(g) return g.file end, PF.available(dir))
    H.ok(vim.tbl_contains(files, "Dockerfile"))
    H.ok(vim.tbl_contains(files, ".github/workflows/build.yml"))
    local names = vim.tbl_map(function(g) return g.name end, PF.available(dir))
    H.ok(vim.tbl_contains(names, ".gitignore (Java/Maven)"))
    H.falsy(vim.tbl_contains(names, ".gitignore (Go)"), "a Maven project is not a Go project")
  end)

  H.it("offers each language its own set", function()
    for kind, want in pairs({
      go = ".gitignore (Go)",
      rust = ".gitignore (Rust)",
      node = ".gitignore (Node)",
      python = ".gitignore (Python)",
      flutter = ".gitignore (Flutter)",
    }) do
      local names = vim.tbl_map(function(g) return g.name end, PF.available(project(kind)))
      H.ok(vim.tbl_contains(names, want), kind .. " should be offered " .. want)
    end
  end)

  H.it("always offers the language-agnostic ones", function()
    for _, kind in ipairs({ "maven", "go", "node" }) do
      local files = vim.tbl_map(function(g) return g.file end, PF.available(project(kind)))
      H.ok(vim.tbl_contains(files, ".editorconfig"), ".editorconfig should always be offered")
      H.ok(vim.tbl_contains(files, "README.md"))
    end
  end)

  H.it("offers only the agnostic ones outside a project", function()
    local names = vim.tbl_map(function(g) return g.name end, PF.available(H.tmpdir("pf-none")))
    H.ok(vim.tbl_contains(names, ".editorconfig"))
    H.falsy(vim.tbl_contains(names, "Dockerfile (Go, static binary)"))
  end)

  H.it("resolves the project root from a nested directory", function()
    local dir = project("go")
    vim.fn.mkdir(dir .. "/internal/deep", "p")
    H.eq(dir, PF.root_of(dir .. "/internal/deep"))
    local names = vim.tbl_map(function(g) return g.name end, PF.available(dir .. "/internal/deep"))
    H.ok(vim.tbl_contains(names, ".gitignore (Go)"), "it should still know it is a Go project")
  end)
end)

H.describe("generating a project file", function()
  H.it("writes it at the project root, not the current directory", function()
    local dir = project("go")
    vim.fn.mkdir(dir .. "/cmd/app", "p")
    local gen = by_file(dir, ".editorconfig")
    local ok, path = PF.create(gen, dir .. "/cmd/app", { open = false })
    H.ok(ok, tostring(path))
    H.eq(dir .. "/.editorconfig", path, "it belongs at the root")
  end)

  H.it("writes a Go Dockerfile that builds a static binary", function()
    local dir = project("go")
    local ok, path = PF.create(by_file(dir, "Dockerfile"), dir, { open = false })
    H.ok(ok, tostring(path))
    local text = H.read(path)
    H.matches("FROM golang", text)
    H.matches("CGO_ENABLED=0", text, "a scratch final image needs a static binary")
    H.matches("distroless", text)
  end)

  H.it("writes a Maven Dockerfile that uses the wrapper", function()
    local dir = project("maven")
    local _, path = PF.create(by_file(dir, "Dockerfile"), dir, { open = false })
    local text = H.read(path)
    H.matches("%./mvnw", text, "CI should match local builds")
    H.matches("eclipse%-temurin:21%-jre", text)
    H.matches("USER app", text, "it should not run as root")
  end)

  H.it("names the image after the project", function()
    local dir = project("go")
    local _, path = PF.create(by_file(dir, "Dockerfile"), dir, { open = false })
    H.matches(vim.pesc(vim.fn.fnamemodify(dir, ":t")), H.read(path))
  end)

  H.it("writes a CI workflow under .github/workflows, creating the directories", function()
    local dir = project("rust")
    local gen = by_file(dir, ".github/workflows/test.yml")
    local ok, path = PF.create(gen, dir, { open = false })
    H.ok(ok, tostring(path))
    H.eq(dir .. "/.github/workflows/test.yml", path)
    local text = H.read(path)
    H.matches("cargo clippy", text)
    H.matches("cargo test", text)
  end)

  H.it("writes an editorconfig that matches the indentation each language uses", function()
    local dir = project("maven")
    local _, path = PF.create(by_file(dir, ".editorconfig"), dir, { open = false })
    local text = H.read(path)
    H.matches("root = true", text)
    H.matches("%[%*%.{java,kt,gradle}%]", text)
    H.matches("%[%*%.go%]\nindent_style = tab", text, "Go is formatted with tabs")
  end)

  H.it("refuses to overwrite an existing file", function()
    local dir = project("node")
    H.write(dir .. "/.editorconfig", "mine")
    local ok, err = PF.create(by_file(dir, ".editorconfig"), dir, { open = false })
    H.falsy(ok)
    H.matches("already exists", err)
    H.eq("mine", H.read(dir .. "/.editorconfig"), "the existing file must survive")
  end)

  H.it("overwrites only when told to", function()
    local dir = project("node")
    H.write(dir .. "/.editorconfig", "mine")
    local ok, path = PF.create(by_file(dir, ".editorconfig"), dir, { open = false, overwrite = true })
    H.ok(ok, tostring(path))
    H.falsy(H.read(path) == "mine", "it should have been replaced")
    H.matches("root = true", H.read(path))
  end)

  H.it("refuses a generator with no file", function()
    local ok, err = PF.create({ name = "broken" }, H.tmpdir("pf-broken"), { open = false })
    H.falsy(ok)
    H.matches("Nothing to generate", err)
  end)

  H.it("writes every declared generator without error", function()
    -- A generator that renders nothing, or a non-string line, would only show
    -- up when someone picked it.
    for _, kind in ipairs({ "maven", "go", "rust", "node", "python", "flutter" }) do
      local dir = project(kind)
      for _, gen in ipairs(PF.available(dir)) do
        local ok, path = PF.create(gen, dir, { open = false, overwrite = true })
        H.ok(ok, ("%s in a %s project: %s"):format(gen.name, kind, tostring(path)))
        local lines = vim.fn.readfile(path)
        H.ok(#lines > 0, gen.name .. " wrote an empty file")
        for i, line in ipairs(lines) do
          H.ok(type(line) == "string", ("%s line %d is not a string"):format(gen.name, i))
        end
      end
    end
  end)
end)

H.describe("project file declarations", function()
  H.it("every generator has a name, a file and content", function()
    for _, g in ipairs(registry.collect("project_files")) do
      H.ok(type(g.name) == "string" and g.name ~= "", "a generator needs a name")
      H.ok(type(g.file) == "string" and g.file ~= "", g.name .. " needs a file name")
      H.ok(type(g.lines) == "table" or type(g.render) == "function",
        g.name .. " needs lines or a render function")
      if g.kinds ~= nil then
        H.ok(type(g.kinds) == "table" and #g.kinds > 0, g.name .. " kinds should be a list")
      end
    end
  end)

  H.it("writes no absolute paths", function()
    for _, g in ipairs(registry.collect("project_files")) do
      H.falsy(g.file:match("^/"), g.name .. " should write a relative path")
      H.falsy(g.file:match("%.%."), g.name .. " should not escape the project")
    end
  end)

  H.it("covers the four the backlog asked for", function()
    local files = {}
    for _, g in ipairs(registry.collect("project_files")) do
      files[g.file] = true
    end
    H.ok(files[".gitignore"], ".gitignore")
    H.ok(files["Dockerfile"], "Dockerfile")
    H.ok(files[".editorconfig"], ".editorconfig")
    local has_workflow = false
    for file in pairs(files) do
      if file:match("^%.github/workflows/") then has_workflow = true end
    end
    H.ok(has_workflow, "a GitHub Actions workflow")
  end)
end)

H.describe("the project file picker", function()
  H.it("writes the chosen file", function()
    local dir = project("go")
    local saved = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    H.with_ui({ ".editorconfig" }, function()
      H.capture_notify(function() PF.pick({ dir = dir }) end)
    end)
    vim.cmd("cd " .. vim.fn.fnameescape(saved))
    H.ok(H.exists(dir .. "/.editorconfig"))
    vim.cmd("bwipeout!")
  end)

  H.it("asks before replacing a file that is already there", function()
    local dir = project("go")
    H.write(dir .. "/.editorconfig", "mine")
    local ui = H.with_ui({ ".editorconfig", "No" }, function()
      H.capture_notify(function() PF.pick({ dir = dir }) end)
    end)
    H.eq(2, ui.consumed(), "it should have asked about overwriting")
    H.matches("Overwrite", ui.log[2].prompt)
    H.eq("mine", H.read(dir .. "/.editorconfig"), "No means no")
  end)

  H.it("replaces it on yes", function()
    local dir = project("go")
    H.write(dir .. "/.editorconfig", "mine")
    H.with_ui({ ".editorconfig", "Yes" }, function()
      H.capture_notify(function() PF.pick({ dir = dir }) end)
    end)
    H.matches("root = true", H.read(dir .. "/.editorconfig"))
    pcall(vim.cmd, "bwipeout!")
  end)

  H.it("marks the files that already exist", function()
    local dir = project("go")
    H.write(dir .. "/.editorconfig", "mine")
    local labels
    local orig = vim.ui.select
    vim.ui.select = function(items, opts)
      labels = vim.tbl_map(function(i) return opts.format_item(i) end, items)
    end
    PF.pick({ dir = dir })
    vim.ui.select = orig
    H.matches("%[exists%]", table.concat(labels, "\n"),
      "you should be able to see what is already there before choosing")
  end)

  H.it("does nothing when cancelled", function()
    local dir = project("go")
    H.with_ui({ H.CANCEL }, function()
      H.capture_notify(function() PF.pick({ dir = dir }) end)
    end)
    H.falsy(H.exists(dir .. "/.editorconfig"))
  end)
end)

H.describe("the :IdeProjectFile command", function()
  H.it("is registered", function()
    H.ok(vim.fn.exists(":IdeProjectFile") >= 1)
  end)

  H.it("reports an unknown name with the list of real ones", function()
    local notes = H.capture_notify(function()
      vim.cmd("IdeProjectFile nonsense-file")
    end)
    local n = H.notified(notes, "No generator matching")
    H.ok(n, "should say it did not match")
    H.matches("editorconfig", n.msg, "and list what is available")
  end)
end)
