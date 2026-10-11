-- Kotlin.
--
-- No markers of its own on purpose. A Kotlin project is built with Gradle, and
-- java.lua already claims build.gradle.kts and build.gradle -- including the
-- dependency editing, which is the same `dependencies { }` block whatever
-- language is inside. Claiming them here as well would only shadow that.
local S = require("kebab.scaffold")

return {
  key = "kotlin",
  label = "Kotlin",
  kind = "gradle",
  filetypes = { "kotlin" },

  markers = {},

  extras = { "lazyvim.plugins.extras.lang.kotlin" },
  -- The extra installs ktlint and declares the language server; naming the
  -- server too means a fresh install does not land without one.
  tools = { "kotlin-language-server", "ktlint" },

  tasks = (function()
    local function gradlew()
      return { vim.fn.executable("./gradlew") == 1 and "./gradlew" or "gradle" }
    end
    return {
      { name = "gradle: run", cmd = gradlew, args = { "run" }, desc = "Run the application", marker = { "build.gradle.kts", "build.gradle" } },
      { name = "gradle: test", cmd = gradlew, args = { "test" }, desc = "Run all tests", marker = { "build.gradle.kts", "build.gradle" } },
      { name = "gradle: build", cmd = gradlew, args = { "build" }, desc = "Build everything", marker = { "build.gradle.kts", "build.gradle" } },
      { name = "gradle: bootRun", cmd = gradlew, args = { "bootRun" }, desc = "Run the Spring Boot app", marker = { "build.gradle.kts", "build.gradle" } },
      { name = "gradle: ktlintCheck", cmd = gradlew, args = { "ktlintCheck" }, desc = "Lint", marker = { "build.gradle.kts", "build.gradle" } },
    }
  end)(),

  scratch = {
    {
      key = "kt",
      name = "Kotlin",
      extension = "kt",
      filetype = "kotlin",
      lines = { "fun main() {", '    println("hello")', "}" },
    },
  },

  templates = (function()
    local function package_line(ctx)
      local pkg = require("kebab.templates").package_for(ctx.dir)
      if pkg == "" then
        return {}
      end
      return { "package " .. pkg, "" }
    end
    return {
      {
        name = "Kotlin class",
        extension = "kt",
        prompt = "Class name",
        filetypes = { "kotlin" },
        render = function(ctx)
          local lines = package_line(ctx)
          vim.list_extend(lines, { ("class %s {"):format(ctx.name), "}", "" })
          return lines
        end,
      },
      {
        name = "Kotlin data class",
        extension = "kt",
        prompt = "Class name",
        filetypes = { "kotlin" },
        render = function(ctx)
          local lines = package_line(ctx)
          vim.list_extend(lines, { ("data class %s("):format(ctx.name), "    val id: Long,", ")", "" })
          return lines
        end,
      },
      {
        name = "Kotlin interface",
        extension = "kt",
        prompt = "Interface name",
        filetypes = { "kotlin" },
        render = function(ctx)
          local lines = package_line(ctx)
          vim.list_extend(lines, { ("interface %s {"):format(ctx.name), "}", "" })
          return lines
        end,
      },
      {
        name = "Kotlin test class (JUnit 5)",
        extension = "kt",
        prompt = "Test class name",
        filetypes = { "kotlin" },
        target_dir = function(dir)
          return require("kebab.templates").test_dir_for(dir)
        end,
        default_name = function(current)
          if current == nil or current == "" then
            return nil
          end
          return current:match("Test$") and current or (current .. "Test")
        end,
        render = function(ctx)
          local lines = package_line(ctx)
          vim.list_extend(lines, {
            "import kotlin.test.Test",
            "import kotlin.test.assertTrue",
            "",
            ("class %s {"):format(ctx.name),
            "",
            "    @Test",
            "    fun todo() {",
            "        assertTrue(true)",
            "    }",
            "}",
            "",
          })
          return lines
        end,
      },
    }
  end)(),

  project_files = {
    {
      name = ".gitignore (Kotlin/Gradle)",
      file = ".gitignore",
      kinds = { "gradle" },
      lines = {
        "build/", ".gradle/", "!gradle/wrapper/gradle-wrapper.jar",
        "*.class", "*.jar", "out/",
        "", "# IDE", ".idea/", "*.iml",
        "", "# local config", ".env",
      },
    },
    {
      name = "GitHub Actions (Gradle)",
      file = ".github/workflows/build.yml",
      kinds = { "gradle" },
      lines = {
        "name: build",
        "",
        "on:",
        "  push:",
        "    branches: [main]",
        "  pull_request:",
        "",
        "jobs:",
        "  build:",
        "    runs-on: ubuntu-latest",
        "    steps:",
        "      - uses: actions/checkout@v4",
        "      - uses: actions/setup-java@v4",
        "        with:",
        "          distribution: temurin",
        '          java-version: "21"',
        "      - uses: gradle/actions/setup-gradle@v4",
        "      - run: ./gradlew build",
      },
    },
  },

  project_types = {
    {
      key = "kotlin",
      label = "Kotlin (Gradle)",
      requires = { "git" },
      prompts = {
        { name = "package", prompt = "Package: ", default = "com.example" },
      },
      build = function(ctx, done)
        -- `gradle init` needs Gradle installed and is slow and interactive-ish.
        -- Writing the wrapper-less skeleton by hand means the scaffold works
        -- with nothing but git, and `gradle wrapper` is one task away.
        local pkg = ctx.answers.package
        if pkg == nil or pkg == "" then
          pkg = "com.example"
        end
        local pkg_path = pkg:gsub("%.", "/")
        local name = S.sanitise(ctx.name, "kebab")
        S.mkdir(ctx.dest)
        S.write_file(ctx.dest .. "/settings.gradle.kts", {
          ('rootProject.name = "%s"'):format(name),
        })
        S.write_file(ctx.dest .. "/build.gradle.kts", {
          "plugins {",
          '    kotlin("jvm") version "2.0.21"',
          "    application",
          "}",
          "",
          ('group = "%s"'):format(pkg),
          'version = "0.1.0"',
          "",
          "repositories {",
          "    mavenCentral()",
          "}",
          "",
          "dependencies {",
          '    testImplementation(kotlin("test"))',
          "}",
          "",
          "kotlin {",
          "    jvmToolchain(21)",
          "}",
          "",
          "application {",
          ('    mainClass.set("%s.MainKt")'):format(pkg),
          "}",
          "",
          "tasks.test {",
          "    useJUnitPlatform()",
          "}",
          "",
        })
        S.write_file(ctx.dest .. "/src/main/kotlin/" .. pkg_path .. "/Main.kt", {
          "package " .. pkg,
          "",
          "fun main() {",
          '    println("hello")',
          "}",
          "",
        })
        S.write_file(ctx.dest .. "/src/test/kotlin/" .. pkg_path .. "/MainTest.kt", {
          "package " .. pkg,
          "",
          "import kotlin.test.Test",
          "import kotlin.test.assertTrue",
          "",
          "class MainTest {",
          "",
          "    @Test",
          "    fun todo() {",
          "        assertTrue(true)",
          "    }",
          "}",
          "",
        })
        S.write_file(ctx.dest .. "/.gitignore", {
          "build/", ".gradle/", "*.class", "out/", ".idea/",
        })
        S.run_steps({ { label = "git init", cmd = { "git", "init", "-q" } } }, ctx.dest, done)
      end,
    },
  },
}
