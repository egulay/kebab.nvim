-- Adding a dependency. The Maven half edits pom.xml directly, so it is tested
-- hard: a bad insertion corrupts a build file, and the result is checked with a
-- real XML parser rather than a substring match.
local H = ...
local deps = require("kebab.deps")
-- The pom reading and writing moved to its own module when the ecosystem
-- knowledge moved into lua/kebab/languages/; deps.lua is now only the
-- dispatcher.
local maven = require("kebab.maven")

-- A Spring Boot pom in the shape start.spring.io produces, with the
-- dependencyManagement block that makes a naive search pick the wrong
-- <dependencies>.
local SPRING_POM = table.concat({
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  "    <modelVersion>4.0.0</modelVersion>",
  "    <parent>",
  "        <groupId>org.springframework.boot</groupId>",
  "        <artifactId>spring-boot-starter-parent</artifactId>",
  "        <version>3.3.0</version>",
  "        <relativePath/>",
  "    </parent>",
  "    <groupId>io.gulay</groupId>",
  "    <artifactId>demo</artifactId>",
  "    <version>0.0.1-SNAPSHOT</version>",
  "    <properties>",
  "        <java.version>21</java.version>",
  "    </properties>",
  "    <dependencyManagement>",
  "        <dependencies>",
  "            <dependency>",
  "                <groupId>com.managed</groupId>",
  "                <artifactId>managed-lib</artifactId>",
  "                <version>1.2.3</version>",
  "            </dependency>",
  "        </dependencies>",
  "    </dependencyManagement>",
  "    <dependencies>",
  "        <dependency>",
  "            <groupId>org.springframework.boot</groupId>",
  "            <artifactId>spring-boot-starter-web</artifactId>",
  "        </dependency>",
  "    </dependencies>",
  "    <build>",
  "        <plugins>",
  "            <plugin>",
  "                <groupId>org.springframework.boot</groupId>",
  "                <artifactId>spring-boot-maven-plugin</artifactId>",
  "            </plugin>",
  "        </plugins>",
  "    </build>",
  "</project>",
  "",
}, "\n")

local PLAIN_POM = table.concat({
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  "  <modelVersion>4.0.0</modelVersion>",
  "  <groupId>io.gulay</groupId>",
  "  <artifactId>plain</artifactId>",
  "  <version>1.0.0</version>",
  "</project>",
  "",
}, "\n")

---Parse `text` as XML and return the project-level dependencies as
---{ "group:artifact[:version]" }. Fails the test if the XML is malformed, which
---is the thing that actually matters after an insertion.
local function parsed_dependencies(text)
  local path = H.tmpdir("xml") .. "/pom.xml"
  H.write(path, text)
  local script = [[
import sys, xml.etree.ElementTree as ET
t = ET.parse(sys.argv[1]); r = t.getroot()
ns = {"m": r.tag.split("}")[0].strip("{")} if "}" in r.tag else {}
def find(node, name):
    return node.find("m:" + name, ns) if ns else node.find(name)
def findall(node, name):
    return node.findall("m:" + name, ns) if ns else node.findall(name)
deps = find(r, "dependencies")
if deps is None:
    print("NONE"); sys.exit(0)
for d in findall(deps, "dependency"):
    g = find(d, "groupId"); a = find(d, "artifactId"); v = find(d, "version")
    out = (g.text if g is not None else "?") + ":" + (a.text if a is not None else "?")
    if v is not None: out += ":" + v.text
    print(out)
]]
  local res = vim.system({ "python3", "-I", "-c", script, path }, { text = true }):wait(30000)
  H.eq(0, res.code, "the pom should still be valid XML:\n" .. (res.stderr or "") .. "\n" .. text)
  local out = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    if line ~= "NONE" then
      out[#out + 1] = line
    end
  end
  return out
end

H.describe("dependency ecosystem detection", function()
  H.it("finds each marker", function()
    local cases = {
      { "pubspec.yaml", "flutter" },
      { "pom.xml", "maven" },
      { "package.json", "node" },
      { "pyproject.toml", "python" },
      { "requirements.txt", "python" },
      { "build.gradle", "gradle" },
      { "build.gradle.kts", "gradle" },
      { "go.mod", "go" },
      { "Cargo.toml", "rust" },
      { ".git", "dir" },
    }
    for _, case in ipairs(cases) do
      local dir = H.tmpdir("detect")
      H.write(dir .. "/" .. case[1], "x")
      local kind, marker = deps.detect(dir)
      H.eq(case[2], kind, case[1] .. " should be " .. case[2])
      H.eq(dir .. "/" .. case[1], marker)
    end
  end)

  H.it("walks up from a nested directory", function()
    local dir = H.tmpdir("nested")
    H.write(dir .. "/pom.xml", "<project/>")
    vim.fn.mkdir(dir .. "/src/main/java/com/x", "p")
    local kind, marker = deps.detect(dir .. "/src/main/java/com/x")
    H.eq("maven", kind)
    H.eq(dir .. "/pom.xml", marker)
  end)

  H.it("prefers Flutter over node when both markers exist", function()
    -- a Flutter project with a web build can carry both
    local dir = H.tmpdir("hybrid")
    H.write(dir .. "/pubspec.yaml", "name: x")
    H.write(dir .. "/package.json", "{}")
    H.eq("flutter", (deps.detect(dir)))
  end)

  H.it("returns nil outside any project", function()
    H.eq(nil, (deps.detect(H.tmpdir("nothing"))))
  end)

  H.it("prefers a real build system over the bare git marker", function()
    -- every project is also a git repository, so `generic` is registered last
    local dir = H.tmpdir("gitplus")
    vim.fn.mkdir(dir .. "/.git", "p")
    H.write(dir .. "/Cargo.toml", "[package]")
    H.eq("rust", (deps.detect(dir)))
  end)
end)

H.describe("maven coordinates", function()
  H.it("expands a bare name to a Spring Boot starter", function()
    H.eq({ group = "org.springframework.boot", artifact = "spring-boot-starter-data-jpa" },
      maven.parse_coordinate("data-jpa"))
  end)

  H.it("does not double the starter prefix", function()
    H.eq({ group = "org.springframework.boot", artifact = "spring-boot-starter-security" },
      maven.parse_coordinate("spring-boot-starter-security"))
  end)

  H.it("takes group:artifact", function()
    H.eq({ group = "org.postgresql", artifact = "postgresql" },
      maven.parse_coordinate("org.postgresql:postgresql"))
  end)

  H.it("takes group:artifact:version", function()
    H.eq({ group = "org.postgresql", artifact = "postgresql", version = "42.7.3" },
      maven.parse_coordinate("org.postgresql:postgresql:42.7.3"))
  end)

  H.it("rejects nonsense", function()
    for _, bad in ipairs({ "", "   ", "a:b:c:d", ":artifact", "group:" }) do
      local dep, err = maven.parse_coordinate(bad)
      H.falsy(dep, ("%q should be rejected"):format(bad))
      H.ok(err and err ~= "", "should explain why")
    end
  end)
end)

H.describe("finding the right <dependencies> block", function()
  H.it("picks the project-level one, not dependencyManagement's", function()
    local open_end, close_start = maven.find_dependencies_block(SPRING_POM)
    H.ok(open_end, "should find a block")
    local block = SPRING_POM:sub(open_end, close_start - 1)
    H.matches("spring%-boot%-starter%-web", block, "should be the real dependencies block")
    H.falsy(block:match("managed%-lib"), "must not be the dependencyManagement block")
  end)

  H.it("returns nothing when there is no dependencies block", function()
    H.eq(nil, (maven.find_dependencies_block(PLAIN_POM)))
  end)

  H.it("is not fooled by <plugins> entries", function()
    local open_end, close_start = maven.find_dependencies_block(SPRING_POM)
    local block = SPRING_POM:sub(open_end, close_start - 1)
    H.falsy(block:match("maven%-plugin"), "plugins are not dependencies")
  end)
end)

H.describe("reading an existing pom", function()
  H.it("detects the spring-boot parent", function()
    H.eq(true, maven.has_spring_boot_parent(SPRING_POM))
    H.eq(false, maven.has_spring_boot_parent(PLAIN_POM))
  end)

  H.it("sees a dependency that is already there", function()
    H.eq(true, maven.has_dependency(SPRING_POM,
      { group = "org.springframework.boot", artifact = "spring-boot-starter-web" }))
    H.eq(false, maven.has_dependency(SPRING_POM,
      { group = "org.springframework.boot", artifact = "spring-boot-starter-security" }))
  end)

  H.it("does not count a managed dependency as a real one", function()
    H.eq(false, maven.has_dependency(SPRING_POM,
      { group = "com.managed", artifact = "managed-lib" }),
      "it is managed, not depended on")
  end)

  H.it("knows when a version is unnecessary", function()
    H.eq(false, maven.needs_version(SPRING_POM,
      { group = "org.springframework.boot", artifact = "spring-boot-starter-security" }),
      "the spring parent manages starter versions")
    H.eq(false, maven.needs_version(SPRING_POM,
      { group = "com.managed", artifact = "managed-lib" }),
      "dependencyManagement covers this one")
    H.eq(true, maven.needs_version(SPRING_POM,
      { group = "org.postgresql", artifact = "postgresql" }),
      "nothing manages this one")
  end)
end)

H.describe("maven.insert", function()
  H.it("adds a Spring starter without a version", function()
    local out, err = maven.insert(SPRING_POM, maven.parse_coordinate("data-jpa"))
    H.ok(out, err)
    local list = parsed_dependencies(out)
    H.eq({
      "org.springframework.boot:spring-boot-starter-web",
      "org.springframework.boot:spring-boot-starter-data-jpa",
    }, list)
  end)

  H.it("adds a third-party dependency with its version", function()
    local out, err = maven.insert(SPRING_POM,
      maven.parse_coordinate("org.postgresql:postgresql:42.7.3"))
    H.ok(out, err)
    H.ok(vim.tbl_contains(parsed_dependencies(out), "org.postgresql:postgresql:42.7.3"))
  end)

  H.it("refuses a third-party dependency with no version and no management", function()
    local out, err = maven.insert(SPRING_POM,
      maven.parse_coordinate("org.postgresql:postgresql"))
    H.falsy(out, "should refuse rather than write an unbuildable pom")
    H.matches("needs a version", err)
  end)

  H.it("adds a scope when asked", function()
    local dep = maven.parse_coordinate("org.postgresql:postgresql:42.7.3")
    dep.scope = "runtime"
    local out, err = maven.insert(SPRING_POM, dep)
    H.ok(out, err)
    H.matches("<scope>runtime</scope>", out)
    parsed_dependencies(out) -- still valid XML
  end)

  H.it("refuses a duplicate", function()
    local out, err = maven.insert(SPRING_POM, maven.parse_coordinate("web"))
    H.falsy(out)
    H.matches("already a dependency", err)
  end)

  H.it("creates a <dependencies> block when the pom has none", function()
    local out, err = maven.insert(PLAIN_POM,
      maven.parse_coordinate("org.postgresql:postgresql:42.7.3"))
    H.ok(out, err)
    H.eq({ "org.postgresql:postgresql:42.7.3" }, parsed_dependencies(out))
    H.matches("</dependencies>\n</project>", out:gsub("[ \t]", ""),
      "the new block should sit inside <project>")
  end)

  H.it("keeps the file's own indentation", function()
    local out = maven.insert(SPRING_POM, maven.parse_coordinate("data-jpa"))
    H.matches("\n        <dependency>\n            <groupId>org.springframework.boot</groupId>", out,
      "should match the four-space style of this pom")
  end)

  H.it("indents from the project block, not dependencyManagement's", function()
    -- The bug this guards: deriving the indent by matching "<dependencies>"
    -- finds dependencyManagement's copy first on every Spring pom, which is one
    -- level deeper, so the new entry landed at 16 spaces in a 12-space file.
    local out, err = maven.insert(SPRING_POM, maven.parse_coordinate("data-jpa"))
    H.ok(out, err)
    local inserted = out:match("\n([ \t]*)<dependency>\n[ \t]*<groupId>org%.springframework%.boot</groupId>\n[ \t]*<artifactId>spring%-boot%-starter%-data%-jpa")
    H.eq("        ", inserted, "<dependency> should sit at the same depth as its siblings")

    -- and the existing sibling is at exactly that depth, so they line up
    local sibling = out:match("\n([ \t]*)<dependency>\n[ \t]*<groupId>org%.springframework%.boot</groupId>\n[ \t]*<artifactId>spring%-boot%-starter%-web")
    H.eq(sibling, inserted, "the new entry should line up with the existing ones")
  end)

  H.it("lines up in a pom whose blocks are indented differently", function()
    local pom = table.concat({
      '<?xml version="1.0"?>',
      "<project>",
      "  <modelVersion>4.0.0</modelVersion>",
      "  <dependencyManagement>",
      "        <dependencies>",
      "            <dependency>",
      "                <groupId>com.managed</groupId>",
      "                <artifactId>m</artifactId>",
      "                <version>1</version>",
      "            </dependency>",
      "        </dependencies>",
      "  </dependencyManagement>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.managed</groupId>",
      "      <artifactId>m</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
      "",
    }, "\n")
    local out, err = maven.insert(pom, maven.parse_coordinate("org.postgresql:postgresql:42.7.3"))
    H.ok(out, err)
    local indent = out:match("\n([ \t]*)<dependency>\n[ \t]*<groupId>org%.postgresql")
    H.eq("    ", indent, "should follow the project block's two-space-per-level style")
    H.ok(vim.tbl_contains(parsed_dependencies(out), "org.postgresql:postgresql:42.7.3"))
  end)

  H.it("handles a tab-indented pom", function()
    local tabbed = SPRING_POM:gsub("\n    ", "\n\t"):gsub("\n\t    ", "\n\t\t")
    local out, err = maven.insert(tabbed, maven.parse_coordinate("data-jpa"))
    H.ok(out, err)
    local list = parsed_dependencies(out)
    H.ok(vim.tbl_contains(list, "org.springframework.boot:spring-boot-starter-data-jpa"))
  end)

  H.it("leaves everything else in the pom untouched", function()
    local out = maven.insert(SPRING_POM, maven.parse_coordinate("data-jpa"))
    for _, keep in ipairs({
      "<java.version>21</java.version>",
      "<artifactId>spring%-boot%-maven%-plugin</artifactId>",
      "<artifactId>managed%-lib</artifactId>",
      "<version>0.0.1%-SNAPSHOT</version>",
    }) do
      H.matches(keep, out, "insertion must not disturb " .. keep)
    end
  end)

  H.it("rejects an incomplete dependency", function()
    H.falsy(maven.insert(SPRING_POM, { group = "x" }))
    H.falsy(maven.insert(SPRING_POM, { artifact = "y" }))
    H.falsy(maven.insert(SPRING_POM, nil))
  end)

  H.it("adds two dependencies in a row", function()
    local out = maven.insert(SPRING_POM, maven.parse_coordinate("data-jpa"))
    out = maven.insert(out, maven.parse_coordinate("security"))
    H.eq({
      "org.springframework.boot:spring-boot-starter-web",
      "org.springframework.boot:spring-boot-starter-data-jpa",
      "org.springframework.boot:spring-boot-starter-security",
    }, parsed_dependencies(out))
  end)
end)

H.describe("package manager commands", function()
  H.it("uses flutter pub add", function()
    H.eq({ "flutter", "pub", "add", "provider" }, deps.command_for("flutter", "provider"))
    H.eq({ "flutter", "pub", "add", "--dev", "mockito" },
      deps.command_for("flutter", "mockito", { dev = true }))
  end)

  H.it("uses npm install", function()
    H.eq({ "npm", "install", "zod" }, deps.command_for("node", "zod"))
    H.eq({ "npm", "install", "--save-dev", "vitest" },
      deps.command_for("node", "vitest", { dev = true }))
  end)

  H.it("prefers uv for python when it is installed", function()
    if vim.fn.executable("uv") == 0 then
      H.skip("uv is not on PATH")
    end
    H.eq({ "uv", "add", "httpx" }, deps.command_for("python", "httpx"))
    H.eq({ "uv", "add", "--dev", "pytest" }, deps.command_for("python", "pytest", { dev = true }))
  end)

  H.it("explains that maven is edited, not installed", function()
    local cmd, err = deps.command_for("maven", "anything")
    H.falsy(cmd)
    H.matches("pom%.xml", err)
  end)

  H.it("uses go get, and does not tidy afterwards", function()
    H.eq({ "go", "get", "github.com/go-chi/chi/v5" },
      deps.command_for("go", "github.com/go-chi/chi/v5"))
    -- `go mod tidy` removes any requirement no package imports, so running it
    -- straight after the add deletes the dependency just requested. Verified
    -- against a real module: go.sum is written and go.mod comes back
    -- unchanged. This guards against the convenience being re-added.
    H.eq(nil, require("kebab.registry").deps_for("go").after,
      "an automatic tidy would undo the add")
  end)

  H.it("uses cargo add", function()
    H.eq({ "cargo", "add", "serde" }, deps.command_for("rust", "serde"))
    H.eq({ "cargo", "add", "--dev", "rstest" },
      deps.command_for("rust", "rstest", { dev = true }))
  end)

  H.it("rejects an unknown kind", function()
    local cmd, err = deps.command_for("cobol", "anything")
    H.falsy(cmd)
    H.matches("Unknown project kind", err)
  end)

  H.it("explains that gradle is edited, not installed", function()
    local cmd, err = deps.command_for("gradle", "anything")
    H.falsy(cmd)
    H.matches("build%.gradle", err, "gradle has no add-a-dependency command either")
  end)

  H.it("rejects an empty or multi-word package", function()
    H.falsy(deps.command_for("node", ""))
    local cmd, err = deps.command_for("node", "two packages")
    H.falsy(cmd)
    H.matches("one package at a time", err)
  end)
end)

H.describe("the add flow", function()
  H.it("writes the dependency into a real pom on disk", function()
    local dir = H.tmpdir("add-pom")
    H.write(dir .. "/pom.xml", SPRING_POM)
    local result
    H.capture_notify(function()
      deps.add("data-jpa", { cwd = dir, done = function(ok, err) result = { ok, err } end })
    end)
    H.ok(result[1], tostring(result[2]))
    H.ok(vim.tbl_contains(parsed_dependencies(H.read(dir .. "/pom.xml")),
      "org.springframework.boot:spring-boot-starter-data-jpa"))
  end)

  H.it("adds a Maven dev dependency as <scope>test</scope>", function()
    -- Maven has no dev/prod flag; test scope is the equivalent, so the bang
    -- form has to mean something rather than being silently ignored.
    local dir = H.tmpdir("add-dev")
    H.write(dir .. "/pom.xml", SPRING_POM)
    local result
    H.capture_notify(function()
      deps.add("org.testcontainers:testcontainers:1.20.1",
        { cwd = dir, dev = true, done = function(ok, err) result = { ok, err } end })
    end)
    H.ok(result[1], tostring(result[2]))
    local pom = H.read(dir .. "/pom.xml")
    H.matches("<artifactId>testcontainers</artifactId>%s*\n%s*<version>1%.20%.1</version>%s*\n%s*<scope>test</scope>", pom)
    parsed_dependencies(pom) -- still valid XML
  end)

  H.it("adds a non-Maven dev dependency through the package manager", function()
    local dir = H.tmpdir("add-dev-node")
    H.write(dir .. "/package.json", "{}")
    -- Asserting on the command rather than running npm, which would hit the
    -- network for a package that may not exist.
    H.eq({ "npm", "install", "--save-dev", "vitest" },
      deps.command_for("node", "vitest", { dev = true }))
  end)

  H.it("prompts when given no argument", function()
    local dir = H.tmpdir("add-prompt")
    H.write(dir .. "/pom.xml", SPRING_POM)
    local ui = H.with_ui({ "security" }, function()
      H.capture_notify(function() deps.add(nil, { cwd = dir }) end)
    end)
    H.eq(1, ui.consumed())
    H.matches("group:artifact", ui.log[1].prompt, "the maven prompt should explain the format")
    H.ok(vim.tbl_contains(parsed_dependencies(H.read(dir .. "/pom.xml")),
      "org.springframework.boot:spring-boot-starter-security"))
  end)

  H.it("does nothing when the prompt is cancelled", function()
    local dir = H.tmpdir("add-cancel")
    H.write(dir .. "/pom.xml", SPRING_POM)
    local before = H.read(dir .. "/pom.xml")
    H.with_ui({ H.CANCEL }, function()
      H.capture_notify(function() deps.add(nil, { cwd = dir }) end)
    end)
    H.eq(before, H.read(dir .. "/pom.xml"), "the pom must be byte-for-byte unchanged")
  end)

  H.it("reports when there is no project at all", function()
    local dir = H.tmpdir("add-noproject")
    local result
    local notes = H.capture_notify(function()
      deps.add("x", { cwd = dir, done = function(ok, err) result = { ok, err } end })
    end)
    H.falsy(result[1])
    H.ok(H.notified(notes, "No project above"))
  end)

  H.it("reports a duplicate instead of writing it twice", function()
    local dir = H.tmpdir("add-dup")
    H.write(dir .. "/pom.xml", SPRING_POM)
    local result
    local notes = H.capture_notify(function()
      deps.add("web", { cwd = dir, done = function(ok, err) result = { ok, err } end })
    end)
    H.falsy(result[1])
    H.ok(H.notified(notes, "already a dependency"))
    H.eq(1, #parsed_dependencies(H.read(dir .. "/pom.xml")), "still exactly one dependency")
  end)

  H.it("reports a missing package manager instead of throwing", function()
    -- vim.system *throws* ENOENT for a missing executable rather than
    -- returning a code, so this used to abort with a stack trace and never
    -- call `done`. Found because the doctor pointed out bundler was missing.
    local dir = H.tmpdir("add-nobin")
    H.write(dir .. "/package.json", "{}")
    local real = vim.fn.executable
    vim.fn.executable = function(exe)
      if exe == "npm" then
        return 0
      end
      return real(exe)
    end
    local result
    local notes
    local ok, err = pcall(function()
      notes = H.capture_notify(function()
        deps.add("zod", { cwd = dir, done = function(o, e) result = { o, e } end })
      end)
    end)
    vim.fn.executable = real

    H.ok(ok, "it must not throw: " .. tostring(err))
    H.ok(result, "the callback must still fire")
    H.eq(false, result[1])
    H.matches("npm is not installed", result[2])
    H.ok(H.notified(notes, "not installed"), "and say so")
  end)

  H.it("tells you how to install the missing manager", function()
    local dir = H.tmpdir("add-hint")
    H.write(dir .. "/Gemfile", 'source "https://rubygems.org"')
    local real = vim.fn.executable
    vim.fn.executable = function(exe)
      if exe == "bundle" then
        return 0
      end
      return real(exe)
    end
    local result
    H.capture_notify(function()
      deps.add("sinatra", { cwd = dir, done = function(o, e) result = { o, e } end })
    end)
    vim.fn.executable = real
    H.matches("gem install", result[2],
      "the advice should come from the same place the doctor gets it")
    H.matches("bundler", result[2])
  end)

  H.it("registers :IdeAddDependency", function()
    H.ok(vim.fn.exists(":IdeAddDependency") >= 1, ":IdeAddDependency should be defined")
  end)
end)

-- Three ways a pom survived `mvn validate` before an insert and was
-- non-parseable after it: markup read out of a comment or a CDATA section, and
-- a `<dependencies/>` that looked like "no dependency block at all".
H.describe("poms that used to be corrupted by an insert", function()
  local M = require("kebab.maven")

  local function pom(middle)
    return table.concat({
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<project xmlns="http://maven.apache.org/POM/4.0.0">',
      "  <modelVersion>4.0.0</modelVersion>",
      "  <groupId>com.example</groupId>",
      "  <artifactId>app</artifactId>",
      "  <version>1.0</version>",
      middle,
      "</project>",
      "",
    }, "\n")
  end

  local dep = { group = "com.fasterxml.jackson.core", artifact = "jackson-databind", version = "2.17.1" }

  local cases = {
    ["a <dependency> named inside a comment"] = pom(
      "  <!-- TODO: a <dependency> for redis goes here -->\n  <dependencies>\n  </dependencies>"
    ),
    ["a <dependency> named inside CDATA"] = pom(
      "  <description><![CDATA[add a <dependency> later]]></description>\n  <dependencies>\n  </dependencies>"
    ),
    ["a self-closing <dependencies/>"] = pom("  <dependencies/>"),
  }

  for label, text in pairs(cases) do
    H.it("leaves exactly one <dependencies> for " .. label, function()
      local updated, err = M.insert(text, dep)
      H.ok(updated, tostring(err))
      local opens = select(2, updated:gsub("<dependencies>", ""))
      H.eq(1, opens, "a second <dependencies> makes the pom non-parseable")
      H.eq(1, select(2, updated:gsub("</dependencies>", "")))
      H.matches("jackson%-databind", updated)
      -- and it must be a real dependency, not a managed version
      H.ok(M.has_dependency(updated, dep), "the new entry should be in the project's own block")
    end)
  end

  H.it("does not mistake a commented-out block for the real one", function()
    local text = pom(table.concat({
      "  <!--",
      "  <dependencies>",
      "    <dependency><groupId>old</groupId><artifactId>old</artifactId></dependency>",
      "  </dependencies>",
      "  -->",
      "  <dependencies>",
      "  </dependencies>",
    }, "\n"))
    local updated, err = M.insert(text, dep)
    H.ok(updated, tostring(err))
    H.eq(2, select(2, updated:gsub("<dependencies>", "")), "the commented one is still text")
    H.ok(M.has_dependency(updated, dep))
    H.falsy(M.has_dependency(updated, { group = "old", artifact = "old" }), "a commented dependency is not declared")
  end)

  H.it("blanks text regions without moving any byte offset", function()
    local text = pom("  <!-- x -->\n  <dependencies>\n  </dependencies>")
    local blanked = M.blank_text_regions(text)
    H.eq(#text, #blanked, "offsets must survive, so comments become spaces")
    H.eq(select(2, text:gsub("\n", "")), select(2, blanked:gsub("\n", "")), "newlines are kept")
    H.falsy(blanked:find("<!--", 1, true), "the comment markup should be gone")
  end)

  H.it("keeps CRLF endings and a missing final newline", function()
    local path = H.tmpdir("crlf-pom") .. "/pom.xml"
    local body = pom("  <dependencies>\n  </dependencies>"):gsub("\n$", ""):gsub("\n", "\r\n")
    vim.fn.writefile({ body }, path, "b")
    local before = table.concat(vim.fn.readfile(path, "b"), "\n")
    H.ok(before:find("\r\n"), "the fixture should be CRLF")
    H.ok(M.add_to_file(path, dep))
    local after = table.concat(vim.fn.readfile(path, "b"), "\n")
    H.falsy(after:find("[^\r]\n"), "every line should still end CRLF")
    H.falsy(after:sub(-1) == "\n", "a file without a final newline should not gain one")
    H.matches("jackson%-databind", after)
  end)

  -- A pasted build-script snippet splits into three non-empty parts, and
  -- writing those out unescaped breaks the build file instead of failing.
  H.it("rejects a pasted dependency snippet", function()
    for _, bad in ipairs({
      "implementation 'com.google.guava:guava:33.0.0-jre'",
      'implementation("com.google.guava:guava:33.0.0-jre")',
      "a&b:c:1",
      "a<b:c:1",
      'a":c:1',
      "g:a:1 2",
    }) do
      local parsed, err = M.parse_coordinate(bad)
      H.falsy(parsed, bad .. " should not parse")
      H.matches("coordinate", err, "it should say what is wrong with " .. bad)
    end
  end)

  H.it("still accepts the coordinates people really type", function()
    for _, good in ipairs({
      "org.slf4j:slf4j-api:2.0.13",
      "org.slf4j:slf4j-api",
      "com.h2database:h2:2.2.224",
      "g:a:[1.0,2.0)",
      "g:a:1.0+build.5",
      "data-jpa",
    }) do
      local parsed, err = M.parse_coordinate(good)
      H.ok(parsed, good .. " should parse: " .. tostring(err))
    end
  end)
end)
