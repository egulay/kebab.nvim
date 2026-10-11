-- Proves the harness itself works and the layer is loaded, so a failure in any
-- other spec means that spec's subject is broken rather than the environment.
local H = ...

H.describe("environment", function()
  H.it("runs a real Neovim with the user config", function()
    H.ok(package.loaded["lazy"], "lazy.nvim should be loaded")
    H.ok(_G.LazyVim, "LazyVim global should exist")
  end)

  H.it("is not sitting in the project directory", function()
    H.falsy(vim.fn.getcwd():match("kebab%.nvim$"), "cwd must be a sandbox, not the repo")
  end)

  H.it("has the kebab layer on the runtimepath", function()
    H.ok(#vim.api.nvim_get_runtime_file("lua/kebab/project.lua", false) > 0,
      "lua/kebab/project.lua should be findable")
  end)

  H.it("registers the project commands", function()
    H.eq(2, vim.fn.exists(":IdeNewProject"))
    H.eq(2, vim.fn.exists(":IdeOpenProject"))
    H.eq(2, vim.fn.exists(":IdeInitHere"))
  end)
end)

H.describe("harness", function()
  H.it("captures notifications", function()
    local got = H.capture_notify(function()
      vim.notify("hello world", vim.log.levels.WARN)
    end)
    H.eq(1, #got)
    H.ok(H.notified(got, "hello"), "should find the message")
    H.eq(vim.log.levels.WARN, got[1].level)
  end)

  H.it("scripts vim.ui.select by index, label and predicate", function()
    local picked = {}
    H.with_ui({ 2, "beta", function(items) return items[3] end }, function()
      for _ = 1, 3 do
        vim.ui.select({ "alpha", "beta", "gamma" }, {}, function(c) picked[#picked + 1] = c end)
      end
    end)
    H.eq({ "beta", "beta", "gamma" }, picked)
  end)

  H.it("scripts vim.ui.input and models cancellation", function()
    local got = {}
    H.with_ui({ "typed", H.CANCEL, H.DEFAULT }, function()
      vim.ui.input({ prompt = "a" }, function(v) got[#got + 1] = v or "<nil>" end)
      vim.ui.input({ prompt = "b" }, function(v) got[#got + 1] = v or "<nil>" end)
      vim.ui.input({ prompt = "c", default = "dflt" }, function(v) got[#got + 1] = v or "<nil>" end)
    end)
    H.eq({ "typed", "<nil>", "dflt" }, got)
  end)

  H.it("restores vim.ui even when the body errors", function()
    local before = vim.ui.select
    pcall(H.with_ui, { 1 }, function() error("boom") end)
    H.eq(before, vim.ui.select, "vim.ui.select must be restored")
  end)

  H.it("builds a git repo with a HEAD commit", function()
    local dir, git = H.git_repo("smoke")
    H.ok(H.exists(dir .. "/.git"), ".git should exist")
    H.matches("initial", git("log", "--oneline"))
    H.eq("", vim.trim(git("status", "--porcelain")), "repo should be clean")
  end)
end)
