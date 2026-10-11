-- The fallbacks: a directory that is a project because it is a git repository,
-- or because some other build system left a marker, and the empty scaffold that
-- needs no language at all.
--
-- Loaded last, so every real language gets to claim a directory first -- a Rust
-- project is "rust", not "dir", even though it is also a git repository.
local S = require("kebab.scaffold")

return {
  key = "generic",
  label = "Any project",
  kind = "dir",

  markers = {
    { file = ".git", kind = "dir" },
  },

  extras = {},
  tools = {},

  -- No `kinds`, so these are offered in any project.
  project_files = {
    {
      name = ".editorconfig",
      file = ".editorconfig",
      lines = {
        "root = true",
        "",
        "[*]",
        "charset = utf-8",
        "end_of_line = lf",
        "insert_final_newline = true",
        "trim_trailing_whitespace = true",
        "indent_style = space",
        "indent_size = 2",
        "",
        "[*.{java,kt,gradle}]",
        "indent_size = 4",
        "",
        "[*.py]",
        "indent_size = 4",
        "",
        "[*.go]",
        "indent_style = tab",
        "",
        "[*.rs]",
        "indent_size = 4",
        "",
        "[*.md]",
        "trim_trailing_whitespace = false",
        "",
        "[Makefile]",
        "indent_style = tab",
      },
    },
    {
      name = "README.md",
      file = "README.md",
      render = function(ctx)
        return { "# " .. ctx.project, "", "## Getting started", "" }
      end,
    },
    {
      name = ".gitignore (editors and OS noise)",
      file = ".gitignore",
      lines = {
        "# editors", ".idea/", ".vscode/", "*.swp", "*.swo",
        "", "# OS", ".DS_Store", "Thumbs.db",
        "", "# local config", ".env",
      },
    },
  },

  project_types = {
    {
      key = "empty",
      label = "Empty (git + README)",
      requires = { "git" },
      build = function(ctx, done)
        S.mkdir(ctx.dest)
        S.write_file(ctx.dest .. "/README.md", { "# " .. ctx.name, "" })
        S.run_steps({ { label = "git init", cmd = { "git", "init", "-q" } } }, ctx.dest, done)
      end,
    },
  },
}
