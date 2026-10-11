-- Scratch files: real files outside the project, so a language server attaches
-- and they survive a restart.
local H = ...
local S = require("kebab.scratch")
local registry = require("kebab.registry")

---Point the scratch directory somewhere disposable.
local function with_scratch_dir(fn)
  local saved = vim.g.kebab_scratch_dir
  local dir = H.tmpdir("scratch-home")
  vim.g.kebab_scratch_dir = dir
  local ok, err = pcall(fn, dir)
  vim.g.kebab_scratch_dir = saved
  if not ok then error(err, 0) end
end

H.describe("scratch kinds", function()
  H.it("includes the ones the backlog asked for", function()
    local keys = vim.tbl_map(function(k) return k.key end, S.kinds())
    for _, want in ipairs({ "http", "sql" }) do
      H.ok(vim.tbl_contains(keys, want), want .. " should be a scratch kind")
    end
  end)

  H.it("includes a buffer per language", function()
    local keys = vim.tbl_map(function(k) return k.key end, S.kinds())
    for _, want in ipairs({ "java", "py", "go", "rs", "ts", "js", "lua", "sh" }) do
      H.ok(vim.tbl_contains(keys, want), want .. " should be a scratch kind")
    end
  end)

  H.it("gives every kind a key, a name and an extension", function()
    for _, k in ipairs(S.kinds()) do
      H.ok(type(k.key) == "string" and k.key ~= "", "a kind needs a key")
      H.ok(type(k.name) == "string" and k.name ~= "", k.key .. " needs a name")
      H.ok(type(k.extension) == "string" and k.extension ~= "", k.key .. " needs an extension")
      H.ok(type(k.lines) == "table" or type(k.render) == "function",
        k.key .. " needs lines or a render function")
    end
  end)

  H.it("has no duplicate keys", function()
    local seen = {}
    for _, k in ipairs(S.kinds()) do
      H.falsy(seen[k.key], "duplicate scratch kind: " .. k.key)
      seen[k.key] = true
    end
  end)

  H.it("looks a kind up by key", function()
    H.eq("http", S.kind("http").key)
    H.eq(nil, S.kind("nope"))
  end)
end)

H.describe("creating a scratch file", function()
  H.it("writes a real file outside the project", function()
    with_scratch_dir(function(dir)
      local ok, path = S.open("http", { open = false })
      H.ok(ok, tostring(path))
      H.matches(vim.pesc(dir), path, "it should live in the scratch directory")
      H.ok(H.exists(path), "the file must exist for an LSP to attach")
      H.matches("GET https://", H.read(path))
    end)
  end)

  H.it("numbers successive scratches instead of overwriting", function()
    with_scratch_dir(function()
      local _, first = S.open("sql", { open = false })
      local _, second = S.open("sql", { open = false })
      H.falsy(first == second, "the second scratch must be a new file")
      H.ok(H.exists(first) and H.exists(second))
      H.matches("scratch%-1%.sql$", first)
      H.matches("scratch%-2%.sql$", second)
    end)
  end)

  H.it("names a Java scratch class after its file, which javac requires", function()
    with_scratch_dir(function()
      local ok, path = S.open("java", { open = false })
      H.ok(ok, tostring(path))
      local stem = vim.fn.fnamemodify(path, ":t:r"):gsub("[^%w]", "_")
      H.matches("public class " .. stem .. " {", H.read(path),
        "the public class name has to match the file name")
    end)
  end)

  H.it("rejects an unknown kind, listing the real ones", function()
    with_scratch_dir(function()
      local ok, err = S.open("cobol", { open = false })
      H.falsy(ok)
      H.matches("Unknown scratch kind", err)
      H.matches("http", err, "it should list what is available")
    end)
  end)

  H.it("rejects a kind with no extension", function()
    local ok, err = S.open({ name = "broken" }, { open = false })
    H.falsy(ok)
    H.matches("needs an extension", err)
  end)

  H.it("opens the file with the right filetype", function()
    with_scratch_dir(function()
      local ok = S.open("sql")
      H.ok(ok)
      H.eq("sql", vim.bo.filetype)
      H.matches("%.sql$", vim.api.nvim_buf_get_name(0))
      vim.cmd("bwipeout!")
    end)
  end)

  H.it("creates the scratch directory if it is missing", function()
    local saved = vim.g.kebab_scratch_dir
    local dir = H.tmpdir("scratch-missing") .. "/nested/deeper"
    vim.g.kebab_scratch_dir = dir
    local ok, path = S.open("md", { open = false })
    vim.g.kebab_scratch_dir = saved
    H.ok(ok, tostring(path))
    H.ok(H.exists(path))
  end)
end)

H.describe("listing scratch files", function()
  H.it("is empty to begin with", function()
    with_scratch_dir(function()
      H.eq({}, S.list())
    end)
  end)

  H.it("lists what has been created, newest first", function()
    with_scratch_dir(function()
      S.open("sql", { open = false })
      S.open("http", { open = false })
      local files = S.list()
      H.eq(2, #files)
      for _, f in ipairs(files) do
        H.ok(H.exists(f.path))
        H.ok(type(f.name) == "string" and f.name ~= "")
      end
    end)
  end)

  H.it("says so plainly when there is nothing to open", function()
    with_scratch_dir(function()
      local notes = H.capture_notify(function() S.pick_existing() end)
      H.ok(H.notified(notes, "No scratch files yet"))
    end)
  end)

  H.it("reopens a chosen scratch", function()
    with_scratch_dir(function()
      local _, path = S.open("md", { open = false })
      H.with_ui({ 1 }, function()
        H.capture_notify(function() S.pick_existing() end)
      end)
      H.eq(vim.fn.resolve(path), vim.fn.resolve(vim.api.nvim_buf_get_name(0)))
      vim.cmd("bwipeout!")
    end)
  end)
end)

H.describe("the scratch picker", function()
  H.it("offers every kind and creates the chosen one", function()
    with_scratch_dir(function(dir)
      -- Markdown rather than HTTP: opening a .http buffer loads kulala, which
      -- is a lot of machinery to drag into a test about the picker.
      local ui = H.with_ui({ "Markdown note" }, function()
        H.capture_notify(function() S.pick_new() end)
      end)
      H.eq(1, ui.consumed())
      local files = vim.fn.readdir(dir)
      H.eq(1, #files)
      H.matches("%.md$", files[1])
      vim.cmd("bwipeout!")
    end)
  end)

  H.it("does nothing when cancelled", function()
    with_scratch_dir(function(dir)
      H.with_ui({ H.CANCEL }, function()
        H.capture_notify(function() S.pick_new() end)
      end)
      H.eq({}, vim.fn.readdir(dir))
    end)
  end)
end)

H.describe("the scratch commands", function()
  H.it("are registered", function()
    H.ok(vim.fn.exists(":IdeScratch") >= 1)
    H.ok(vim.fn.exists(":IdeScratchList") >= 1)
  end)

  H.it("default to stdpath('data'), never the project", function()
    local saved = vim.g.kebab_scratch_dir
    vim.g.kebab_scratch_dir = nil
    local dir = S.dir()
    vim.g.kebab_scratch_dir = saved
    H.matches(vim.pesc(vim.fn.stdpath("data")), dir,
      "scratches must not land somewhere they could be committed")
  end)
end)
