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

local function is_jdk(dir)
  return uv.fs_stat(dir .. "/bin/javac") ~= nil
end

-- "…/java-21-openjdk" / "temurin-17.jdk" / "21.0.2-tem" -> 21
local function major_of(dir)
  local base = vim.fn.fnamemodify(dir, ":t")
  local v = base:match("(%d+)")
  if not v then
    return nil
  end
  v = tonumber(v)
  -- 1.8.0_x style
  if v == 1 then
    local second = base:match("1%.(%d+)")
    v = second and tonumber(second) or nil
  end
  return v
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

  for _, root in ipairs(SEARCH_DIRS) do
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
  add(vim.env.JAVA_HOME)
  add(vim.fn.exepath("java"))

  table.sort(found, function(a, b)
    return a.major < b.major
  end)

  local runtimes = {}
  for i, jdk in ipairs(found) do
    runtimes[#runtimes + 1] = {
      name = "JavaSE-" .. jdk.major,
      path = jdk.path,
      -- newest wins as the default
      default = i == #found or nil,
    }
  end
  return runtimes
end

return M
