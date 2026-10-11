-- Writing a file without the write being able to abort the caller.
--
-- vim.fn.writefile raises E482 rather than returning -1, and no caller wrapped
-- it -- so a read-only checkout or a full disk raised mid-flow: the dependency
-- was reported as added, the scaffold stopped without calling `done`, and the
-- user saw a stack trace instead of a reason.
local H = ...
local FS = require("kebab.fs")

H.describe("kebab.fs.write_lines", function()
  H.it("creates parent directories", function()
    local dir = H.tmpdir("fs-nested")
    local path = dir .. "/a/b/c/file.txt"
    local ok, err = FS.write_lines(path, { "one", "two" })
    H.ok(ok, tostring(err))
    H.eq({ "one", "two" }, FS.read_lines(path))
  end)

  H.it("reports a failure instead of raising", function()
    -- /proc is not writable, and the parent cannot be created either
    local ok, err = FS.write_lines("/proc/self/nope/x.txt", { "x" })
    H.falsy(ok, "it must not claim success")
    H.ok(err, "and must say what happened")
    H.matches("could not", err)
  end)

  H.it("keeps bytes exactly with the b flag", function()
    local path = H.tmpdir("fs-crlf") .. "/crlf.txt"
    H.ok(FS.write_lines(path, { "a\r", "b\r" }, "b"))
    local raw = table.concat(FS.read_lines(path, "b"), "\n")
    H.matches("a\r\nb\r", raw, "CRLF should survive")
  end)

  H.it("reports a read it could not do", function()
    local lines, err = FS.read_lines("/nonexistent-kebab-file-xyz")
    H.falsy(lines)
    H.matches("could not read", err)
  end)
end)

H.describe("the writers that used to raise", function()
  -- Each of these ends in a writefile. A caller has to get an error back, not
  -- a stack trace from inside the editor.
  H.it("maven.add_to_file reports an unwritable pom", function()
    local M = require("kebab.maven")
    local ok, err = M.add_to_file("/proc/self/nope/pom.xml", { group = "g", artifact = "a", version = "1" })
    H.falsy(ok)
    H.ok(err, "a reason is required")
  end)

  H.it("scaffold.write_file reports rather than raising", function()
    local S = require("kebab.scaffold")
    local ran, result = pcall(S.write_file, "/proc/self/nope/x.txt", { "x" })
    H.ok(ran, "it must not throw: " .. tostring(result))
    H.falsy(result, "and must report the failure")
  end)

  H.it("runconfig.save reports an unwritable root", function()
    local RC = require("kebab.runconfig")
    local ok, err = RC.save("/proc/self/nope", { { name = "a", cmd = { "echo" } } })
    H.falsy(ok)
    H.ok(err)
  end)
end)
