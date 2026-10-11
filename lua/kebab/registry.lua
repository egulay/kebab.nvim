-- Everything the layer knows about a language, in one place per language.
--
-- Before this, each fact about a stack was hardcoded in whichever file happened
-- to need it: the project types in project.lua, the Mason tools in
-- plugins/mason.lua, the LazyVim extras in plugins/extras.lua, the run
-- configurations in plugins/run.lua, the dependency command in deps.lua. Adding
-- Go meant editing five files and remembering all five.
--
-- Now a language is one declarative file in lua/kebab/languages/, and those five
-- places ask this registry instead. Adding a language is adding a file; a user
-- can add or override one without touching the repo at all.
--
-- Deliberately dependency-free: plugins/extras.lua and plugins/mason.lua are
-- lazy specs evaluated during startup, before anything else is loaded, so this
-- module must be requireable on its own.
local M = {}

-- Loaded in this order. Order matters for project detection: a Flutter project
-- also has a package.json sometimes, and the first marker to match decides what
-- kind of project it is.
local BUILTIN = {
  -- Detection order. The first marker to match decides what kind of project a
  -- directory is, so the specific stacks come before the general ones: a
  -- Flutter project also carries a package.json sometimes, and every one of
  -- them is also a git repository, which is what `generic` would claim.
  "dart",
  "java",
  "kotlin",
  "ruby",
  "rust",
  "go",
  "python",
  "javascript",
  "web",
  "data",
  "generic",
}

---@class kebab.Language
---@field key string stable identifier
---@field label string human name
---@field markers? string[] files that identify a project of this kind
---@field kind? string what to call it in a picker (defaults to key)
---@field filetypes? string[]
---@field extras? string[] LazyVim extras to import
---@field tools? string[] Mason packages
---@field tasks? table[] overseer templates
---@field deps? table how to add a dependency
---@field project_types? table[] scaffolds offered by :IdeNewProject
---@field templates? table[] file templates

local cache = nil

local function load_builtin()
  local out = {}
  for _, name in ipairs(BUILTIN) do
    local ok, lang = pcall(require, "kebab.languages." .. name)
    if ok and type(lang) == "table" and lang.key then
      out[#out + 1] = lang
    elseif not ok then
      vim.notify(("kebab: language %q failed to load: %s"):format(name, tostring(lang)),
        vim.log.levels.WARN)
    end
  end
  return out
end

---User additions and overrides.
---
---`vim.g.kebab_languages` may be a list of language tables or a function
---returning one. A table whose `key` matches a built-in one is merged over it,
---so a user can change a single field -- swap a language server, add a project
---type -- without restating the rest.
---
---`vim.g.kebab_disabled_languages` is a list of keys to drop entirely.
local function apply_user(languages)
  local extra = vim.g.kebab_languages
  if type(extra) == "function" then
    local ok, res = pcall(extra)
    extra = ok and res or nil
  end

  if type(extra) == "table" then
    for _, lang in ipairs(extra) do
      if type(lang) == "table" and lang.key then
        local replaced = false
        for i, existing in ipairs(languages) do
          if existing.key == lang.key then
            languages[i] = vim.tbl_deep_extend("force", existing, lang)
            replaced = true
            break
          end
        end
        if not replaced then
          languages[#languages + 1] = lang
        end
      end
    end
  end

  local disabled = vim.g.kebab_disabled_languages
  if type(disabled) == "table" and #disabled > 0 then
    local keep = {}
    for _, lang in ipairs(languages) do
      if not vim.tbl_contains(disabled, lang.key) then
        keep[#keep + 1] = lang
      end
    end
    languages = keep
  end

  return languages
end

---Every known language, in load order.
---@return kebab.Language[]
function M.languages()
  if cache then
    return cache
  end
  cache = apply_user(load_builtin())
  return cache
end

---Add or override a language in process.
---
---The other way in is vim.g.kebab_languages, which suits a config file. This
---suits a Lua config that wants to compute something first, and it is what the
---tests use -- so the extension point users are told about is the one that is
---exercised.
---
---A language whose `key` matches an existing one is merged over it, so a single
---field can be changed without restating the rest.
---@param lang kebab.Language
function M.register(lang)
  assert(type(lang) == "table" and lang.key, "a language needs a key")
  local languages = M.languages()
  for i, existing in ipairs(languages) do
    if existing.key == lang.key then
      languages[i] = vim.tbl_deep_extend("force", existing, lang)
      return languages[i]
    end
  end
  languages[#languages + 1] = lang
  return lang
end

---Remove a language by key. Returns true if it was there.
---@param key string
function M.unregister(key)
  local languages = M.languages()
  for i, existing in ipairs(languages) do
    if existing.key == key then
      table.remove(languages, i)
      return true
    end
  end
  return false
end

---Forget the cached set. For tests, and for a user reloading their config.
function M.reset()
  cache = nil
end

---@param key string
---@return kebab.Language|nil
function M.language(key)
  for _, lang in ipairs(M.languages()) do
    if lang.key == key then
      return lang
    end
  end
  return nil
end

function M.keys()
  return vim.tbl_map(function(l) return l.key end, M.languages())
end

-- --------------------------------------------------------------- aggregates

---Collect `field` from every language into one flat list, skipping duplicates.
---@param field string
---@return any[]
function M.collect(field)
  local out, seen = {}, {}
  for _, lang in ipairs(M.languages()) do
    for _, item in ipairs(lang[field] or {}) do
      local id = type(item) == "table" and (item.key or item.name) or item
      if id == nil or not seen[id] then
        if id ~= nil then
          seen[id] = true
        end
        out[#out + 1] = item
      end
    end
  end
  return out
end

---LazyVim extras every language asks for.
function M.extras()
  return M.collect("extras")
end

---Mason packages every language asks for.
function M.tools()
  return M.collect("tools")
end

---overseer templates every language contributes.
function M.tasks()
  return M.collect("tasks")
end

---Project scaffolds, each tagged with the language that offers it.
function M.project_types()
  local out, seen = {}, {}
  for _, lang in ipairs(M.languages()) do
    for _, t in ipairs(lang.project_types or {}) do
      if not seen[t.key] then
        seen[t.key] = true
        local copy = vim.tbl_extend("keep", { language = lang.key }, t)
        out[#out + 1] = copy
      end
    end
  end
  return out
end

---File templates, each tagged with its language.
function M.templates()
  local out = {}
  for _, lang in ipairs(M.languages()) do
    for _, t in ipairs(lang.templates or {}) do
      out[#out + 1] = vim.tbl_extend("keep", { language = lang.key }, t)
    end
  end
  return out
end

-- ---------------------------------------------------------------- detection

---Every project marker, normalised.
---
---A marker is the unit of detection rather than the language, because one
---language can be built several ways and they do not behave alike: a Java
---project is Maven or Gradle, and adding a dependency means editing pom.xml in
---one case and is unsupported in the other. A language may declare a marker as
---a plain filename for the simple case.
---@return { file: string, kind: string, language: string, deps: table|nil }[]
function M.markers()
  local out = {}
  for _, lang in ipairs(M.languages()) do
    for _, marker in ipairs(lang.markers or {}) do
      if type(marker) == "string" then
        out[#out + 1] = {
          file = marker,
          kind = lang.kind or lang.key,
          language = lang.key,
          deps = lang.deps,
        }
      elseif type(marker) == "table" and marker.file then
        out[#out + 1] = {
          file = marker.file,
          kind = marker.kind or lang.kind or lang.key,
          language = lang.key,
          deps = marker.deps or lang.deps,
        }
      end
    end
  end
  return out
end

---Just the filenames, for "is this directory a project?".
function M.marker_files()
  local out, seen = {}, {}
  for _, m in ipairs(M.markers()) do
    if not seen[m.file] then
      seen[m.file] = true
      out[#out + 1] = m.file
    end
  end
  return out
end

---Is `dir` a project at all?
function M.is_project(dir)
  for _, file in ipairs(M.marker_files()) do
    if vim.uv.fs_stat(dir .. "/" .. file) then
      return true
    end
  end
  return false
end

---What kind of project `dir` is, by the first marker that matches.
---@param dir string
---@return string|nil kind, table|nil marker
function M.kind_of(dir)
  for _, entry in ipairs(M.markers()) do
    if vim.uv.fs_stat(dir .. "/" .. entry.file) then
      return entry.kind, entry
    end
  end
  return nil, nil
end

---Walk up from `dir` looking for a project marker.
---@param dir string
---@return string|nil kind, string|nil marker_path, table|nil marker
function M.find_project(dir)
  local current = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
  while current ~= "" do
    local kind, entry = M.kind_of(current)
    if kind then
      return kind, current .. "/" .. entry.file, entry
    end
    local parent = vim.fn.fnamemodify(current, ":h")
    if parent == current then
      break
    end
    current = parent
  end
  return nil, nil, nil
end

---How to add a dependency to a project of this `kind`, as declared by whichever
---marker claims it.
---@param kind string e.g. "maven", "node", "flutter"
---@return table|nil
function M.deps_for(kind)
  for _, entry in ipairs(M.markers()) do
    if entry.kind == kind and entry.deps then
      return entry.deps
    end
  end
  return nil
end

return M
