-- Java: Maven and Gradle, with Spring Boot as the framework that matters here.
local S = require("kebab.scaffold")

return {
  key = "java",
  label = "Java",
  kind = "maven",
  filetypes = { "java", "jproperties" },

  markers = {
    {
      file = "pom.xml",
      kind = "maven",
      deps = {
        file = "pom.xml",
        prompt = "Dependency (group:artifact[:version], or a Spring starter name): ",
        -- Maven has no command that adds a dependency, so the pom is edited.
        edit = function(marker_path, input, opts)
          local maven = require("kebab.maven")
          local dep, err = maven.parse_coordinate(input)
          if not dep then
            return false, err
          end
          -- Maven has no dev/prod split; <scope>test</scope> is the equivalent.
          if opts and opts.dev and not dep.scope then
            dep.scope = "test"
          end
          local ok, perr = maven.add_to_file(marker_path, dep)
          if not ok then
            return false, perr
          end
          return true, ("Added %s:%s to pom.xml"):format(dep.group, dep.artifact)
        end,
      },
    },
    {
      file = "build.gradle.kts",
      kind = "gradle",
      deps = {
        file = "build.gradle.kts",
        prompt = "Dependency (group:artifact[:version], or a Spring starter name): ",
        -- Gradle has no add-a-dependency command either, so the build file is
        -- edited; see kebab/gradle.lua.
        edit = function(marker_path, input, opts)
          return require("kebab.gradle").add_to_file(marker_path, input, opts)
        end,
      },
    },
    {
      file = "build.gradle",
      kind = "gradle",
      deps = {
        file = "build.gradle",
        prompt = "Dependency (group:artifact[:version], or a Spring starter name): ",
        -- Gradle has no add-a-dependency command either, so the build file is
        -- edited; see kebab/gradle.lua.
        edit = function(marker_path, input, opts)
          return require("kebab.gradle").add_to_file(marker_path, input, opts)
        end,
      },
    },
  },

  extras = { "lazyvim.plugins.extras.lang.java" },
  tools = { "jdtls", "java-debug-adapter", "java-test", "vscode-spring-boot-tools" },

  -- `cmd` is a function because a project that ships ./mvnw should be built
  -- with it rather than with whatever mvn happens to be on PATH, and that is
  -- only knowable when the task runs.
  tasks = (function()
    local function mvn()
      return { vim.fn.executable("./mvnw") == 1 and "./mvnw" or "mvn" }
    end
    return {
      { name = "maven: spring-boot:run", cmd = mvn, args = { "spring-boot:run" }, desc = "Run the Spring Boot app", marker = "pom.xml" },
      { name = "maven: test", cmd = mvn, args = { "test" }, desc = "Run all tests", marker = "pom.xml" },
      { name = "maven: package -DskipTests", cmd = mvn, args = { "package", "-DskipTests" }, desc = "Build the jar", marker = "pom.xml" },
      { name = "maven: clean install", cmd = mvn, args = { "clean", "install" }, desc = "Clean build and install", marker = "pom.xml" },
    }
  end)(),

  -- The Generate menu a graphical IDE has. jdtls implements these as LSP
  -- *source* code actions; naming them here is what lifts them out of the
  -- undifferentiated <leader>ca list.
  --
  -- The kinds are dot-separated ("source.generate.toString"), NOT the camelCase
  -- names that appear as field names inside the jdt.ls jars. Guessing from
  -- those gave six dead entries. This list was read back off a live server --
  -- re-derive it the same way if jdtls changes:
  --
  --   params.context = { diagnostics = {}, only = { "source" } }
  --   client:request("textDocument/codeAction", params, cb, bufnr)
  --
  -- with the cursor on a class name in a fully imported Maven project. Before
  -- the import finishes, only organizeImports and overrideMethods are offered,
  -- which is a misleading moment to check.
  codegen = {
    { name = "Constructor...", kind = "source.generate.constructors", filetypes = { "java" } },
    -- one kind, three server-side variants: getters and setters, getters only,
    -- setters only. The picker offers the choice.
    { name = "Getters and Setters...", kind = "source.generate.accessors", filetypes = { "java" } },
    { name = "toString()...", kind = "source.generate.toString", filetypes = { "java" } },
    { name = "equals() and hashCode()...", kind = "source.generate.hashCodeEquals", filetypes = { "java" } },
    { name = "Override/Implement Methods...", kind = "source.overrideMethods", filetypes = { "java" } },
    { name = "Delegate Methods...", kind = "source.generate.delegateMethods", filetypes = { "java" } },
    { name = "Organize Imports", kind = "source.organizeImports", filetypes = { "java" } },
  },

  -- The package line comes from the directory, which is the part of "New Java
  -- class" worth having: typing `package com.example.thing.service;` by hand is
  -- tedious and is what you get wrong after moving a file.
  templates = (function()
    local function package_line(ctx)
      if ctx.package == "" then
        return {}
      end
      return { "package " .. ctx.package .. ";", "" }
    end
    local function body(ctx, decl)
      local lines = package_line(ctx)
      vim.list_extend(lines, { decl:format(ctx.name), "}", "" })
      return lines
    end
    return {
      {
        name = "Java class",
        extension = "java",
        prompt = "Class name",
        filetypes = { "java" },
        render = function(ctx) return body(ctx, "public class %s {") end,
      },
      {
        name = "Java interface",
        extension = "java",
        prompt = "Interface name",
        filetypes = { "java" },
        render = function(ctx) return body(ctx, "public interface %s {") end,
      },
      {
        name = "Java record",
        extension = "java",
        prompt = "Record name",
        filetypes = { "java" },
        render = function(ctx)
          local lines = package_line(ctx)
          vim.list_extend(lines, { ("public record %s() {"):format(ctx.name), "}", "" })
          return lines
        end,
      },
      {
        name = "Java enum",
        extension = "java",
        prompt = "Enum name",
        filetypes = { "java" },
        render = function(ctx) return body(ctx, "public enum %s {") end,
      },
      {
        name = "Java abstract class",
        extension = "java",
        prompt = "Class name",
        filetypes = { "java" },
        render = function(ctx) return body(ctx, "public abstract class %s {") end,
      },
      {
        -- The backlog's "test class for the file you are on": written under
        -- src/test/java with the same package, named after the current file.
        name = "JUnit 5 test class",
        extension = "java",
        prompt = "Test class name",
        filetypes = { "java" },
        target_dir = function(dir) return require("kebab.templates").test_dir_for(dir) end,
        default_name = function(current)
          if current == nil or current == "" then
            return nil
          end
          return current:match("Test$") and current or (current .. "Test")
        end,
        render = function(ctx)
          local lines = package_line(ctx)
          vim.list_extend(lines, {
            "import org.junit.jupiter.api.Test;",
            "",
            "import static org.assertj.core.api.Assertions.assertThat;",
            "",
            ("class %s {"):format(ctx.name),
            "",
            "    @Test",
            "    void todo() {",
            "        assertThat(true).isTrue();",
            "    }",
            "}",
            "",
          })
          return lines
        end,
      },
      {
        name = "Spring @RestController",
        extension = "java",
        prompt = "Controller name",
        filetypes = { "java" },
        render = function(ctx)
          local lines = package_line(ctx)
          vim.list_extend(lines, {
            "import org.springframework.web.bind.annotation.GetMapping;",
            "import org.springframework.web.bind.annotation.RequestMapping;",
            "import org.springframework.web.bind.annotation.RestController;",
            "",
            "@RestController",
            '@RequestMapping("/api")',
            ("public class %s {"):format(ctx.name),
            "",
            '    @GetMapping("/hello")',
            "    public String hello() {",
            '        return "hello";',
            "    }",
            "}",
            "",
          })
          return lines
        end,
      },
      {
        name = "Spring @Service",
        extension = "java",
        prompt = "Service name",
        filetypes = { "java" },
        render = function(ctx)
          local lines = package_line(ctx)
          vim.list_extend(lines, {
            "import org.springframework.stereotype.Service;",
            "",
            "@Service",
            ("public class %s {"):format(ctx.name),
            "}",
            "",
          })
          return lines
        end,
      },
    }
  end)(),

  -- A single-file Java program, which Java 21 can run directly:
  -- `java scratch-1.java`, no project needed.
  scratch = {
    {
      key = "java",
      name = "Java (single file)",
      extension = "java",
      filetype = "java",
      -- `scratch-1.java` cannot hold a public class: javac wants the file named
      -- after it, so the buffer opened with a permanent error.
      stem = "Scratch%d",
      render = function(ctx)
        -- the public class has to match the file name
        local class = (ctx.name:gsub("[^%w]", "_"))
        return {
          ("public class %s {"):format(class),
          "    public static void main(String[] args) {",
          '        System.out.println("hello");',
          "    }",
          "}",
        }
      end,
    },
  },

  project_files = {
    {
      name = ".gitignore (Java/Maven)",
      file = ".gitignore",
      kinds = { "maven", "gradle" },
      lines = {
        -- the negations have to come AFTER *.jar: git applies the last
        -- matching pattern, so with them first the wrapper jars stay ignored
        -- and ./mvnw or ./gradlew fails on a fresh clone
        "target/", "build/",
        "*.class", "*.jar", "*.war",
        "!.mvn/wrapper/maven-wrapper.jar",
        "!gradle/wrapper/gradle-wrapper.jar",
        "", "# IDE", ".idea/", "*.iml", ".classpath", ".project", ".settings/",
        "", "# local config", "application-local.properties", "application-local.yml", ".env",
      },
    },
    {
      name = "Dockerfile (Spring Boot, multi-stage)",
      file = "Dockerfile",
      kinds = { "maven" },
      render = function(ctx)
        return {
          "# Build with the wrapper so CI matches local builds.",
          "FROM maven:3.9-eclipse-temurin-21 AS build",
          "WORKDIR /app",
          "COPY .mvn/ .mvn/",
          "COPY mvnw pom.xml ./",
          "RUN ./mvnw -B dependency:go-offline",
          "COPY src ./src",
          "RUN ./mvnw -B -DskipTests package",
          "",
          "FROM eclipse-temurin:21-jre-alpine",
          "WORKDIR /app",
          "RUN addgroup -S app && adduser -S app -G app",
          "USER app",
          "COPY --from=build /app/target/*.jar app.jar",
          "EXPOSE 8080",
          ('LABEL org.opencontainers.image.title="%s"'):format(ctx.project),
          'ENTRYPOINT ["java", "-jar", "/app/app.jar"]',
        }
      end,
    },
    {
      name = "GitHub Actions (Maven)",
      file = ".github/workflows/build.yml",
      kinds = { "maven" },
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
        '          distribution: temurin',
        '          java-version: "21"',
        "          cache: maven",
        "      - run: ./mvnw -B verify",
      },
    },
  },

  project_types = {
    {
      key = "spring",
      label = "Spring Boot (Maven, Java 21)",
      requires = { "curl", "unzip" },
      network = true,
      prompts = {
        { name = "group", prompt = "Group id: ", default = "com.example" },
        { name = "deps", prompt = "Dependencies (comma separated): ", default = "web" },
      },
      build = function(ctx, done)
        local deps = ctx.answers.deps
        if deps == nil or deps == "" then
          deps = "web"
        end
        local zip = vim.fn.tempname() .. ".zip"
        local artifact = S.sanitise(ctx.name, "kebab")
        local pkg = (ctx.answers.group .. "." .. artifact:gsub("[^%w]", "")):lower()
        S.mkdir(ctx.dest)
        S.run_steps({
          {
            label = "fetching from start.spring.io",
            cmd = {
              "curl", "-fsSL", "https://start.spring.io/starter.zip",
              "-d", "type=maven-project", "-d", "language=java",
              "-d", "javaVersion=21", "-d", "groupId=" .. ctx.answers.group,
              "-d", "artifactId=" .. artifact, "-d", "name=" .. artifact,
              "-d", "packageName=" .. pkg,
              "-d", "dependencies=" .. deps,
              "-o", zip,
            },
          },
          { label = "unpacking", cmd = { "unzip", "-q", "-o", zip, "-d", ctx.dest } },
        }, ctx.dest, done)
      end,
    },
    {
      key = "maven",
      label = "Maven (plain Java 21)",
      requires = { "mvn" },
      network = true,
      prompts = {
        { name = "group", prompt = "Group id: ", default = "com.example" },
      },
      build = function(ctx, done)
        local artifact = S.sanitise(ctx.name, "kebab")
        local parent = S.parent_of(ctx.dest)
        S.mkdir(parent)
        S.run_steps({
          {
            label = "mvn archetype:generate",
            cmd = {
              "mvn", "-q", "-B", "archetype:generate",
              "-DgroupId=" .. ctx.answers.group,
              "-DartifactId=" .. artifact,
              "-DarchetypeArtifactId=maven-archetype-quickstart",
              "-DarchetypeVersion=1.5",
              "-DinteractiveMode=false",
            },
            cwd = parent,
          },
        }, parent, function(ok, err)
          -- the archetype creates <parent>/<artifact>; move it if the chosen
          -- destination name differs from the sanitised artifact id
          if ok and artifact ~= S.leaf_of(ctx.dest) then
            os.rename(parent .. "/" .. artifact, ctx.dest)
          end
          done(ok, err)
        end)
      end,
    },
  },
}
