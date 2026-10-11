-- Noticing that git state changed outside the editor.
--
-- kebab.follow watches the working tree and excludes `.git`, which is right --
-- you do not want the view jumping to `.git/index`. But it means nothing sees
-- a commit, a checkout or a push, and a push changes no file at all, only
-- `.git/refs/remotes/...`. So the tree kept showing a file as changed after it
-- had been committed elsewhere.
local H = ...
local W = require("kebab.gitwatch")

local function with_watch(fn)
  local was = W.running()
  if was then
    W.stop()
  end
  local ok, err = pcall(fn)
  pcall(W.stop)
  if not ok then
    error(err, 0)
  end
end

H.describe("kebab.gitwatch", function()
  H.it("finds the git directory of a plain repository", function()
    local repo = H.git_repo("gw-plain")
    H.eq(repo .. "/.git", W.git_dir(repo))
  end)

  H.it("follows the gitdir pointer of a worktree", function()
    -- a worktree's `.git` is a *file* holding "gitdir: <path>"
    local repo = H.git_repo("gw-worktree")
    local fake = H.tmpdir("gw-linked")
    H.write(fake .. "/.git", "gitdir: " .. repo .. "/.git/worktrees/wt")
    H.eq(repo .. "/.git/worktrees/wt", W.git_dir(fake))
  end)

  H.it("resolves a relative gitdir pointer", function()
    local base = H.tmpdir("gw-rel")
    vim.fn.mkdir(base .. "/real", "p")
    H.write(base .. "/.git", "gitdir: real")
    H.eq(base .. "/real", W.git_dir(base))
  end)

  H.it("reports a directory that is not a repository", function()
    local ok, err = W.start(H.tmpdir("gw-norepo"))
    H.falsy(ok)
    H.matches("not a git repository", err)
  end)

  H.it("refreshes without a tree or gitsigns loaded", function()
    -- every consumer is pcall'd, so a refresh must never raise
    local before = W.state().refreshes
    H.ok(W.refresh())
    H.eq(before + 1, W.state().refreshes)
  end)

  H.it("registers :IdeGitRefresh", function()
    H.ok(vim.fn.exists(":IdeGitRefresh") >= 1, ":IdeGitRefresh should be defined")
  end)

  H.it("notices a commit made outside the editor", function()
    if vim.fn.executable("inotifywait") == 0 then
      H.skip("inotify-tools is needed to watch .git")
    end
    with_watch(function()
      local repo, git = H.git_repo("gw-commit")
      H.write(repo .. "/f.txt", "changed")
      local ok, err = W.start(repo)
      H.ok(ok, tostring(err))
      local before = W.state().refreshes
      git("add", "-A")
      git("commit", "-q", "-m", "external")
      H.wait(15000, function()
        return W.state().refreshes > before
      end, "an external commit should trigger a refresh")
    end)
  end)

  H.it("notices a push, which changes no file at all", function()
    if vim.fn.executable("inotifywait") == 0 then
      H.skip("inotify-tools is needed to watch .git")
    end
    with_watch(function()
      local base = H.tmpdir("gw-push")
      local function run(...)
        local res = vim.system({ "git", ... }, { text = true }):wait(60000)
        return res.code, (res.stderr or "") .. (res.stdout or "")
      end
      H.eq(0, (run("init", "-q", "--bare", base .. "/remote.git")))
      H.eq(0, (run("clone", "-q", base .. "/remote.git", base .. "/work")))
      local work = base .. "/work"
      run("-C", work, "config", "user.email", "t@example.com")
      run("-C", work, "config", "user.name", "t")
      run("-C", work, "config", "commit.gpgsign", "false")
      H.write(work .. "/f.txt", "one")
      run("-C", work, "add", "-A")
      run("-C", work, "commit", "-q", "-m", "init")

      local ok, err = W.start(work)
      H.ok(ok, tostring(err))
      local before = W.state().refreshes
      -- a push writes only .git/refs/remotes/..., so nothing in the working
      -- tree changes and no other watcher could possibly see it
      local code, out = run("-C", work, "push", "-q", "origin", "HEAD:refs/heads/main")
      H.eq(0, code, out)
      H.wait(15000, function()
        return W.state().refreshes > before
      end, "an external push should trigger a refresh")
    end)
  end)

  H.it("coalesces a burst into one refresh", function()
    if vim.fn.executable("inotifywait") == 0 then
      H.skip("inotify-tools is needed to watch .git")
    end
    with_watch(function()
      local repo, git = H.git_repo("gw-burst")
      H.ok(W.start(repo))
      local before = W.state().refreshes
      -- one commit writes several files under .git; a rebase writes many
      for i = 1, 4 do
        H.write(repo .. ("/f%d.txt"):format(i), "x")
        git("add", "-A")
        git("commit", "-q", "-m", "commit " .. i)
      end
      H.wait(15000, function()
        return W.state().refreshes > before
      end, "the commits should trigger a refresh")
      H.drain(1200)
      local fired = W.state().refreshes - before
      H.ok(fired <= 4, ("four commits should not mean more than four refreshes, got %d"):format(fired))
    end)
  end)

  H.it("can be turned off", function()
    local saved = vim.g.kebab_git_watch
    vim.g.kebab_git_watch = false
    W.setup()
    local aus = vim.api.nvim_get_autocmds({ group = "kebab_gitwatch" })
    local events = {}
    for _, a in ipairs(aus) do
      events[a.event] = true
    end
    vim.g.kebab_git_watch = saved
    W.setup()
    H.ok(events["VimLeavePre"], "it must still stop on exit")
    H.falsy(events["BufEnter"], "but not arm itself")
  end)
end)
