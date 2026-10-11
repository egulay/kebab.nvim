-- Reading and editing a Gradle build file.
--
-- The Maven counterpart is kebab/maven.lua, and the same reasoning applies:
-- Gradle has no command that adds a dependency, so the build file is edited,
-- and that editing is pure string functions because a bad insertion breaks the
-- build.
--
-- Two dialects, which is the complication Maven does not have:
--
--   build.gradle.kts   implementation("group:artifact:version")
--   build.gradle       implementation 'group:artifact:version'
--
-- and the version is omitted when a plugin manages it, exactly as with
-- spring-boot-starter-parent.
local M = {}

---Which dialect a path is written in.
---@param path string
---@return "kotlin"|"groovy"
function M.dialect(path)
  return (path or ""):match("%.kts$") and "kotlin" or "groovy"
end

---Split "group:artifact[:version]". Reuses Maven's shorthand, so a bare name
---still means a Spring Boot starter.
---@param input string
function M.parse_coordinate(input)
  return require("kebab.maven").parse_coordinate(input)
end

---Blank out line comments so a `dependencies {` inside one is not mistaken for
---the real block.
---
---Replaced with spaces rather than removed, because every position this module
---returns indexes the *original* text. Shortening the string would shift every
---offset after the first comment -- which is exactly the bug this replaced.
---
---Line comments only; a block comment containing an unbalanced brace is rare
---enough to leave alone.
local function blank_line_comments(text)
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local code, comment = line:match("^(.-)(//.*)$")
    if comment then
      out[#out + 1] = code .. (" "):rep(#comment)
    else
      out[#out + 1] = line
    end
  end
  -- gmatch above adds one trailing element for the sentinel newline
  local joined = table.concat(out, "\n")
  return joined:sub(1, #text)
end

---The byte range of the top-level `dependencies { ... }` block.
---
---Found by brace matching rather than a pattern, because a build file nests
---freely -- `subprojects { dependencies { ... } }`, `buildscript { ... }` --
---and only the block at depth 0 is the project's own.
---@param text string
---@return number|nil open_end just after the `{`
---@return number|nil close_start the matching `}`
---@return string|nil indent the block's own indentation
function M.find_dependencies_block(text)
  local scan = blank_line_comments(text)
  local pos = 1
  while true do
    local s, e = scan:find("dependencies%s*{", pos)
    if not s then
      return nil, nil, nil
    end
    -- depth of this occurrence, counting braces before it
    local depth = 0
    for i = 1, s - 1 do
      local ch = scan:sub(i, i)
      if ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
      end
    end
    -- and it must be a statement start, not "...dependencies {" inside a word
    local before = s > 1 and scan:sub(s - 1, s - 1) or "\n"
    if depth == 0 and before:match("[%s{}\n]") then
      -- walk to the matching close brace
      local level = 1
      local i = e + 1
      while i <= #scan do
        local ch = scan:sub(i, i)
        if ch == "{" then
          level = level + 1
        elseif ch == "}" then
          level = level - 1
          if level == 0 then
            local line_start = (scan:sub(1, s - 1):find("\n[^\n]*$") or 0) + 1
            local indent = scan:sub(line_start, s - 1):match("^[ \t]*") or ""
            return e + 1, i, indent
          end
        end
        i = i + 1
      end
      return nil, nil, nil
    end
    pos = e + 1
  end
end

---Is this dependency already declared?
---@param text string
---@param dep table { group, artifact }
function M.has_dependency(text, dep)
  local open_end, close_start = M.find_dependencies_block(text)
  if not open_end then
    return false
  end
  local block = text:sub(open_end, close_start - 1)
  local needle = dep.group .. ":" .. dep.artifact
  -- "group:artifact" or "group:artifact:version", in either quote style
  for found in block:gmatch("[\"']([^\"']+)[\"']") do
    local g, a = found:match("^([^:]+):([^:]+)")
    if g == dep.group and a == dep.artifact then
      return true
    end
  end
  -- the map form: group: 'x', name: 'y'
  for g, a in block:gmatch("group:%s*[\"']([^\"']+)[\"'],%s*name:%s*[\"']([^\"']+)[\"']") do
    if g == dep.group and a == dep.artifact then
      return true
    end
  end
  return needle == nil
end

---True when a plugin manages versions for this group, so one must not be given.
---@param text string
---@param dep table
function M.version_managed(text, dep)
  if dep.group ~= "org.springframework.boot" then
    return false
  end
  -- id("org.springframework.boot") / id 'org.springframework.boot'
  return text:match("id%s*%(?%s*[\"']org%.springframework%.boot[\"']") ~= nil
    or text:match("io%.spring%.dependency%-management") ~= nil
end

---Does this dependency need an explicit version?
function M.needs_version(text, dep)
  if dep.version then
    return true
  end
  return not M.version_managed(text, dep)
end

---The line to add, in the right dialect.
---@param dialect "kotlin"|"groovy"
---@param configuration string e.g. "implementation"
---@param dep table
function M.declaration(dialect, configuration, dep)
  local coord = dep.group .. ":" .. dep.artifact
  if dep.version then
    coord = coord .. ":" .. dep.version
  end
  if dialect == "kotlin" then
    return ('%s("%s")'):format(configuration, coord)
  end
  return ("%s '%s'"):format(configuration, coord)
end

---Insert `dep` into the build file's dependencies block.
---@param text string
---@param dep table { group, artifact, version? }
---@param opts? { dialect?: string, configuration?: string }
---@return string|nil new_text, string|nil err
function M.insert(text, dep, opts)
  opts = opts or {}
  if not dep or not dep.group or not dep.artifact then
    return nil, "A group and an artifact are required"
  end
  local dialect = opts.dialect or "kotlin"
  local configuration = opts.configuration or "implementation"

  if M.has_dependency(text, dep) then
    return nil, ("%s:%s is already a dependency"):format(dep.group, dep.artifact)
  end

  local effective = vim.deepcopy(dep)
  if not M.needs_version(text, effective) then
    effective.version = nil
  elseif not effective.version then
    return nil, ("%s:%s needs a version: no plugin in this build manages it")
      :format(dep.group, dep.artifact)
  end

  local open_end, close_start, indent = M.find_dependencies_block(text)
  if not open_end then
    return nil, "no top-level dependencies { } block found"
  end

  -- Match the indentation already used inside the block, falling back to one
  -- level in from the block itself.
  local block = text:sub(open_end, close_start - 1)
  local inner = block:match("\n([ \t]+)%S") or ((indent or "") .. "    ")
  local line = inner .. M.declaration(dialect, configuration, effective)

  local before = text:sub(1, close_start - 1)
  local trailing = before:match("([ \t]*)$") or ""
  before = before:sub(1, #before - #trailing)
  if not before:match("\n$") then
    before = before .. "\n"
  end
  return before .. line .. "\n" .. trailing .. text:sub(close_start)
end

---Add `dep` to the build file at `path`. Returns ok, message.
function M.add_to_file(path, input, opts)
  opts = opts or {}
  local dep, err = M.parse_coordinate(input)
  if not dep then
    return false, err
  end
  local ok, text = pcall(function()
    return table.concat(vim.fn.readfile(path), "\n")
  end)
  if not ok then
    return false, "Could not read " .. path
  end
  local configuration = opts.configuration
  if not configuration then
    -- `! ` on the command means a test dependency, as it does for Maven scope.
    configuration = opts.dev and "testImplementation" or "implementation"
  end
  local updated, ierr = M.insert(text, dep, {
    dialect = M.dialect(path),
    configuration = configuration,
  })
  if not updated then
    return false, ierr
  end
  vim.fn.writefile(vim.split(updated, "\n"), path)
  return true, ("Added %s to %s as %s")
    :format(dep.group .. ":" .. dep.artifact, vim.fn.fnamemodify(path, ":t"), configuration)
end

return M
