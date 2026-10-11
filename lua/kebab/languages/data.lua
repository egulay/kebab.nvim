-- The formats every project carries: config, data, docs, SQL, and the shell and
-- Lua that glue them together. No project types -- nobody starts a project
-- because it has YAML in it -- but the language servers and formatters have to
-- come from somewhere, and that somewhere should not be a hardcoded list in
-- plugins/mason.lua.
return {
  key = "data",
  label = "Config / data / docs",
  kind = "dir",
  filetypes = {
    "json", "jsonc", "yaml", "toml", "markdown", "sql", "lua", "sh", "bash",
    "dockerfile", "gitcommit", "gitignore",
  },

  markers = {},

  extras = {
    "lazyvim.plugins.extras.lang.docker",
    "lazyvim.plugins.extras.lang.git",
    "lazyvim.plugins.extras.lang.json",
    "lazyvim.plugins.extras.lang.markdown",
    "lazyvim.plugins.extras.lang.sql",
    "lazyvim.plugins.extras.lang.toml",
    "lazyvim.plugins.extras.lang.yaml",
  },

  -- Scratch kinds. `.http` is the one this layer was missing most: kulala is
  -- already installed, but there was nowhere to put a request that is not part
  -- of a project.
  scratch = {
    {
      key = "http",
      name = "HTTP request",
      extension = "http",
      filetype = "http",
      lines = {
        "# <leader>Rs sends the request under the cursor (kulala)",
        "",
        "GET https://httpbin.org/get",
        "Accept: application/json",
        "",
        "###",
        "",
        "# POST https://httpbin.org/post",
        "# Content-Type: application/json",
        "#",
        '# { "hello": "world" }',
      },
    },
    {
      key = "sql",
      name = "SQL query",
      extension = "sql",
      filetype = "sql",
      lines = {
        "-- :DBUIToggle picks a connection (vim-dadbod-ui)",
        "",
        "select 1;",
      },
    },
    { key = "json", name = "JSON", extension = "json", filetype = "json", lines = { "{", '  "": ""', "}" } },
    { key = "yaml", name = "YAML", extension = "yaml", filetype = "yaml", lines = { "key: value" } },
    { key = "md", name = "Markdown note", extension = "md", filetype = "markdown", lines = { "# Note", "" } },
    { key = "sh", name = "Shell script", extension = "sh", filetype = "sh", lines = { "#!/usr/bin/env bash", "set -euo pipefail", "" } },
    { key = "lua", name = "Lua", extension = "lua", filetype = "lua", lines = { "-- :luafile % runs this", "", 'print("hello")' } },
  },

  tools = {
    "json-lsp", "yaml-language-server", "taplo",
    "dockerfile-language-server", "docker-compose-language-service", "hadolint",
    "marksman", "markdownlint-cli2", "markdown-toc", "sqlfluff",
    "stylua", "shfmt",
  },
}
