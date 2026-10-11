-- Go.
local S = require("kebab.scaffold")

return {
  key = "go",
  label = "Go",
  kind = "go",
  filetypes = { "go", "gomod", "gowork", "gotmpl" },

  markers = {
    {
      file = "go.mod",
      kind = "go",
      deps = {
        prompt = "Module to add (e.g. github.com/go-chi/chi/v5): ",
        -- `go get` downloads it and records the requirement in go.mod, marked
        -- `// indirect` until something imports it.
        --
        -- Deliberately NOT followed by `go mod tidy`. Tidy removes any
        -- requirement no package imports, so running it straight after the add
        -- deletes the dependency you just asked for -- verified: go.sum gets
        -- written and go.mod comes back unchanged. The "go: mod tidy" task is
        -- there for when you have written the import.
        command = function(package)
          return { "go", "get", package }
        end,
      },
    },
  },

  extras = { "lazyvim.plugins.extras.lang.go" },
  -- gopls and delve come from the extra's own mason list; these are the ones it
  -- does not pull in.
  tools = { "gopls", "delve", "gofumpt", "goimports", "gomodifytags", "impl" },

  tasks = {
    { name = "go: run", cmd = { "go" }, args = { "run", "." }, desc = "Run the package in the project root", marker = "go.mod" },
    { name = "go: test ./...", cmd = { "go" }, args = { "test", "./..." }, desc = "Run all tests", marker = "go.mod" },
    { name = "go: test -v ./...", cmd = { "go" }, args = { "test", "-v", "./..." }, desc = "Run all tests, verbose", marker = "go.mod" },
    { name = "go: build", cmd = { "go" }, args = { "build", "./..." }, desc = "Build everything", marker = "go.mod" },
    { name = "go: vet", cmd = { "go" }, args = { "vet", "./..." }, desc = "Static analysis", marker = "go.mod" },
    { name = "go: mod tidy", cmd = { "go" }, args = { "mod", "tidy" }, desc = "Tidy go.mod", marker = "go.mod" },
  },

  templates = {
    {
      name = "Go file",
      extension = "go",
      prompt = "File name",
      filetypes = { "go" },
      render = function(ctx)
        return { "package " .. S.go_package(ctx.dir), "" }
      end,
    },
    {
      name = "Go test file",
      extension = "go",
      prompt = "Test file name",
      filetypes = { "go" },
      default_name = function(current)
        if current == nil or current == "" then
          return nil
        end
        return current:match("_test$") and current or (current .. "_test")
      end,
      render = function(ctx)
        return {
          "package " .. S.go_package(ctx.dir),
          "",
          'import "testing"',
          "",
          "func TestTodo(t *testing.T) {",
          "\tt.Parallel()",
          "}",
          "",
        }
      end,
    },
  },

  scratch = {
    {
      key = "go",
      name = "Go",
      extension = "go",
      filetype = "go",
      lines = {
        "package main",
        "",
        'import "fmt"',
        "",
        "func main() {",
        '\tfmt.Println("hello")',
        "}",
      },
    },
  },

  project_files = {
    {
      name = ".gitignore (Go)",
      file = ".gitignore",
      kinds = { "go" },
      lines = { "/bin/", "/dist/", "*.test", "*.out", "coverage.*", "", "# local config", ".env" },
    },
    {
      name = "Dockerfile (Go, static binary)",
      file = "Dockerfile",
      kinds = { "go" },
      render = function(ctx)
        return {
          "FROM golang:1.23-alpine AS build",
          "WORKDIR /src",
          "COPY go.mod go.sum* ./",
          "RUN go mod download",
          "COPY . .",
          "# CGO off gives a static binary, so the final image can be scratch.",
          "RUN CGO_ENABLED=0 go build -ldflags='-s -w' -o /out/app .",
          "",
          "FROM gcr.io/distroless/static:nonroot",
          ('LABEL org.opencontainers.image.title="%s"'):format(ctx.project),
          "COPY --from=build /out/app /app",
          "USER nonroot:nonroot",
          'ENTRYPOINT ["/app"]',
        }
      end,
    },
    {
      name = "GitHub Actions (Go)",
      file = ".github/workflows/test.yml",
      kinds = { "go" },
      lines = {
        "name: test",
        "",
        "on:",
        "  push:",
        "    branches: [main]",
        "  pull_request:",
        "",
        "jobs:",
        "  test:",
        "    runs-on: ubuntu-latest",
        "    steps:",
        "      - uses: actions/checkout@v4",
        "      - uses: actions/setup-go@v5",
        "        with:",
        '          go-version: "1.23"',
        "      - run: go vet ./...",
        "      - run: go test -race ./...",
      },
    },
  },

  project_types = {
    {
      key = "go",
      label = "Go module",
      requires = { "go", "git" },
      prompts = {
        {
          name = "module",
          prompt = "Module path (e.g. github.com/you/thing): ",
          default = "",
        },
      },
      build = function(ctx, done)
        -- A module path is what `go mod init` wants; fall back to the bare
        -- project name, which is valid for something that is never published.
        local module = ctx.answers.module
        if module == nil or module == "" then
          module = S.sanitise(ctx.name, "kebab")
        end
        S.mkdir(ctx.dest)
        S.write_file(ctx.dest .. "/main.go", {
          "package main",
          "",
          'import "fmt"',
          "",
          "func main() {",
          '\tfmt.Println("hello")',
          "}",
        })
        S.write_file(ctx.dest .. "/.gitignore", { "/bin/", "*.test", "*.out" })
        S.run_steps({
          { label = "go mod init", cmd = { "go", "mod", "init", module } },
          { label = "git init", cmd = { "git", "init", "-q" } },
        }, ctx.dest, done)
      end,
    },
  },
}
