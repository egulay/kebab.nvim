-- Discover installed JDKs instead of hardcoding paths.
--
-- jdtls needs `java.configuration.runtimes` to compile against the right
-- release. Paths differ per distro and per install method, so probe the
-- common locations plus JAVA_HOME and whatever `java` is on PATH.
local M = {}

local uv = vim.uv

local SEARCH_DIRS = {
  "/usr/lib/jvm",
  "/usr/lib64/jvm",
  "/Library/Java/JavaVirtualMachines",
  vim.fn.expand("~/.sdkman/candidates/java"),
  vim.fn.expand("~/.jdks"),
  vim.fn.expand("~/.local/share/mise/installs/java"),
}

---Where to look. `vim.g.kebab_jdk_roots` replaces the list, which is what
---makes this testable at all -- and lets someone with an unusual install
---layout point at it without editing the layer.
function M.search_dirs()
  local override = vim.g.kebab_jdk_roots
  if type(override) == "table" and #override > 0 then
    return vim.tbl_map(function(d)
      return require("kebab.path").expand(d)
    end, override)
  end
  return SEARCH_DIRS
end

local function is_jdk(dir)
  return uv.fs_stat(dir .. "/bin/javac") ~= nil
end

---The major version in a directory name, or nil.
---@param base string
local function major_in(base)
  local v = base:match("(%d+)")
  if not v then
    return nil
  end
  v = tonumber(v)
  -- 1.8.0_x style
  if v == 1 then
    local second = base:match("1%.(%d+)")
    return second and tonumber(second) or nil
  end
  return v
end

---The major version from the JDK's own `release` file, which every layout has.
---@param dir string
local function major_from_release(dir)
  local ok, lines = pcall(vim.fn.readfile, dir .. "/release", "", 40)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  for _, line in ipairs(lines) do
    local value = line:match('^JAVA_VERSION="?([^"]+)"?')
    if value then
      return major_in(value)
    end
  end
  return nil
end

-- "…/java-21-openjdk" / "temurin-17.jdk" / "21.0.2-tem" -> 21
--
-- The basename alone is not enough: a macOS bundle is
-- `<x>.jdk/Contents/Home`, whose basename is "Home", so every Homebrew,
-- Temurin and Oracle bundle JDK was silently dropped and jdtls fell back to
-- its own JVM. So walk up the path, and ask the JDK itself as a last resort.
local function major_of(dir)
  local base = vim.fn.fnamemodify(dir, ":t")
  if base == "Home" or base == "Contents" then
    -- Only for a bundle, and only the bundle's own component: walking up
    -- blindly reads a version out of an unrelated ancestor directory, which
    -- is how `<scratch>/no-version-in-the-name` came back as JavaSE-1.4.
    local bundle = dir:match("([^/]+)%.jdk/Contents") or dir:match("([^/]+)/Contents")
    local v = bundle and major_in(bundle) or nil
    if v then
      return v
    end
  else
    local v = major_in(base)
    if v then
      return v
    end
  end
  -- Whatever the layout, the JDK itself knows.
  return major_from_release(dir)
end

---The Eclipse execution-environment id for a major version.
---
---JDT only knows `JavaSE-1.8` and below for 8 and below -- `JavaSE-8` is
---rejected with "Invalid runtime for JavaSE-8" and the entry dropped, which is
---exactly the JDK the `1.8.0_x` parsing was written to find.
---@param major number
function M.ee_name(major)
  if major <= 8 then
    return ("JavaSE-1.%d"):format(major)
  end
  return ("JavaSE-%d"):format(major)
end

---@return table[] list of { name = "JavaSE-21", path = "...", default = bool }
function M.runtimes()
  local seen, found = {}, {}

  local function add(dir)
    if not dir or dir == "" then
      return
    end
    dir = vim.fn.resolve(dir):gsub("/$", "")
    -- a JRE/JDK home may be handed to us as .../bin/java
    if dir:match("/bin/java$") then
      dir = vim.fn.fnamemodify(dir, ":h:h")
    end
    if seen[dir] or not is_jdk(dir) then
      return
    end
    local major = major_of(dir)
    if not major then
      return
    end
    seen[dir] = true
    found[#found + 1] = { major = major, path = dir }
  end

  for _, root in ipairs(M.search_dirs()) do
    local fd = uv.fs_scandir(root)
    if fd then
      while true do
        local name = uv.fs_scandir_next(fd)
        if not name then
          break
        end
        add(root .. "/" .. name)
        -- macOS bundles: <x>.jdk/Contents/Home
        add(root .. "/" .. name .. "/Contents/Home")
      end
    end
  end
  if type(vim.g.kebab_jdk_roots) ~= "table" then
    -- Skipped when the roots are overridden, so a caller pointing at a fixture
    -- directory sees exactly what is in it.
    add(vim.env.JAVA_HOME)
    add(vim.fn.exepath("java"))
  end

  table.sort(found, function(a, b)
    return a.major < b.major
  end)

  local runtimes = {}
  for i, jdk in ipairs(found) do
    runtimes[#runtimes + 1] = {
      name = M.ee_name(jdk.major),
      path = jdk.path,
      -- newest wins as the default
      default = i == #found or nil,
    }
  end
  return runtimes
end

return M
