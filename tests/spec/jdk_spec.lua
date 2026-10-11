-- JDK discovery. jdtls needs java.configuration.runtimes to compile against
-- the right release, and this had no direct tests -- which is where two bugs
-- were sitting.
local H = ...
local J = require("kebab.jdk")

---A fake JDK at `path`; `release` adds a release file with that JAVA_VERSION.
local function fake_jdk(path, release)
  vim.fn.mkdir(path .. "/bin", "p")
  for _, exe in ipairs({ "java", "javac" }) do
    H.write(path .. "/bin/" .. exe, "#!/bin/sh\n")
    vim.fn.setfperm(path .. "/bin/" .. exe, "rwxr-xr-x")
  end
  if release then
    H.write(path .. "/release", ('JAVA_VERSION="%s"\nIMPLEMENTOR="Test"'):format(release))
  end
end

local function with_roots(dirs, fn)
  local saved = vim.g.kebab_jdk_roots
  vim.g.kebab_jdk_roots = dirs
  local ok, err = pcall(fn)
  vim.g.kebab_jdk_roots = saved
  if not ok then
    error(err, 0)
  end
end

H.describe("the execution-environment id", function()
  -- JDT only knows JavaSE-1.8 and below for 8 and below. `JavaSE-8` is
  -- rejected with "Invalid runtime for JavaSE-8" and the entry dropped -- so a
  -- Java 8 project was analysed against whatever JVM jdtls itself runs on.
  H.it("uses the 1.x spelling for 8 and below", function()
    H.eq("JavaSE-1.6", J.ee_name(6))
    H.eq("JavaSE-1.7", J.ee_name(7))
    H.eq("JavaSE-1.8", J.ee_name(8))
  end)

  H.it("uses the plain spelling from 9 up", function()
    H.eq("JavaSE-9", J.ee_name(9))
    H.eq("JavaSE-11", J.ee_name(11))
    H.eq("JavaSE-17", J.ee_name(17))
    H.eq("JavaSE-21", J.ee_name(21))
    H.eq("JavaSE-25", J.ee_name(25))
  end)
end)

H.describe("finding JDKs", function()
  H.it("recognises the layouts people actually have", function()
    local root = H.tmpdir("jdks")
    fake_jdk(root .. "/java-21-openjdk")
    fake_jdk(root .. "/java-1.8.0-openjdk")
    fake_jdk(root .. "/corretto-1.8.0_412")
    fake_jdk(root .. "/17.0.10-tem")

    with_roots({ root }, function()
      local byname = {}
      for _, r in ipairs(J.runtimes()) do
        byname[r.name] = r.path
      end
      H.ok(byname["JavaSE-21"], "a distro layout: " .. vim.inspect(byname))
      H.ok(byname["JavaSE-1.8"], "a 1.8.0_x layout")
      H.ok(byname["JavaSE-17"], "an sdkman layout")
      H.falsy(byname["JavaSE-8"], "JavaSE-8 is not an execution environment jdtls knows")
    end)
  end)

  -- The basename of a macOS bundle is "Home", so reading only the basename
  -- dropped every Homebrew, Temurin and Oracle bundle JDK silently.
  H.it("recognises a macOS bundle, whose basename is Home", function()
    local root = H.tmpdir("jdks-bundle")
    fake_jdk(root .. "/temurin-21.jdk/Contents/Home")
    with_roots({ root }, function()
      local runtimes = J.runtimes()
      H.eq(1, #runtimes, "the bundle should be found: " .. vim.inspect(runtimes))
      H.eq("JavaSE-21", runtimes[1].name)
      H.matches("Contents/Home$", runtimes[1].path)
    end)
  end)

  H.it("falls back to the JDK's own release file", function()
    local root = H.tmpdir("jdks-release")
    fake_jdk(root .. "/no-version-in-the-name", "11.0.22")
    with_roots({ root }, function()
      local runtimes = J.runtimes()
      H.eq(1, #runtimes, vim.inspect(runtimes))
      H.eq("JavaSE-11", runtimes[1].name)
    end)
  end)

  H.it("ignores a directory that is not a JDK", function()
    local root = H.tmpdir("jdks-junk")
    vim.fn.mkdir(root .. "/java-21-notreally/bin", "p")
    H.write(root .. "/java-21-notreally/bin/java", "")
    with_roots({ root }, function()
      H.eq({}, J.runtimes(), "no javac means no JDK")
    end)
  end)

  H.it("marks the newest as the default, exactly once", function()
    local root = H.tmpdir("jdks-default")
    fake_jdk(root .. "/java-11-openjdk")
    fake_jdk(root .. "/java-17-openjdk")
    fake_jdk(root .. "/java-21-openjdk")
    with_roots({ root }, function()
      local runtimes = J.runtimes()
      H.eq(3, #runtimes)
      local defaults = {}
      for _, r in ipairs(runtimes) do
        if r.default then
          defaults[#defaults + 1] = r.name
        end
      end
      H.eq({ "JavaSE-21" }, defaults, "jdtls takes one default")
    end)
  end)

  H.it("finds the real JDKs on this machine", function()
    local runtimes = J.runtimes()
    if #runtimes == 0 then
      H.skip("no JDK installed")
    end
    for _, r in ipairs(runtimes) do
      H.matches("^JavaSE%-", r.name)
      H.ok(H.exists(r.path .. "/bin/javac"), r.path .. " should have javac")
    end
  end)
end)
