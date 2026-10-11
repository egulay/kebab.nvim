-- The layer's own configuration contract: that its specs reach the plugins they
-- are meant to configure, in the order that makes its overrides win.
local H = ...

local function modules()
  return require("lazy.core.config").spec.modules
end

local function index_of(pattern, last)
  local mods = modules()
  local found
  for i = 1, #mods do
    if mods[i]:find(pattern) then
      found = i
      if not last then return i end
    end
  end
  return found
end

H.describe("lazy import order", function()
  H.it("imports lazyvim.plugins first", function()
    H.eq(1, index_of("^lazyvim%.plugins$"))
  end)

  H.it("imports every extra this layer declares", function()
    local declared = {}
    for _, spec in ipairs(dofile(_G.KEBAB_TEST.root .. "/lua/kebab/plugins/extras.lua")) do
      if spec.import then declared[#declared + 1] = spec.import end
    end
    H.ok(#declared >= 20, "expected 20+ extras, found " .. #declared)
    local mods = modules()
    for _, name in ipairs(declared) do
      H.ok(vim.tbl_contains(mods, name), name .. " should have been imported")
    end
  end)

  H.it("sorts extras.lua before the specs that override those extras", function()
    -- This is what LazyVim's order check is really protecting, and the reason
    -- vim.g.lazyvim_check_order is set to false in extras.lua. lazy.nvim
    -- imports a directory's files in sorted order, so `extras.lua` being first
    -- alphabetically is what makes the layer's java/flutter/python tuning merge
    -- on top of the stock extras instead of under them. If a file ever sorted
    -- before it -- anything starting a-d -- those overrides would be lost.
    local dir = _G.KEBAB_TEST.root .. "/lua/kebab/plugins"
    local files = vim.fn.readdir(dir)
    table.sort(files)
    H.eq("extras.lua", files[1],
      "extras.lua must sort first in lua/kebab/plugins; got " .. vim.inspect(files))
  end)

  H.it("keeps the layer's overrides in the merged options", function()
    -- The outcome the ordering exists for, checked directly rather than by
    -- reading import indices: lazy records a directory import as one module, so
    -- the per-file order is not observable, but its result is.
    local function opts(plugin)
      local spec = require("lazy.core.config").plugins[plugin]
      H.ok(spec, plugin .. " should be a known plugin")
      return require("lazy.core.plugin").values(spec, "opts", false)
    end

    H.eq("automatic", vim.tbl_get(opts("nvim-jdtls"), "settings", "java", "configuration", "updateBuildConfiguration"),
      "the layer's jdtls tuning should survive the stock java extra")
    H.eq(true, vim.tbl_get(opts("nvim-jdtls"), "settings", "java", "referencesCodeLens", "enabled"))
    H.eq("git_add_file", vim.tbl_get(opts("neo-tree.nvim"), "window", "mappings", "ga"),
      "the layer's tree mappings should survive the stock neo-tree extra")
    H.eq(32, vim.tbl_get(opts("neo-tree.nvim"), "window", "width"))
  end)

  H.it("silences LazyVim's order warning deliberately, not by accident", function()
    H.eq(false, vim.g.lazyvim_check_order,
      "extras.lua should set this, with the reason in a comment")
  end)

  H.it("does not emit the order warning at startup", function()
    for _, n in ipairs(H.startup_notifications) do
      H.falsy(n.msg:match("order of your `lazy%.nvim` imports"),
        "LazyVim's order warning should not reach the user: " .. n.msg)
    end
  end)
end)

H.describe("a quiet startup", function()
  H.it("produces no warnings at all", function()
    -- Anything that warns on every start trains you to ignore warnings, so the
    -- bar is zero. This caught plugins/run.lua calling the deprecated
    -- dap.ext.vscode.load_launchjs, which warned on each launch.
    local warnings = {}
    for _, n in ipairs(H.startup_notifications) do
      if (n.level or 0) >= vim.log.levels.WARN then
        warnings[#warnings + 1] = n.msg
      end
    end
    H.eq({}, warnings, "startup should be silent")
  end)

  H.it("does not call deprecated dap APIs", function()
    local source = table.concat(vim.fn.readfile(_G.KEBAB_TEST.root .. "/lua/kebab/plugins/run.lua"), "\n")
    -- A *call*, not a mention: the comment explaining why it was removed names
    -- it, and should be allowed to.
    H.falsy(source:match("load_launchjs%s*%("),
      "nvim-dap reads .vscode/launch.json itself; load_launchjs is deprecated")
  end)

  H.it("still picks up a project's launch.json through dap's own provider", function()
    require("lazy").load({ plugins = { "nvim-dap" } })
    local dap = require("dap")
    H.ok(dap.providers and dap.providers.configs, "dap should expose config providers")
    H.ok(dap.providers.configs["dap.launch.json"],
      "dap's launch.json provider is what replaces the removed call")
  end)
end)

H.describe("language server choices", function()
  H.it("uses basedpyright rather than letting LazyVim disable it", function()
    -- LazyVim defaults vim.g.lazyvim_python_lsp to "pyright", which *disables*
    -- basedpyright. Setting it is the whole reason extras.lua runs code.
    H.eq("basedpyright", vim.g.lazyvim_python_lsp)
    H.eq("ruff", vim.g.lazyvim_python_ruff)
  end)

  H.it("disables the lspconfig dartls so flutter-tools owns it alone", function()
    -- Two dartls clients on one buffer is the failure this prevents.
    local spec = require("lazy.core.config").plugins["nvim-lspconfig"]
    H.ok(spec, "nvim-lspconfig should be a known plugin")
    local opts = require("lazy.core.plugin").values(spec, "opts", false)
    H.eq(false, vim.tbl_get(opts, "servers", "dartls", "enabled"),
      "dartls must be disabled in lspconfig")
  end)

  H.it("turns on blink signature help, which LazyVim ships off", function()
    local spec = require("lazy.core.config").plugins["blink.cmp"]
    H.ok(spec, "blink.cmp should be a known plugin")
    local opts = require("lazy.core.plugin").values(spec, "opts", false)
    H.eq(true, vim.tbl_get(opts, "signature", "enabled"))
  end)
end)

H.describe("flutter command triggers", function()
  H.it("declares cmd triggers so the Flutter menu works outside a Dart buffer", function()
    local spec = require("lazy.core.config").plugins["flutter-tools.nvim"]
    H.ok(spec, "flutter-tools.nvim should be a known plugin")
    local cmds = spec.cmd or {}
    for _, name in ipairs({ "FlutterRun", "FlutterReload", "FlutterRestart", "FlutterQuit",
      "FlutterDevices", "FlutterEmulators", "FlutterLogToggle", "FlutterPubGet", "FlutterOutlineToggle" }) do
      H.ok(vim.tbl_contains(cmds, name), name .. " should be a lazy cmd trigger")
    end
  end)

  H.it("still loads on dart files", function()
    local spec = require("lazy.core.config").plugins["flutter-tools.nvim"]
    H.ok(vim.tbl_contains(spec.ft or {}, "dart"), "ft = dart should be kept")
  end)

  H.it("every declared trigger is a command flutter-tools really defines", function()
    -- A trigger for a command that does not exist would load the plugin and
    -- then still fail with E492.
    local spec = require("lazy.core.config").plugins["flutter-tools.nvim"]
    local source = table.concat(vim.fn.readfile(spec.dir .. "/lua/flutter-tools.lua"), "\n")
    for _, name in ipairs(spec.cmd or {}) do
      H.matches('command%("' .. name .. '"', source, name .. " should be defined by flutter-tools")
    end
  end)
end)

H.describe("aerial command triggers", function()
  H.it("declares cmd triggers so File Structure works from the dashboard", function()
    local spec = require("lazy.core.config").plugins["aerial.nvim"]
    H.ok(spec, "aerial.nvim should be a known plugin")
    H.ok(vim.tbl_contains(spec.cmd or {}, "AerialToggle"), "AerialToggle should be a cmd trigger")
  end)
end)

H.describe("the .http client", function()
  local function kulala_opts()
    local spec = require("lazy.core.config").plugins["kulala.nvim"]
    H.ok(spec, "kulala.nvim should be a known plugin")
    return require("lazy.core.plugin").values(spec, "opts", false)
  end

  H.it("does not prompt for a licence token on every .http buffer", function()
    -- kulala's LSP backend downloads "kulala-core" and asks for a paid token
    -- with vim.fn.inputsecret, which blocks a headless session outright and
    -- interactively turns the layer's advertised .http support into a paywall.
    -- Sending requests does not need it.
    local token = (vim.env.KULALA_CORE_LICENSE_TOKEN or "") ~= ""
      or (vim.uv.fs_stat(vim.fn.stdpath("data") .. "/kulala.nvim/license-token") ~= nil)
    if token then
      H.skip("a licence token is present, so the backend is enabled on purpose")
    end
    H.eq(false, vim.tbl_get(kulala_opts(), "lsp", "enable"),
      "the licensed backend should stay off without a token")
  end)

  H.it("still binds the keys that send a request", function()
    local spec = require("lazy.core.config").plugins["kulala.nvim"]
    local lhs = vim.tbl_map(function(k) return k[1] end, spec.keys or {})
    H.ok(vim.tbl_contains(lhs, "<leader>Rs"), "sending a request must still be bound")
  end)
end)
