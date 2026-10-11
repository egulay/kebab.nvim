-- Python, including the PySpark work this layer was built for.
local S = require("kebab.scaffold")

local PY_DEPS = {
  prompt = "Package to add (python): ",
  command = function(package, opts)
    local dir = opts and opts.dir
    -- `uv add` requires a pyproject.toml and exits 2 without one, so a
    -- requirements.txt-only project (the usual shape for PySpark work) has to
    -- go through pip -- the directory is already in hand for the venv below.
    local has_pyproject = dir ~= nil and vim.uv.fs_stat(dir .. "/pyproject.toml") ~= nil
    -- uv is much faster and writes pyproject.toml itself; pip does neither.
    if vim.fn.executable("uv") == 1 and (has_pyproject or dir == nil) then
      local cmd = { "uv", "add" }
      if opts and opts.dev then
        table.insert(cmd, "--dev")
      end
      table.insert(cmd, package)
      return cmd
    end
    local venv = opts and opts.dir and (opts.dir .. "/.venv/bin/python")
    local python = (venv and vim.uv.fs_stat(venv)) and venv
      or (vim.fn.executable("python3") == 1 and "python3" or "python")
    return { python, "-m", "pip", "install", package }
  end,
}

return {
  key = "python",
  label = "Python",
  kind = "python",
  filetypes = { "python" },

  markers = {
    { file = "pyproject.toml", kind = "python", deps = PY_DEPS },
    { file = "requirements.txt", kind = "python", deps = PY_DEPS },
  },

  extras = { "lazyvim.plugins.extras.lang.python" },
  tools = { "basedpyright", "ruff", "debugpy" },

  tasks = {
    {
      name = "python: run current file",
      cmd = { vim.fn.exepath("python3") ~= "" and "python3" or "python" },
      args = { "%:p" },
      desc = "Run the file in the current buffer",
      filetypes = { "python" },
    },
    {
      name = "python: pytest",
      cmd = { "python3" },
      args = { "-m", "pytest" },
      desc = "Run pytest in the project root",
      marker = { "pyproject.toml", "requirements.txt" },
    },
  },

  templates = {
    {
      name = "Python module",
      extension = "py",
      prompt = "Module name",
      filetypes = { "python" },
      render = function(ctx)
        return { ('"""%s."""'):format(ctx.name), "" }
      end,
    },
    {
      name = "pytest test module",
      extension = "py",
      prompt = "Test module name",
      filetypes = { "python" },
      default_name = function(current)
        if current == nil or current == "" then
          return nil
        end
        return current:match("^test_") and current or ("test_" .. current)
      end,
      render = function(ctx)
        return {
          ('"""Tests for %s."""'):format((ctx.name:gsub("^test_", ""))),
          "",
          "",
          "def test_todo() -> None:",
          "    assert True",
          "",
        }
      end,
    },
  },

  scratch = {
    {
      key = "py",
      name = "Python",
      extension = "py",
      filetype = "python",
      lines = { '"""Scratch."""', "", 'print("hello")' },
    },
  },

  project_files = {
    {
      name = ".gitignore (Python)",
      file = ".gitignore",
      kinds = { "python" },
      lines = {
        ".venv/", "venv/", "__pycache__/", "*.py[cod]",
        ".pytest_cache/", ".ruff_cache/", ".mypy_cache/",
        "dist/", "build/", "*.egg-info/",
        "", "# local config", ".env",
      },
    },
    {
      name = "Dockerfile (Python)",
      file = "Dockerfile",
      kinds = { "python" },
      lines = {
        "FROM python:3.13-slim",
        "WORKDIR /app",
        "",
        "# uv resolves and installs much faster than pip, and respects the lock.",
        "COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv",
        "COPY pyproject.toml ./",
        "RUN uv pip install --system --no-cache .",
        "",
        "COPY src ./src",
        "RUN useradd --create-home app && chown -R app /app",
        "USER app",
        'CMD ["python", "-m", "src.main"]',
      },
    },
    {
      name = "GitHub Actions (Python)",
      file = ".github/workflows/test.yml",
      kinds = { "python" },
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
        "      - uses: astral-sh/setup-uv@v5",
        "      - run: uv sync --all-extras --dev",
        "      - run: uv run ruff check .",
        "      - run: uv run pytest",
      },
    },
  },

  project_types = {
    {
      key = "python",
      label = "Python (venv + pyproject)",
      requires = { "git", "python3" },
      build = function(ctx, done)
        S.mkdir(ctx.dest .. "/src")
        S.write_file(ctx.dest .. "/src/main.py", {
          "def main() -> None:",
          '    print("hello")',
          "",
          "",
          'if __name__ == "__main__":',
          "    main()",
        })
        S.write_file(ctx.dest .. "/pyproject.toml", {
          "[project]",
          ('name = "%s"'):format(S.sanitise(ctx.name, "plain")),
          'version = "0.1.0"',
          'requires-python = ">=3.11"',
          "dependencies = []",
        })
        S.write_file(ctx.dest .. "/.gitignore", { ".venv/", "__pycache__/", "*.pyc", ".ruff_cache/" })
        S.run_steps({
          { label = "git init", cmd = { "git", "init", "-q" } },
          { label = "creating .venv", cmd = { "python3", "-m", "venv", ".venv" } },
        }, ctx.dest, done)
      end,
    },
  },
}
