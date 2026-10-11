-- Reading and editing a Maven pom.
--
-- Written as pure string functions so they can be tested exhaustively: a bad
-- insertion corrupts a build file, which is not a failure mode worth
-- discovering by hand. tests/spec/deps_spec.lua checks the result with a real
-- XML parser rather than a substring match.
--
-- Maven is the only ecosystem here without a command that adds a dependency, so
-- it is the only one that needs this. Everything else delegates to
-- `flutter pub add`, `npm install`, `cargo add`, `go get`.
local M = {}

-- --------------------------------------------------------------- coordinates

---Split a Maven coordinate.
---
---Accepts "group:artifact", "group:artifact:version" and a bare name, which is
---taken to be a Spring Boot starter -- "data-jpa" meaning
---org.springframework.boot:spring-boot-starter-data-jpa. That shorthand is the
---whole point: it is what you actually want to type on a Spring project.
---Is this a usable group/artifact/version?
---
---Deliberately strict: whatever comes out of here is written verbatim into
---XML and into a Groovy or Kotlin string literal, so a quote, an angle
---bracket, an ampersand or a space corrupts a build file rather than failing
---loudly. A version may also carry `+`, `[`, `]`, `(`, `)` and `,` for ranges.
---@param value string|nil
---@param field string "group" | "artifact" | "version"
function M.is_coordinate_part(value, field)
  if value == nil then
    return true
  end
  if type(value) ~= "string" or value == "" then
    return false
  end
  if field == "version" then
    return value:match("^[%w%-%.%_%+%[%]%(%)%,]+$") ~= nil
  end
  return value:match("^[%w%-%.%_]+$") ~= nil
end

---@param input string
---@return table|nil dep { group, artifact, version }, string|nil err
function M.parse_coordinate(input)
  input = vim.trim(input or "")
  if input == "" then
    return nil, "No coordinate given"
  end

  local parts = vim.split(input, ":", { plain = true })
  if #parts == 1 then
    local name = parts[1]
    if name:match("^[%w%-%.]+$") == nil then
      return nil, ("%q is not a package name or a group:artifact coordinate"):format(input)
    end
    local artifact = name:match("^spring%-boot%-starter") and name or ("spring-boot-starter-" .. name)
    return { group = "org.springframework.boot", artifact = artifact }
  end

  if #parts == 2 or #parts == 3 then
    local group, artifact, version = parts[1], parts[2], parts[3]
    if group == "" or artifact == "" then
      return nil, ("%q is missing a group or an artifact"):format(input)
    end
    if version == "" then
      version = nil
    end
    -- Validate here too. Pasting Maven Central's Gradle snippet --
    -- `implementation 'com.google.guava:guava:33.0.0-jre'` -- splits into three
    -- non-empty parts, and writing those straight out produces a build script
    -- that no longer parses, or a pom that is not well-formed XML.
    for field, value in pairs({ group = group, artifact = artifact, version = version }) do
      if not M.is_coordinate_part(value, field) then
        return nil, ("%q is not a coordinate: %s %q contains characters a Maven %s cannot"):format(
          input,
          field,
          value,
          field
        )
      end
    end
    return { group = group, artifact = artifact, version = version }
  end

  return nil, ("%q has too many colons to be a coordinate"):format(input)
end

-- ------------------------------------------------------------------ pom.xml

---Replace every XML comment, CDATA section and processing instruction with an
---equal run of spaces, so a scanner can look for tags without finding the ones
---written inside prose -- and without any byte offset moving.
---@param text string
function M.blank_text_regions(text)
  local out = {}
  local pos = 1
  local regions = {
    { "<!--", "-->" },
    { "<![CDATA[", "]]>" },
    { "<?", "?>" },
  }
  while pos <= #text do
    local best_s, best_close
    for _, r in ipairs(regions) do
      local s = text:find(r[1], pos, true)
      if s and (not best_s or s < best_s) then
        best_s, best_close = s, r[2]
      end
    end
    if not best_s then
      out[#out + 1] = text:sub(pos)
      break
    end
    out[#out + 1] = text:sub(pos, best_s - 1)
    local close_s = text:find(best_close, best_s, true)
    local stop = close_s and (close_s + #best_close - 1) or #text
    -- keep newlines: the indentation lookup counts lines
    out[#out + 1] = (text:sub(best_s, stop):gsub("[^\n]", " "))
    pos = stop + 1
  end
  return table.concat(out)
end

---Walk `text` and return the byte range of the `<dependencies>` element that is
---a direct child of `<project>`.
---
---Finding it by a plain search would hit the one inside `<dependencyManagement>`
---first on most Spring poms, and adding a dependency there declares a managed
---version without actually depending on anything.
---@param text string
---@return number|nil open_end position just after `<dependencies>`
---@return number|nil close_start position of `</dependencies>`
---@return string|nil indent the block's own indentation, for matching style
---@return table|nil selfclose byte range of a self-closing `<dependencies/>`
function M.find_dependencies_block(text)
  -- Comments and CDATA hold text, not markup, and a pom may well say
  -- `<!-- TODO: a <dependency> for redis -->`. The tag pattern below cannot
  -- match `<!--` itself, so without this it would walk straight into the
  -- comment and read that as a real element. Blank the regions with *spaces*
  -- so every byte offset below still refers to the real text.
  local scan = M.blank_text_regions(text)
  local stack = {}
  local pos = 1
  while true do
    local s, e, closing, name, selfclose = scan:find("<(/?)([%w_:%-%.]+)[^<>]-(/?)>", pos)
    if not s then
      break
    end
    -- declarations and processing instructions
    local lead = scan:sub(s + 1, s + 1)
    if lead == "!" or lead == "?" then
      pos = e + 1
    else
      if closing == "/" then
        if #stack > 0 and stack[#stack].name == name then
          local frame = table.remove(stack)
          if name == "dependencies" and frame.depth == 2 then
            return frame.content_start, s, frame.indent
          end
        end
        pos = e + 1
      elseif selfclose == "/" then
        -- `<dependencies/>` is a real, empty dependency list. Report where it
        -- is so a caller can expand it, rather than letting it look like "this
        -- pom has no dependencies block" and getting a second one appended.
        if name == "dependencies" and #stack == 1 then
          local line_start = (scan:sub(1, s - 1):find("\n[^\n]*$") or 0) + 1
          local indent = scan:sub(line_start, s - 1):match("^[ \t]*") or ""
          return nil, nil, indent, { s = s, e = e }
        end
        pos = e + 1
      else
        -- indentation of this tag, for matching the file's own style
        local line_start = (scan:sub(1, s - 1):find("\n[^\n]*$") or 0) + 1
        local indent = scan:sub(line_start, s - 1):match("^[ \t]*") or ""
        stack[#stack + 1] = { name = name, depth = #stack + 1, content_start = e + 1, indent = indent }
        pos = e + 1
      end
    end
  end
  return nil, nil, nil, nil
end

---Is `group:artifact` already declared in the project's dependencies?
---@param text string
---@param dep table
function M.has_dependency(text, dep)
  local open_end, close_start = M.find_dependencies_block(text)
  if not open_end then
    return false
  end
  local block = text:sub(open_end, close_start - 1)
  for entry in block:gmatch("<dependency>(.-)</dependency>") do
    local g = entry:match("<groupId>%s*(.-)%s*</groupId>")
    local a = entry:match("<artifactId>%s*(.-)%s*</artifactId>")
    if g == dep.group and a == dep.artifact then
      return true
    end
  end
  return false
end

---True when the pom inherits spring-boot-starter-parent, which manages versions
---for every org.springframework.boot artifact -- so adding one with an explicit
---version would override the curated set and is usually a mistake.
---@param text string
function M.has_spring_boot_parent(text)
  local parent = text:match("<parent>(.-)</parent>")
  if not parent then
    return false
  end
  return parent:match("<artifactId>%s*spring%-boot%-starter%-parent%s*</artifactId>") ~= nil
end

---Does this dependency need an explicit `<version>`?
---@param text string pom contents
---@param dep table
function M.needs_version(text, dep)
  if dep.version then
    return true
  end
  if dep.group == "org.springframework.boot" and M.has_spring_boot_parent(text) then
    return false
  end
  -- anything else without a version only resolves if dependencyManagement
  -- covers it; report that rather than writing a pom that will not build
  local managed = text:match("<dependencyManagement>(.-)</dependencyManagement>")
  if managed then
    for entry in managed:gmatch("<dependency>(.-)</dependency>") do
      local g = entry:match("<groupId>%s*(.-)%s*</groupId>")
      local a = entry:match("<artifactId>%s*(.-)%s*</artifactId>")
      if g == dep.group and a == dep.artifact then
        return false
      end
    end
  end
  return true
end

---Insert `dep` into the project's `<dependencies>`, matching the file's own
---indentation. Returns the new text, or nil plus a reason.
---@param text string
---@param dep table { group, artifact, version?, scope? }
---@return string|nil new_text, string|nil err
function M.insert(text, dep)
  if not dep or not dep.group or not dep.artifact then
    return nil, "A group and an artifact are required"
  end
  if M.has_dependency(text, dep) then
    return nil, ("%s:%s is already a dependency"):format(dep.group, dep.artifact)
  end

  local open_end, close_start, indent, selfclose = M.find_dependencies_block(text)

  -- Derive the indent unit from the file rather than assuming: this pom uses
  -- four spaces, start.spring.io's uses tabs.
  local unit = text:match("\n([ \t]+)<modelVersion>") or "    "
  -- The block's own indentation, as reported by the scanner. Matching
  -- `<dependencies>` by pattern instead would find dependencyManagement's copy
  -- first on any Spring pom and indent the new entry one level too deep.
  local base = indent or unit

  local lines = {}
  local function add(level, line)
    lines[#lines + 1] = base .. unit:rep(level) .. line
  end
  add(1, "<dependency>")
  add(2, ("<groupId>%s</groupId>"):format(dep.group))
  add(2, ("<artifactId>%s</artifactId>"):format(dep.artifact))
  if M.needs_version(text, dep) then
    if not dep.version then
      return nil, ("%s:%s needs a version: nothing in this pom manages it")
        :format(dep.group, dep.artifact)
    end
    add(2, ("<version>%s</version>"):format(dep.version))
  end
  if dep.scope then
    add(2, ("<scope>%s</scope>"):format(dep.scope))
  end
  add(1, "</dependency>")
  local block = table.concat(lines, "\n")

  if open_end then
    -- Insert as the last child, keeping whatever whitespace preceded the
    -- closing tag so the result still looks hand-written.
    local before = text:sub(1, close_start - 1)
    local trailing = before:match("([ \t]*)$") or ""
    before = before:sub(1, #before - #trailing)
    return before .. block .. "\n" .. trailing .. text:sub(close_start)
  end

  if selfclose then
    -- `<dependencies/>` already *is* the list; expand it in place. Appending a
    -- second <dependencies> here would make the pom non-parseable.
    return text:sub(1, selfclose.s - 1)
      .. "<dependencies>\n"
      .. block
      .. "\n"
      .. base
      .. "</dependencies>"
      .. text:sub(selfclose.e + 1)
  end

  -- No <dependencies> at all: add one before </project>.
  local close_project = text:find("</project>")
  if not close_project then
    return nil, "pom.xml has no </project>"
  end
  local section = base .. "<dependencies>\n" .. block .. "\n" .. base .. "</dependencies>\n"
  return text:sub(1, close_project - 1) .. section .. text:sub(close_project)
end


---Add `dep` to the pom at `path`. Returns ok, err.
---@param path string
---@param dep table
function M.add_to_file(path, dep)
  -- "b" keeps the bytes exactly: a plain readfile/writefile round trip strips
  -- every CR from a CRLF file and appends a newline to one that lacked it, so
  -- a one-line change shows up in git as a whole-file rewrite.
  local ok, raw = pcall(vim.fn.readfile, path, "b")
  if not ok then
    return false, "Could not read " .. path
  end
  local text = table.concat(raw, "\n")
  local crlf = text:find("\r\n") ~= nil
  local updated, err = M.insert(crlf and (text:gsub("\r\n", "\n")) or text, dep)
  if not updated then
    return false, err
  end
  if crlf then
    updated = updated:gsub("\n", "\r\n")
  end
  local wrote, werr = require("kebab.fs").write_lines(path, vim.split(updated, "\n", { plain = true }), "b")
  if not wrote then
    return false, werr
  end
  return true
end

return M
