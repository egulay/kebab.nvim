-- kebab.git: the revert the tree menu performs by hand.
--
-- This exists because `git checkout HEAD -- <path>` silently ignores untracked
-- files, so reverting a newly added file looked like it did nothing. These
-- tests run against real scratch repositories, because that bug was invisible
-- to anything that only inspected `git diff`.
local H = ...
local git = require("kebab.git")

H.describe("kebab.git revert_plan", function()
  H.it("refuses a path outside any repository", function()
    local dir = H.tmpdir("norepo")
    local plan, err = git.revert_plan(dir .. "/nothing.txt")
    H.falsy(plan)
    H.matches("Not inside a git repository", err)
  end)

  H.it("finds nothing to do in a clean repository", function()
    local repo = H.git_repo("clean")
    local plan = git.revert_plan(repo .. "/README.md")
    H.ok(plan, "should produce a plan")
    H.ok(git.is_empty(plan), "a clean file has nothing to revert")
    H.eq(0, #plan.modified)
    H.eq(0, #plan.untracked)
  end)

  H.it("reports a modified tracked file", function()
    local repo = H.git_repo("modified")
    H.write(repo .. "/README.md", "changed on purpose")
    local plan = git.revert_plan(repo .. "/README.md")
    H.eq({ "README.md" }, plan.modified)
    H.eq(0, #plan.untracked)
    H.falsy(git.is_empty(plan))
  end)

  H.it("reports a staged change as modified too", function()
    -- porcelain gives "M " for staged and " M" for unstaged; both are tracked
    -- changes that a revert should discard.
    local repo, g = H.git_repo("staged")
    H.write(repo .. "/README.md", "staged change")
    g("add", "README.md")
    local plan = git.revert_plan(repo .. "/README.md")
    H.eq({ "README.md" }, plan.modified)
  end)

  H.it("reports an untracked file, which git checkout would ignore", function()
    local repo = H.git_repo("untracked")
    H.write(repo .. "/brand-new.txt", "fresh")
    local plan = git.revert_plan(repo .. "/brand-new.txt")
    H.eq(0, #plan.modified)
    H.eq({ repo .. "/brand-new.txt" }, plan.untracked)
  end)

  H.it("covers a whole directory, mixing tracked and untracked", function()
    local repo, g = H.git_repo("mixed")
    vim.fn.mkdir(repo .. "/src", "p")
    H.write(repo .. "/src/kept.txt", "original")
    g("add", "src/kept.txt")
    g("commit", "-q", "-m", "add kept")
    H.write(repo .. "/src/kept.txt", "edited")
    H.write(repo .. "/src/added.txt", "new file")

    local plan = git.revert_plan(repo .. "/src")
    H.eq({ "src/kept.txt" }, plan.modified)
    H.eq({ repo .. "/src/added.txt" }, plan.untracked)
  end)

  H.it("handles a path containing a space, which git quotes", function()
    local repo = H.git_repo("spaces")
    H.write(repo .. "/two words.txt", "untracked with a space")
    local plan = git.revert_plan(repo .. "/two words.txt")
    H.eq({ repo .. "/two words.txt" }, plan.untracked,
      "the quotes git adds around the path must be stripped")
  end)

  H.it("resolves a rename to the name that exists on disk", function()
    local repo, g = H.git_repo("renamed")
    H.write(repo .. "/old.txt", "content")
    g("add", "old.txt")
    g("commit", "-q", "-m", "add old")
    g("mv", "old.txt", "new.txt")
    local plan = git.revert_plan(repo)
    H.ok(vim.tbl_contains(plan.modified, "new.txt"),
      "expected new.txt in " .. vim.inspect(plan.modified))
  end)

  H.it("records the repository root, not the clicked directory", function()
    local repo = H.git_repo("root")
    vim.fn.mkdir(repo .. "/deep/nested", "p")
    H.write(repo .. "/deep/nested/file.txt", "x")
    local plan = git.revert_plan(repo .. "/deep/nested/file.txt")
    H.eq(vim.fn.resolve(repo), vim.fn.resolve(plan.root))
  end)
end)

H.describe("kebab.git apply_revert", function()
  H.it("restores a modified tracked file", function()
    local repo = H.git_repo("restore")
    local original = H.read(repo .. "/README.md")
    H.write(repo .. "/README.md", "vandalised")
    H.eq("vandalised", H.read(repo .. "/README.md"))

    local plan = git.revert_plan(repo .. "/README.md")
    local ok, failed = git.apply_revert(plan)
    H.ok(ok, "revert should succeed: " .. vim.inspect(failed))
    H.eq(original, H.read(repo .. "/README.md"), "content should be back to HEAD")
  end)

  H.it("deletes an untracked file, which is what revert is expected to mean", function()
    local repo = H.git_repo("delete-untracked")
    local path = repo .. "/brand-new.txt"
    H.write(path, "fresh")
    H.ok(H.exists(path))

    local plan = git.revert_plan(path)
    local ok = git.apply_revert(plan)
    H.ok(ok)
    H.falsy(H.exists(path), "the untracked file should be gone")
  end)

  H.it("deletes an untracked directory recursively", function()
    local repo = H.git_repo("delete-dir")
    H.write(repo .. "/newdir/a/b.txt", "deep")
    local plan = git.revert_plan(repo .. "/newdir")
    local ok = git.apply_revert(plan)
    H.ok(ok)
    H.falsy(H.exists(repo .. "/newdir"), "the whole untracked tree should be gone")
  end)

  H.it("does both halves for a directory in one pass", function()
    local repo, g = H.git_repo("both")
    vim.fn.mkdir(repo .. "/src", "p")
    H.write(repo .. "/src/kept.txt", "original")
    g("add", "src/kept.txt")
    g("commit", "-q", "-m", "add kept")
    H.write(repo .. "/src/kept.txt", "edited")
    H.write(repo .. "/src/added.txt", "new file")

    local plan = git.revert_plan(repo .. "/src")
    local ok, failed = git.apply_revert(plan)
    H.ok(ok, vim.inspect(failed))
    H.eq("original", H.read(repo .. "/src/kept.txt"), "tracked file restored")
    H.falsy(H.exists(repo .. "/src/added.txt"), "untracked file deleted")
  end)

  H.it("leaves the rest of the repository alone", function()
    local repo, g = H.git_repo("scoped")
    H.write(repo .. "/one.txt", "one")
    H.write(repo .. "/two.txt", "two")
    g("add", ".")
    g("commit", "-q", "-m", "add both")
    H.write(repo .. "/one.txt", "one edited")
    H.write(repo .. "/two.txt", "two edited")

    local plan = git.revert_plan(repo .. "/one.txt")
    git.apply_revert(plan)
    H.eq("one", H.read(repo .. "/one.txt"), "the target is reverted")
    H.eq("two edited", H.read(repo .. "/two.txt"), "its neighbour is untouched")
  end)

  H.it("reverting a clean file is a no-op, not an error", function()
    local repo = H.git_repo("noop")
    local before = H.read(repo .. "/README.md")
    local plan = git.revert_plan(repo .. "/README.md")
    local ok = git.apply_revert(plan)
    H.ok(ok)
    H.eq(before, H.read(repo .. "/README.md"))
  end)
end)

H.describe("kebab.git describe_plan", function()
  H.it("names both halves so the confirmation is not a surprise", function()
    local plan = { root = "/r", path = "/r/x", modified = { "a", "b" }, untracked = { "/r/c" } }
    local msg = git.describe_plan(plan)
    H.matches("2 tracked file", msg)
    H.matches("DELETE 1 untracked file", msg)
  end)

  H.it("mentions only what applies", function()
    H.matches("^discard changes in 1 tracked file%(s%)$",
      git.describe_plan({ modified = { "a" }, untracked = {} }))
    H.matches("^DELETE 1 untracked file%(s%)$",
      git.describe_plan({ modified = {}, untracked = { "/r/c" } }))
  end)
end)

-- `git status --porcelain` quotes any path with a non-ASCII byte and escapes it
-- C-style, so stripping just the quotes left a filename that does not exist:
-- the revert skipped those files while still deleting the untracked ones.
H.describe("reverting paths git has to quote", function()
  H.it("reverts a non-ASCII filename", function()
    local repo, g = H.git_repo("git-utf8")
    vim.fn.mkdir(repo .. "/sub", "p")
    for _, name in ipairs({ "plain.txt", "Şirket.java", "café.txt", "naïve b.txt" }) do
      H.write(repo .. "/sub/" .. name, "orig")
    end
    g("add", "-A")
    g("commit", "-q", "-m", "add")
    for _, name in ipairs({ "plain.txt", "Şirket.java", "café.txt", "naïve b.txt" }) do
      H.write(repo .. "/sub/" .. name, "EDITED")
    end

    local plan, err = git.revert_plan(repo .. "/sub")
    H.ok(plan, tostring(err))
    H.eq(4, #plan.modified, "every quoted path should be in the plan: " .. vim.inspect(plan.modified))
    for _, rel in ipairs(plan.modified) do
      H.falsy(rel:find("\\"), rel .. " still carries git's C-style escapes")
      H.ok(H.exists(repo .. "/" .. rel), rel .. " should be a path that exists")
    end

    local ok, failed = git.apply_revert(plan)
    H.ok(ok, vim.inspect(failed))
    for _, name in ipairs({ "plain.txt", "Şirket.java", "café.txt", "naïve b.txt" }) do
      H.eq("orig", H.read(repo .. "/sub/" .. name), name .. " should be restored")
    end
  end)

  H.it("keeps a glob character in a path from matching a sibling", function()
    local repo, g = H.git_repo("git-glob")
    vim.fn.mkdir(repo .. "/routes/[slug]", "p")
    vim.fn.mkdir(repo .. "/routes/s", "p")
    H.write(repo .. "/routes/[slug]/page.svelte", "orig")
    H.write(repo .. "/routes/s/page.svelte", "orig")
    g("add", "-A")
    g("commit", "-q", "-m", "routes")
    H.write(repo .. "/routes/[slug]/page.svelte", "EDITED")
    H.write(repo .. "/routes/s/page.svelte", "EDITED")

    local plan = git.revert_plan(repo .. "/routes/[slug]")
    H.eq({ "routes/[slug]/page.svelte" }, plan.modified, "only the clicked route")
    H.ok(git.apply_revert(plan))
    H.eq("orig", H.read(repo .. "/routes/[slug]/page.svelte"))
    H.eq("EDITED", H.read(repo .. "/routes/s/page.svelte"), "the sibling route must be untouched")
  end)

  H.it("does not treat a rename's old name as a separate change", function()
    local repo, g = H.git_repo("git-rename-z")
    H.write(repo .. "/old.txt", "orig")
    g("add", "-A")
    g("commit", "-q", "-m", "add")
    g("mv", "old.txt", "new.txt")
    local plan = git.revert_plan(repo)
    H.ok(vim.tbl_contains(plan.modified, "new.txt"), vim.inspect(plan.modified))
    H.falsy(vim.tbl_contains(plan.modified, "old.txt"), "the old name is not on disk: " .. vim.inspect(plan.modified))
  end)
end)

-- Restoring is reversible; deleting is not. Doing the deletions anyway after a
-- failed checkout destroyed new work *and* left the edits the user asked to
-- discard.
H.describe("a revert whose restore fails", function()
  H.it("deletes nothing and says why", function()
    local repo, g = H.git_repo("git-locked")
    H.write(repo .. "/tracked.txt", "orig")
    g("add", "-A")
    g("commit", "-q", "-m", "add")
    H.write(repo .. "/tracked.txt", "EDITED")
    H.write(repo .. "/brand-new.txt", "IRREPLACEABLE")
    -- what another git process holding the index looks like
    H.write(repo .. "/.git/index.lock", "")

    local plan = git.revert_plan(repo)
    H.ok(#plan.modified > 0 and #plan.untracked > 0, "the plan needs both halves")
    local ok, failed = git.apply_revert(plan)
    H.falsy(ok, "a locked index is a failure")
    H.ok(H.exists(repo .. "/brand-new.txt"), "untracked work must survive a failed revert")
    H.eq("EDITED", H.read(repo .. "/tracked.txt"), "and nothing was restored either")
    H.matches("NOT deleted", table.concat(failed, "\n"), "the user has to be told the deletions were skipped")
    vim.fn.delete(repo .. "/.git/index.lock")
  end)

  H.it("still restores the files it can when one path is unmatched", function()
    local repo, g = H.git_repo("git-partial")
    for _, n in ipairs({ "a.txt", "b.txt" }) do
      H.write(repo .. "/" .. n, "orig")
    end
    g("add", "-A")
    g("commit", "-q", "-m", "add")
    H.write(repo .. "/a.txt", "EDITED")
    H.write(repo .. "/b.txt", "EDITED")
    -- one pathspec git cannot match used to abort the whole batch
    local plan = git.revert_plan(repo)
    table.insert(plan.modified, "never-committed.txt")
    local ok, failed = git.apply_revert(plan)
    H.falsy(ok, "the bogus path should be reported")
    H.eq("orig", H.read(repo .. "/a.txt"), "a.txt should still be restored")
    H.eq("orig", H.read(repo .. "/b.txt"), "b.txt should still be restored")
    H.eq(1, #failed, vim.inspect(failed))
  end)
end)

H.describe("counting what a delete really covers", function()
  H.it("counts the files inside an untracked directory", function()
    local repo = H.git_repo("git-count")
    vim.fn.mkdir(repo .. "/newfeature/deeper", "p")
    for i = 1, 12 do
      H.write(repo .. ("/newfeature/f%d.java"):format(i), "x")
    end
    H.write(repo .. "/newfeature/deeper/g.java", "x")
    H.write(repo .. "/loose.txt", "x")

    local plan = git.revert_plan(repo)
    local msg = git.describe_plan(plan)
    H.matches("DELETE 14 untracked file", msg, "a collapsed `?? dir/` entry understated this: " .. msg)
    H.matches("1 new directory", msg, "and the user should know it is recursive: " .. msg)
    H.eq(13, git.untracked_file_count(repo .. "/newfeature"))
    H.eq(1, git.untracked_file_count(repo .. "/loose.txt"))
    H.eq(1, git.untracked_file_count(repo .. "/does-not-exist"))
  end)
end)
