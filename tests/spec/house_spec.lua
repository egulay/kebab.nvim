-- The house rules, enforced rather than remembered.
--
-- CLAUDE.md says no real project, client or database names anywhere in this
-- repository -- not in the README, not in a comment, not in a fixture. It has
-- been asked for three times and broken three times, the last one putting a
-- client's project name in the public README and in four commit messages. A
-- rule that depends on remembering it is not a rule.
--
-- The list of forbidden names cannot live in the repository: it would be the
-- leak. It is read from a file outside it -- $KEBAB_PRIVATE_NAMES, or
-- ~/.config/kebab/private-names -- one term per line, # for comments. Without
-- that file this spec skips, so the suite still runs for anyone else.
--
-- Terms are not printed by default: a failure names the file and line only, so
-- that a CI log cannot leak what the repo was being checked against.
local H = ...

local function list_path()
  local env = vim.env.KEBAB_PRIVATE_NAMES
  if env and env ~= "" then
    return require("kebab.path").expand(env)
  end
  return require("kebab.path").expand("~/.config/kebab/private-names")
end

local function terms()
  local path = list_path()
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, path
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, path
  end
  local out = {}
  for _, line in ipairs(lines) do
    local term = vim.trim(line)
    if term ~= "" and term:sub(1, 1) ~= "#" then
      out[#out + 1] = term:lower()
    end
  end
  return out, path
end

local function show_terms()
  return vim.env.KEBAB_PRIVATE_SHOW == "1"
end

---@param term string
local function redact(term)
  if show_terms() then
    return term
  end
  return ("%s… (%d chars)"):format(term:sub(1, 1), #term)
end

local root = _G.KEBAB_TEST.root

local function tracked_files()
  local res = vim.system({ "git", "-C", root, "ls-files" }, { text = true }):wait(30000)
  if res.code ~= 0 then
    return nil
  end
  return vim.split(res.stdout or "", "\n", { trimempty = true })
end

H.describe("no private names in the repository", function()
  H.it("has a list to check against", function()
    local list, path = terms()
    if not list then
      H.skip("no private-names list at " .. path)
    end
    H.ok(#list > 0, path .. " is empty, so nothing is being checked")
  end)

  H.it("has none of them in any tracked file", function()
    local list, path = terms()
    if not list then
      H.skip("no private-names list at " .. path)
    end
    local files = tracked_files()
    H.ok(files, "git ls-files should work in the repo")

    local hits = {}
    for _, rel in ipairs(files) do
      -- this spec itself, and the list's own path, name nothing
      local full = root .. "/" .. rel
      local stat = vim.uv.fs_stat(full)
      if stat and stat.type == "file" and stat.size < 2 * 1024 * 1024 then
        local ok, lines = pcall(vim.fn.readfile, full)
        if ok then
          for n, line in ipairs(lines) do
            local lower = line:lower()
            for _, term in ipairs(list) do
              if lower:find(term, 1, true) then
                hits[#hits + 1] = ("%s:%d matches %s"):format(rel, n, redact(term))
              end
            end
          end
        end
      end
    end
    H.eq({}, hits, ("%d private name(s) in the tree (KEBAB_PRIVATE_SHOW=1 to see which)"):format(#hits))
  end)

  H.it("has none of them in any commit message", function()
    -- A message is as public as a file, and this is where the last leak
    -- survived the scrub of the tree.
    local list, path = terms()
    if not list then
      H.skip("no private-names list at " .. path)
    end
    local res = vim.system({ "git", "-C", root, "log", "--format=%H%n%s%n%b" }, { text = true }):wait(60000)
    H.eq(0, res.code, "git log should work")
    local hits, commit = {}, "?"
    for _, line in ipairs(vim.split(res.stdout or "", "\n")) do
      if line:match("^%x%x%x%x%x%x%x%x%x%x%x%x") and #line == 40 then
        commit = line:sub(1, 8)
      else
        local lower = line:lower()
        for _, term in ipairs(list) do
          if lower:find(term, 1, true) then
            hits[#hits + 1] = ("%s mentions %s"):format(commit, redact(term))
          end
        end
      end
    end
    H.eq({}, hits, ("%d private name(s) in commit messages"):format(#hits))
  end)
end)
