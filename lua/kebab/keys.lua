-- Turn a key specification into the keys a person presses.
--
-- `<leader>DD` means nothing to anyone who has not read Neovim's
-- documentation, and it was on screen in every right-click menu and all over
-- the cheatsheet. Asked for directly: "do not use leader or any other stuff
-- which you only understand".
--
-- Menus and docs keep declaring the canonical form, because that is what
-- tests/spec/menu_shortcuts_spec.lua checks against the real mappings. This
-- module is the one place that renders it for a human, so the two cannot
-- drift.
--
-- Two separators, and the difference between them is the whole point: keys
-- pressed one after the other are joined with an arrow (`Space -> D -> D`),
-- keys held together with a plus (`Ctrl+Enter`). Asked for directly, after
-- "Space D D" turned out to read like three things to hold down. The arrow is
-- U+2192, which the monospace fonts here all carry; `vim.g.kebab_key_arrow`
-- replaces it (`"->"` for a terminal without it).
local M = {}

-- Named keys. Anything in angle brackets that is not a modifier.
local NAMED = {
  cr = "Enter",
  enter = "Enter",
  esc = "Esc",
  tab = "Tab",
  space = "Space",
  bs = "Backspace",
  del = "Delete",
  up = "Up",
  down = "Down",
  left = "Left",
  right = "Right",
  home = "Home",
  ["end"] = "End",
  pageup = "PageUp",
  pagedown = "PageDown",
  leftmouse = "left click",
  rightmouse = "right click",
  ["2-leftmouse"] = "double click",
}

local MODIFIER = { c = "Ctrl", a = "Alt", m = "Alt", s = "Shift", d = "Cmd" }

---The separator between keys pressed one after the other.
---@return string
function M.arrow()
  local override = vim.g.kebab_key_arrow
  if type(override) == "string" and override ~= "" then
    return override
  end
  return "→"
end

---The leader key, named the way it is printed on a keyboard.
---@return string
function M.leader_name()
  local leader = vim.g.mapleader
  if leader == nil or leader == "" then
    return "\\" -- Neovim's default
  end
  if leader == " " then
    return "Space"
  end
  return leader
end

---@return string
function M.localleader_name()
  local leader = vim.g.maplocalleader
  if leader == nil or leader == "" then
    return "\\"
  end
  if leader == " " then
    return "Space"
  end
  return leader
end

---One `<...>` chunk, rendered.
---@param inside string the text between the angle brackets
---@return string
local function render_bracketed(inside)
  local lower = inside:lower()
  if NAMED[lower] then
    return NAMED[lower]
  end
  -- A modifier chain: <C-S-x>, <C-CR>, <A-1>
  local parts, rest = {}, inside
  while true do
    local mod, remainder = rest:match("^([%a])%-(.+)$")
    if mod and MODIFIER[mod:lower()] then
      parts[#parts + 1] = MODIFIER[mod:lower()]
      rest = remainder
    else
      break
    end
  end
  if #parts > 0 then
    local tail = NAMED[rest:lower()] or rest
    return table.concat(parts, "+") .. "+" .. tail
  end
  -- Something unrecognised: show it without the brackets rather than as jargon
  return inside
end

---What to press, for a key specification.
---
---`<leader>DD` -> "Space → D → D", `<C-CR>` -> "Ctrl+Enter",
---`]p` -> "] → p". A plus means hold them together, an arrow means one
---after the other.
---A leading `:` means it is a command, not a key, and is left alone.
---@param spec string
---@return string
function M.human(spec)
  if type(spec) ~= "string" or spec == "" then
    return ""
  end
  if spec:sub(1, 1) == ":" then
    return spec
  end
  -- A key specification never contains a literal space -- the spacebar is
  -- `<space>` -- so anything that does is prose or a shell command, and
  -- rendering it as keystrokes spells it out one letter at a time. A pass over
  -- the cheatsheet did exactly that and shipped `k e b a b   d b   name`.
  if spec:find(" ", 1, true) then
    return spec
  end

  local out = {}
  local i = 1
  while i <= #spec do
    local char = spec:sub(i, i)
    if char == "<" then
      local close = spec:find(">", i + 1, true)
      if close then
        local inside = spec:sub(i + 1, close - 1)
        if inside:lower() == "leader" then
          out[#out + 1] = M.leader_name()
        elseif inside:lower() == "localleader" then
          out[#out + 1] = M.localleader_name()
        else
          out[#out + 1] = render_bracketed(inside)
        end
        i = close + 1
      else
        out[#out + 1] = char
        i = i + 1
      end
    else
      out[#out + 1] = char
      i = i + 1
    end
  end
  return table.concat(out, " " .. M.arrow() .. " ")
end

---Rewrite a menu's `rtxt` into what a person presses, keeping the canonical
---form in `keyspec` so the shortcut sweep still has something to check
---against the real mappings.
---@param items table[]
---@return table[] the same table, rewritten in place
function M.humanise(items)
  for _, entry in ipairs(items or {}) do
    if entry.items then
      M.humanise(entry.items)
    elseif entry.rtxt and not entry.keyspec then
      entry.keyspec = entry.rtxt
      entry.rtxt = M.human(entry.rtxt)
    end
  end
  return items
end

return M
