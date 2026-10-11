-- Editing a Gradle build file. Same reasoning as the Maven half: Gradle has no
-- command that adds a dependency, so the file is rewritten, and a bad insertion
-- breaks the build -- so the string functions are tested hard.
local H = ...
local G = require("kebab.gradle")

local KTS = table.concat({
  "plugins {",
  '    id("java")',
  '    id("org.springframework.boot") version "3.3.0"',
  '    id("io.spring.dependency-management") version "1.1.5"',
  "}",
  "",
  "group = \"io.gulay\"",
  "",
  "repositories {",
  "    mavenCentral()",
  "}",
  "",
  "dependencies {",
  '    implementation("org.springframework.boot:spring-boot-starter-web")',
  '    testImplementation("org.springframework.boot:spring-boot-starter-test")',
  "}",
  "",
  "tasks.withType<Test> {",
  "    useJUnitPlatform()",
  "}",
  "",
}, "\n")

local GROOVY = table.concat({
  "plugins {",
  "    id 'java'",
  "}",
  "",
  "repositories {",
  "    mavenCentral()",
  "}",
  "",
  "dependencies {",
  "    implementation 'com.google.guava:guava:33.0.0-jre'",
  "}",
  "",
}, "\n")

-- A build file where the dependencies block that appears *first* is not the
-- project's own. This is the shape that defeats a plain search.
local NESTED = table.concat({
  "buildscript {",
  "    dependencies {",
  '        classpath("com.example:some-plugin:1.0")',
  "    }",
  "}",
  "",
  "subprojects {",
  "    dependencies {",
  '        implementation("com.example:shared:1.0")',
  "    }",
  "}",
  "",
  "dependencies {",
  '    implementation("org.real:project-dependency:2.0")',
  "}",
  "",
}, "\n")

H.describe("dialect", function()
  H.it("tells Kotlin and Groovy build files apart", function()
    H.eq("kotlin", G.dialect("/p/build.gradle.kts"))
    H.eq("groovy", G.dialect("/p/build.gradle"))
    H.eq("groovy", G.dialect(""))
  end)
end)

H.describe("finding the dependencies block", function()
  H.it("finds the top-level one in a Kotlin build", function()
    local open_end, close_start = G.find_dependencies_block(KTS)
    H.ok(open_end, "should find a block")
    local block = KTS:sub(open_end, close_start - 1)
    H.matches("spring%-boot%-starter%-web", block)
    H.falsy(block:match("useJUnitPlatform"), "it should stop at the matching brace")
  end)

  H.it("ignores buildscript and subprojects blocks", function()
    -- The project's own block is third in the file; a plain search finds
    -- buildscript's first and would add a classpath entry instead.
    local open_end, close_start = G.find_dependencies_block(NESTED)
    H.ok(open_end)
    local block = NESTED:sub(open_end, close_start - 1)
    H.matches("project%-dependency", block, "it should be the top-level block")
    H.falsy(block:match("classpath"), "not buildscript's")
    H.falsy(block:match("shared"), "not subprojects'")
  end)

  H.it("reports the block's indentation", function()
    local _, _, indent = G.find_dependencies_block(KTS)
    H.eq("", indent, "a top-level block is not indented")
  end)

  H.it("finds nothing when there is no block", function()
    H.eq(nil, (G.find_dependencies_block("plugins {\n    id('java')\n}\n")))
  end)

  H.it("is not fooled by a commented-out block", function()
    local text = "// dependencies {\n//   implementation('a:b:1')\n// }\n\ndependencies {\n    implementation(\"real:dep:1\")\n}\n"
    local open_end, close_start = G.find_dependencies_block(text)
    H.ok(open_end)
    H.matches("real:dep", text:sub(open_end, close_start - 1))
  end)
end)

H.describe("reading an existing build", function()
  H.it("sees a dependency that is already declared, in either dialect", function()
    H.eq(true, G.has_dependency(KTS,
      { group = "org.springframework.boot", artifact = "spring-boot-starter-web" }))
    H.eq(true, G.has_dependency(GROOVY, { group = "com.google.guava", artifact = "guava" }))
    H.eq(false, G.has_dependency(KTS,
      { group = "org.springframework.boot", artifact = "spring-boot-starter-security" }))
  end)

  H.it("does not count a nested block's dependency as the project's", function()
    H.eq(false, G.has_dependency(NESTED, { group = "com.example", artifact = "shared" }),
      "that one belongs to subprojects")
  end)

  H.it("detects the Spring Boot plugin, which manages versions", function()
    H.eq(true, G.version_managed(KTS, { group = "org.springframework.boot" }))
    H.eq(false, G.version_managed(GROOVY, { group = "org.springframework.boot" }))
    H.eq(false, G.version_managed(KTS, { group = "com.google.guava" }),
      "it only manages its own group")
  end)

  H.it("knows when a version is unnecessary", function()
    H.eq(false, G.needs_version(KTS,
      { group = "org.springframework.boot", artifact = "spring-boot-starter-security" }))
    H.eq(true, G.needs_version(GROOVY, { group = "org.postgresql", artifact = "postgresql" }))
    H.eq(true, G.needs_version(KTS,
      { group = "org.postgresql", artifact = "postgresql", version = "42.7.4" }))
  end)
end)

H.describe("the declaration it writes", function()
  H.it("uses function-call syntax for Kotlin", function()
    H.eq('implementation("a:b:1.0")',
      G.declaration("kotlin", "implementation", { group = "a", artifact = "b", version = "1.0" }))
  end)

  H.it("uses quoted-string syntax for Groovy", function()
    H.eq("testImplementation 'a:b'",
      G.declaration("groovy", "testImplementation", { group = "a", artifact = "b" }))
  end)

  H.it("omits the version when there is none", function()
    H.eq('implementation("a:b")', G.declaration("kotlin", "implementation", { group = "a", artifact = "b" }))
  end)
end)

H.describe("inserting a dependency", function()
  H.it("adds a Spring starter with no version to a Kotlin build", function()
    local out, err = G.insert(KTS, G.parse_coordinate("data-jpa"), { dialect = "kotlin" })
    H.ok(out, err)
    H.matches('implementation%("org%.springframework%.boot:spring%-boot%-starter%-data%-jpa"%)', out)
    H.falsy(out:match("starter%-data%-jpa:"), "the plugin manages the version")
  end)

  H.it("adds a third-party dependency with its version", function()
    local out, err = G.insert(KTS, G.parse_coordinate("org.postgresql:postgresql:42.7.4"),
      { dialect = "kotlin" })
    H.ok(out, err)
    H.matches('implementation%("org%.postgresql:postgresql:42%.7%.4"%)', out)
  end)

  H.it("refuses a third-party dependency with no version and nothing managing it", function()
    local out, err = G.insert(GROOVY, G.parse_coordinate("org.postgresql:postgresql"),
      { dialect = "groovy" })
    H.falsy(out, "it should refuse rather than write a build that will not resolve")
    H.matches("needs a version", err)
  end)

  H.it("writes Groovy syntax into a Groovy build", function()
    local out, err = G.insert(GROOVY, G.parse_coordinate("org.postgresql:postgresql:42.7.4"),
      { dialect = "groovy" })
    H.ok(out, err)
    H.matches("implementation 'org%.postgresql:postgresql:42%.7%.4'", out)
    H.falsy(out:match('implementation%("org%.postgresql'), "not Kotlin syntax")
  end)

  H.it("honours the configuration asked for", function()
    local out = G.insert(KTS, G.parse_coordinate("org.x:y:1"),
      { dialect = "kotlin", configuration = "testImplementation" })
    H.matches('testImplementation%("org%.x:y:1"%)', out)
  end)

  H.it("matches the indentation already used in the block", function()
    local out = G.insert(KTS, G.parse_coordinate("data-jpa"), { dialect = "kotlin" })
    H.matches('\n    implementation%("org%.springframework%.boot:spring%-boot%-starter%-data%-jpa"%)', out,
      "four spaces, like its siblings")
  end)

  H.it("adds into the top-level block, not a nested one", function()
    local out, err = G.insert(NESTED, G.parse_coordinate("org.new:thing:1.0"), { dialect = "kotlin" })
    H.ok(out, err)
    local open_end, close_start = G.find_dependencies_block(out)
    H.matches("org%.new:thing", out:sub(open_end, close_start - 1),
      "it must land in the project's own block")
    -- and the nested blocks are untouched
    H.matches('classpath%("com%.example:some%-plugin:1%.0"%)', out)
    H.matches('implementation%("com%.example:shared:1%.0"%)', out)
  end)

  H.it("refuses a duplicate", function()
    local out, err = G.insert(KTS, G.parse_coordinate("web"), { dialect = "kotlin" })
    H.falsy(out)
    H.matches("already a dependency", err)
  end)

  H.it("refuses when there is no dependencies block", function()
    local out, err = G.insert("plugins {\n    id(\"java\")\n}\n",
      G.parse_coordinate("org.x:y:1"), { dialect = "kotlin" })
    H.falsy(out)
    H.matches("no top%-level dependencies", err)
  end)

  H.it("refuses an incomplete dependency", function()
    H.falsy(G.insert(KTS, { group = "x" }))
    H.falsy(G.insert(KTS, nil))
  end)

  H.it("leaves the rest of the build alone", function()
    local out = G.insert(KTS, G.parse_coordinate("data-jpa"), { dialect = "kotlin" })
    for _, keep in ipairs({
      'id%("org%.springframework%.boot"%) version "3%.3%.0"',
      "mavenCentral%(%)",
      "useJUnitPlatform%(%)",
      'group = "io%.gulay"',
    }) do
      H.matches(keep, out, "insertion must not disturb " .. keep)
    end
  end)

  H.it("adds two in a row", function()
    local out = G.insert(KTS, G.parse_coordinate("data-jpa"), { dialect = "kotlin" })
    out = G.insert(out, G.parse_coordinate("security"), { dialect = "kotlin" })
    H.matches("starter%-data%-jpa", out)
    H.matches("starter%-security", out)
  end)
end)

H.describe("writing to a file", function()
  H.it("adds to a Kotlin build on disk", function()
    local dir = H.tmpdir("gradle-kts")
    H.write(dir .. "/build.gradle.kts", KTS)
    local ok, msg = G.add_to_file(dir .. "/build.gradle.kts", "data-jpa")
    H.ok(ok, tostring(msg))
    H.matches("build%.gradle%.kts", msg)
    H.matches("implementation", msg)
    H.matches("starter%-data%-jpa", H.read(dir .. "/build.gradle.kts"))
  end)

  H.it("picks the dialect from the file name", function()
    local dir = H.tmpdir("gradle-groovy")
    H.write(dir .. "/build.gradle", GROOVY)
    local ok, msg = G.add_to_file(dir .. "/build.gradle", "org.postgresql:postgresql:42.7.4")
    H.ok(ok, tostring(msg))
    H.matches("implementation 'org%.postgresql", H.read(dir .. "/build.gradle"),
      "a .gradle file gets Groovy syntax")
  end)

  H.it("uses testImplementation for a dev dependency", function()
    local dir = H.tmpdir("gradle-test")
    H.write(dir .. "/build.gradle.kts", KTS)
    local ok, msg = G.add_to_file(dir .. "/build.gradle.kts",
      "org.testcontainers:testcontainers:1.20.1", { dev = true })
    H.ok(ok, tostring(msg))
    H.matches('testImplementation%("org%.testcontainers', H.read(dir .. "/build.gradle.kts"))
  end)

  H.it("reports a duplicate instead of writing it twice", function()
    local dir = H.tmpdir("gradle-dup")
    H.write(dir .. "/build.gradle.kts", KTS)
    local ok, err = G.add_to_file(dir .. "/build.gradle.kts", "web")
    H.falsy(ok)
    H.matches("already a dependency", err)
  end)

  H.it("reports an unreadable file", function()
    local ok, err = G.add_to_file("/definitely/not/here/build.gradle.kts", "web")
    H.falsy(ok)
    H.matches("Could not read", err)
  end)
end)

H.describe("the dependency flow reaches gradle", function()
  H.it("edits build.gradle.kts through :IdeAddDependency", function()
    local deps = require("kebab.deps")
    local dir = H.tmpdir("gradle-flow")
    H.write(dir .. "/build.gradle.kts", KTS)
    H.eq("gradle", (deps.detect(dir)))
    local result
    H.capture_notify(function()
      deps.add("data-jpa", { cwd = dir, done = function(ok, err) result = { ok, err } end })
    end)
    H.ok(result[1], tostring(result[2]))
    H.matches("starter%-data%-jpa", H.read(dir .. "/build.gradle.kts"))
  end)

  H.it("prompts the same way Maven does", function()
    local deps = require("kebab.deps")
    H.matches("group:artifact", deps.prompt_for("gradle"))
  end)
end)

-- Blanking comments with a pattern matched the first `//` on the line --
-- including the one inside a repository URL -- which erased that line's
-- closing brace from the scanned copy, so the top-level block was never found
-- and :IdeAddDependency refused to add anything to an ordinary build file.
H.describe("scanning a build file that is not trivial", function()
  local function kts(body)
    return table.concat({
      'plugins { kotlin("jvm") version "2.0.0" }',
      "repositories {",
      "    mavenCentral()",
      '    maven { url = uri("https://repo.spring.io/milestone") }',
      "}",
      "dependencies {",
      body,
      "}",
      "",
    }, "\n")
  end

  H.it("does not read a URL's // as a comment", function()
    local text = kts('    implementation("org.slf4j:slf4j-api:2.0.13")')
    local open_end, close_start = G.find_dependencies_block(text)
    H.ok(open_end, "the block should be found despite the maven URL")
    H.matches("slf4j%-api", text:sub(open_end, close_start - 1))

    -- the Groovy spelling too
    local groovy = table.concat({
      "repositories {",
      '    maven { url "https://plugins.gradle.org/m2/" }',
      "}",
      "dependencies {",
      "    implementation 'org.slf4j:slf4j-api:2.0.13'",
      "}",
    }, "\n")
    H.ok(G.find_dependencies_block(groovy), "and for Groovy")
  end)

  H.it("preserves every byte offset while blanking", function()
    local text = kts('    implementation("a:b:1") // trailing')
    for _, opts in ipairs({ { strings = false }, { strings = true } }) do
      local blanked = G.blank(text, opts)
      H.eq(#text, #blanked, "blanking must not move any offset")
      H.eq(select(2, text:gsub("\n", "")), select(2, blanked:gsub("\n", "")), "newlines are kept")
      H.falsy(blanked:find("// trailing", 1, true), "the comment should be gone")
    end
    H.matches("a:b:1", G.blank(text, { strings = false }), "a coordinate survives when strings are kept")
    H.falsy(G.blank(text, { strings = true }):find("a:b:1", 1, true), "and not when they are not")
  end)

  H.it("does not count a brace inside a string literal", function()
    -- the literal `}` used to make the nested block read as depth 0, so the
    -- dependency went into subprojects { } and applied to every subproject
    local text = table.concat({
      'ext.closeBrace = "}"',
      "subprojects {",
      "    dependencies {",
      "        implementation 'org.old:thing:1.0'",
      "    }",
      "}",
      "dependencies {",
      "    implementation 'org.slf4j:slf4j-api:2.0.13'",
      "}",
    }, "\n")
    local open_end, close_start = G.find_dependencies_block(text)
    H.ok(open_end, "a top-level block should be found")
    local block = text:sub(open_end, close_start - 1)
    H.matches("slf4j", block, "it must be the project's own block, got: " .. block)
    H.falsy(block:find("org.old", 1, true), "not the one inside subprojects: " .. block)
  end)
end)

H.describe("has_dependency and comments", function()
  local jackson = { group = "com.fasterxml.jackson.core", artifact = "jackson-databind" }

  H.it("does not count a commented-out declaration as present", function()
    local text = table.concat({
      "dependencies {",
      '    // implementation("com.fasterxml.jackson.core:jackson-databind:2.17.0")',
      "    implementation 'org.slf4j:slf4j-api:2.0.13'",
      "}",
    }, "\n")
    H.falsy(G.has_dependency(text, jackson), "nothing depends on it, so adding it must be allowed")
  end)

  H.it("still finds a real declaration after an apostrophe in a comment", function()
    -- the lone ' in "Jackson's" used to shift the quote pairing, so the real
    -- coordinate was never seen and a duplicate line was appended
    local text = table.concat({
      "dependencies {",
      "    // Jackson's databind",
      "    implementation 'com.fasterxml.jackson.core:jackson-databind:2.17.0'",
      "}",
    }, "\n")
    H.ok(G.has_dependency(text, jackson), "it is declared, so it must not be added twice")
  end)
end)
